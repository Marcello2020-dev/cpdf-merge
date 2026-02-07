//
//  VisionOCRService.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 29.12.25.
//


import Foundation
import PDFKit
import Vision
import CoreGraphics
import CoreText
import CoreImage

enum VisionOCRService {

    struct Options {
        var languages: [String] = ["de-DE", "en-US"]
        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var usesLanguageCorrection: Bool = true
        var renderScale: CGFloat = 2.0
        var skipPagesWithExistingText: Bool = true

        // Optional diagnostics for local angle model.
        var debugBandAngleEstimation: Bool = false

        // Number of vertical bands used to build local skew interpolation.
        var bandAngleBandCount: Int = 20
    }
    
    private struct OCRBox {
        let text: String
        // Vision-normalized Quad (origin bottom-left)
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
    }

    private struct OCRCandidate {
        let text: String
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
        let centerY: CGFloat
        let measuredAngle: CGFloat?
        let isAxisAligned: Bool
    }

    private struct LineAngleSample {
        let yNorm: CGFloat
        let angle: CGFloat
    }

    private struct LocalAngleModel {
        let bandAngles: [CGFloat]

        func angle(atNormalizedY y: CGFloat) -> CGFloat {
            guard !bandAngles.isEmpty else { return 0 }
            if bandAngles.count == 1 { return bandAngles[0] }

            let yc = min(max(y, 0), 1)
            let p = yc * CGFloat(bandAngles.count - 1)
            let i0 = Int(floor(p))
            let i1 = min(bandAngles.count - 1, i0 + 1)
            let t = p - CGFloat(i0)
            return bandAngles[i0] * (1 - t) + bandAngles[i1] * t
        }
    }

    enum OCRError: Error, LocalizedError {
        case cannotOpenPDF
        case cannotCreateOutputContext
        case cannotGetPage(Int)
        case cannotRenderPage(Int)

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF: return "PDF konnte nicht geöffnet werden."
            case .cannotCreateOutputContext: return "Output-PDF konnte nicht erzeugt werden."
            case .cannotGetPage(let i): return "PDF-Seite \(i) konnte nicht gelesen werden."
            case .cannotRenderPage(let i): return "PDF-Seite \(i) konnte nicht gerendert werden."
            }
        }
    }

    /// Creates a searchable PDF by drawing original pages and overlaying invisible recognized text.
    static func ocrToSearchablePDF(
        inputPDF: URL,
        outputPDF: URL,
        /// Base directory for debug artifacts (band PNGs etc.).
        /// If nil, we try to choose a stable directory automatically.
        artifactsBaseDirectory _: URL? = nil,
        options: Options = Options(),
        progress: @escaping (_ currentPage: Int, _ totalPages: Int) -> Void,
        log: ((_ line: String) -> Void)? = nil
    ) throws {

        guard let doc = PDFDocument(url: inputPDF) else { throw OCRError.cannotOpenPDF }
        let total = doc.pageCount
        guard total > 0 else { throw OCRError.cannotOpenPDF }

        guard let consumer = CGDataConsumer(url: outputPDF as CFURL) else {
            throw OCRError.cannotCreateOutputContext
        }

        // We create a PDF context with per-page beginPDFPage(mediaBox) calls.
        // Wichtig: nicht "Letter" hardcoden – sonst kann oben/unten Inhalt fehlen.
        guard let firstRef = doc.page(at: 0)?.pageRef else { throw OCRError.cannotGetPage(1) }

        let firstChosen = bestBox(for: firstRef)
        var firstRect = firstRef.getBoxRect(firstChosen)
        if firstRect.isEmpty { firstRect = firstRef.getBoxRect(.cropBox) }
        if firstRect.isEmpty { firstRect = CGRect(x: 0, y: 0, width: 612, height: 792) } // letzter Fallback

        var dummyBox = CGRect(x: 0, y: 0, width: firstRect.width, height: firstRect.height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
            throw OCRError.cannotCreateOutputContext
        }

        let effectiveOptions = options

        for pageIndex in 0..<total {
            progress(pageIndex + 1, total)

            guard let page = doc.page(at: pageIndex), let cgPage = page.pageRef else {
                throw OCRError.cannotGetPage(pageIndex + 1)
            }

            // Robust: nimm die größte sinnvolle Box (Faxe/Scans haben oft eine "falsche" MediaBox)
            let box: CGPDFBox = bestBox(for: cgPage)
            var pageBox = cgPage.getBoxRect(box)

            // Fallbacks (nur zur Sicherheit)
            if pageBox.isEmpty { pageBox = cgPage.getBoxRect(.cropBox) }
            if pageBox.isEmpty { pageBox = cgPage.getBoxRect(.mediaBox) }

            let mb = cgPage.getBoxRect(.mediaBox)
            let cb = cgPage.getBoxRect(.cropBox)
            log?("Page \(pageIndex + 1): chosen=\(boxName(box)) rotation=\(cgPage.rotationAngle) mediaBox=\(mb) cropBox=\(cb)")
            
            let targetRect = CGRect(x: 0, y: 0, width: pageBox.width, height: pageBox.height)

            // Optional: skip if page already has text
            if effectiveOptions.skipPagesWithExistingText {
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !existing.isEmpty {
                    // Still copy the page into output (no OCR overlay)
                    let pageInfo: [CFString: Any] = [
                        kCGPDFContextMediaBox: targetRect,
                        kCGPDFContextCropBox:  targetRect,
                        kCGPDFContextTrimBox:  targetRect,
                        kCGPDFContextBleedBox: targetRect,
                        kCGPDFContextArtBox:   targetRect
                    ]
                    ctx.beginPDFPage(pageInfo as CFDictionary)
                    drawPDFPage(cgPage, into: ctx, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle)
                    ctx.endPDFPage()
                    continue
                }
            }

            // Render image for OCR
            guard let cgImage = render(page: cgPage, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle, scale: effectiveOptions.renderScale) else {
                throw OCRError.cannotRenderPage(pageIndex + 1)
            }

            let originalSize = CGSize(width: cgImage.width, height: cgImage.height)

            // OCR runs once per page. We do not globally deskew the bitmap.
            // If Vision cannot allocate intermediate buffers on large pages,
            // we retry with a downscaled recognition image (geometry stays normalized).
            let recognitionImage: CGImage
            let observations: [VNRecognizedTextObservation]
            do {
                let maxDimensions: [CGFloat?] = [nil, 1600, 1200, 900, 700]
                var lastError: Error?
                var foundImage: CGImage? = nil
                var foundObservations: [VNRecognizedTextObservation]? = nil

                for maxDim in maxDimensions {
                    let candidateImage: CGImage
                    if let maxDim {
                        guard let scaled = scaleCGImageLanczos(cgImage: cgImage, maxDimension: maxDim)
                                ?? scaleCGImageByRedraw(cgImage: cgImage, maxDimension: maxDim) else {
                            log?("Page \(pageIndex + 1) OCR: could not create fallback image for maxDim=\(Int(maxDim))")
                            continue
                        }
                        candidateImage = scaled
                        log?("Page \(pageIndex + 1) OCR: retry with downscaled image \(scaled.width)x\(scaled.height)")
                    } else {
                        candidateImage = cgImage
                    }

                    do {
                        let obs = try recognizeText(
                            on: candidateImage,
                            options: effectiveOptions,
                            logger: { line in log?("Page \(pageIndex + 1) OCR: \(line)") }
                        )
                        foundImage = candidateImage
                        foundObservations = obs
                        break
                    } catch {
                        lastError = error
                    }
                }

                guard let finalImage = foundImage, let finalObservations = foundObservations else {
                    throw lastError ?? NSError(
                        domain: "VisionOCR",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Vision OCR failed for all fallback scales."]
                    )
                }
                recognitionImage = finalImage
                observations = finalObservations
            }

            let recognitionSize = CGSize(width: recognitionImage.width, height: recognitionImage.height)

            let candidates: [OCRCandidate] = observations.compactMap { obs in
                guard let best = obs.topCandidates(1).first else { return nil }

                // Try quad geometry first.
                let fullRange = best.string.startIndex..<best.string.endIndex
                let rectObs: VNRectangleObservation? = (try? best.boundingBox(for: fullRange))

                var tl: CGPoint
                var tr: CGPoint
                var br: CGPoint
                var bl: CGPoint

                if let r = rectObs {
                    tl = r.topLeft
                    tr = r.topRight
                    br = r.bottomRight
                    bl = r.bottomLeft
                } else {
                    let (qtl, qtr, qbr, qbl) = Self.quadFromAxisAligned(obs.boundingBox)
                    tl = qtl; tr = qtr; br = qbr; bl = qbl
                }

                let centerY = Self.quadCenterY(tl: tl, tr: tr, br: br, bl: bl)
                let localAngle = Self.estimateLocalLineAngle(
                    recognizedText: best,
                    fallbackTL: tl,
                    fallbackTR: tr,
                    fallbackBR: br,
                    fallbackBL: bl,
                    imageSize: recognitionSize
                )

                return OCRCandidate(
                    text: best.string,
                    tl: tl,
                    tr: tr,
                    br: br,
                    bl: bl,
                    centerY: centerY,
                    measuredAngle: localAngle,
                    isAxisAligned: Self.isLikelyAxisAlignedQuad(
                        tl: tl,
                        tr: tr,
                        br: br,
                        bl: bl,
                        imageSize: recognitionSize
                    )
                )
            }

            let model = Self.buildLocalAngleModel(
                from: candidates,
                bandCount: max(1, effectiveOptions.bandAngleBandCount)
            )

            if effectiveOptions.debugBandAngleEstimation {
                let sampleCount = candidates.compactMap(\.measuredAngle).count
                log?("[Page \(pageIndex + 1)] local-angle samples=\(sampleCount), lines=\(candidates.count)")
                for (bandIndex, angle) in model.bandAngles.enumerated() {
                    let deg = Double(angle * 180.0 / .pi)
                    log?(String(format: "  band %02d: %.3f°", bandIndex + 1, deg))
                }
            }

            // Build final OCR boxes. Axis-aligned boxes get local rotation from band model.
            let boxes: [OCRBox] = candidates.map { c in
                var tl = c.tl
                var tr = c.tr
                var br = c.br
                var bl = c.bl

                if c.isAxisAligned {
                    let localAngle = model.angle(atNormalizedY: c.centerY)
                    if abs(localAngle) >= (CGFloat.pi / 900.0) { // ~0.2 degrees
                        (tl, tr, br, bl) = Self.rotateNormalizedQuadInImageSpace(
                            tl: tl,
                            tr: tr,
                            br: br,
                            bl: bl,
                            angleRadians: localAngle,
                            imageSize: originalSize
                        )
                    }
                }

                return OCRBox(text: c.text, tl: tl, tr: tr, br: br, bl: bl)
            }

            // Write output page: original content + invisible text
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: targetRect,
                kCGPDFContextCropBox:  targetRect,
                kCGPDFContextTrimBox:  targetRect,
                kCGPDFContextBleedBox: targetRect,
                kCGPDFContextArtBox:   targetRect
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            drawPDFPage(cgPage, into: ctx, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle)
            overlayInvisibleText(boxes, in: ctx, targetRect: targetRect, imageSize: originalSize, renderScale: effectiveOptions.renderScale)
            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    // MARK: - Vision

    private static func recognizeText(
        on image: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) throws -> [VNRecognizedTextObservation] {
        typealias Attempt = (
            level: VNRequestTextRecognitionLevel,
            useLanguageCorrection: Bool,
            languages: [String]?
        )

        let attempts: [Attempt] = [
            (options.recognitionLevel, options.usesLanguageCorrection, options.languages),
            (options.recognitionLevel, false, options.languages),
            (.fast, false, options.languages),
            (.fast, false, nil)
        ]

        var lastError: Error?

        for (idx, attempt) in attempts.enumerated() {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = attempt.level
            request.usesLanguageCorrection = attempt.useLanguageCorrection
            if let langs = attempt.languages, !langs.isEmpty {
                request.recognitionLanguages = langs
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                if idx > 0 {
                    logger?("fallback attempt \(idx + 1) succeeded")
                }
                return request.results ?? []
            } catch {
                lastError = error
                logger?("attempt \(idx + 1) failed: \(error.localizedDescription)")
            }
        }

        throw lastError ?? NSError(
            domain: "VisionOCR",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "VNRecognizeTextRequest failed without a detailed error."]
        )
    }

    // MARK: - Local line angle model (Vision-only)

    private static func quadFromAxisAligned(_ bb: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let tl = CGPoint(x: bb.minX, y: bb.maxY)
        let tr = CGPoint(x: bb.maxX, y: bb.maxY)
        let br = CGPoint(x: bb.maxX, y: bb.minY)
        let bl = CGPoint(x: bb.minX, y: bb.minY)
        return (tl, tr, br, bl)
    }

    private static func quadCenterY(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) -> CGFloat {
        (tl.y + tr.y + br.y + bl.y) * 0.25
    }

    private static func estimateLocalLineAngle(
        recognizedText: VNRecognizedText,
        fallbackTL: CGPoint,
        fallbackTR: CGPoint,
        fallbackBR: CGPoint,
        fallbackBL: CGPoint,
        imageSize: CGSize
    ) -> CGFloat? {
        let centers = sampledCenters(for: recognizedText)
        if let angle = angleFromPointCloud(centers, imageSize: imageSize) {
            return angle
        }

        return angleFromQuad(
            tl: fallbackTL,
            tr: fallbackTR,
            br: fallbackBR,
            bl: fallbackBL,
            imageSize: imageSize
        )
    }

    private static func sampledCenters(for recognizedText: VNRecognizedText) -> [CGPoint] {
        let s = recognizedText.string
        let n = s.count
        guard n > 0 else { return [] }

        var ranges: [Range<String.Index>] = []
        ranges.reserveCapacity(12)
        ranges.append(s.startIndex..<s.endIndex)

        if n >= 3 {
            let segmentCount = min(10, max(3, n / 5))
            for i in 0..<segmentCount {
                let startOffset = (n * i) / segmentCount
                let endOffset = (n * (i + 1)) / segmentCount
                if endOffset <= startOffset { continue }

                let start = s.index(s.startIndex, offsetBy: startOffset)
                let end = s.index(s.startIndex, offsetBy: endOffset)
                ranges.append(start..<end)
            }
        }

        var points: [CGPoint] = []
        points.reserveCapacity(ranges.count)

        for r in ranges {
            guard let rect = try? recognizedText.boundingBox(for: r) else { continue }
            let cx = (rect.topLeft.x + rect.topRight.x + rect.bottomRight.x + rect.bottomLeft.x) * 0.25
            let cy = (rect.topLeft.y + rect.topRight.y + rect.bottomRight.y + rect.bottomLeft.y) * 0.25
            points.append(CGPoint(x: cx, y: cy))
        }

        // De-duplicate near-identical centers.
        var unique: [CGPoint] = []
        unique.reserveCapacity(points.count)
        for p in points {
            let exists = unique.contains { q in
                abs(q.x - p.x) < 0.001 && abs(q.y - p.y) < 0.001
            }
            if !exists {
                unique.append(p)
            }
        }
        return unique
    }

    private static func angleFromPointCloud(_ points: [CGPoint], imageSize: CGSize) -> CGFloat? {
        guard points.count >= 2 else { return nil }

        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        let pixelPoints = points.map { CGPoint(x: $0.x * w, y: $0.y * h) }

        let meanX = pixelPoints.reduce(0.0) { $0 + $1.x } / CGFloat(pixelPoints.count)
        let meanY = pixelPoints.reduce(0.0) { $0 + $1.y } / CGFloat(pixelPoints.count)

        var num: CGFloat = 0
        var den: CGFloat = 0
        for p in pixelPoints {
            let dx = p.x - meanX
            let dy = p.y - meanY
            num += dx * dy
            den += dx * dx
        }

        if den <= 1e-6 {
            if pixelPoints.count == 2 {
                let a = pixelPoints[0]
                let b = pixelPoints[1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                if abs(dx) > 1e-6 {
                    return atan2(dy, dx)
                }
            }
            return nil
        }

        let slope = num / den
        let angle = atan(slope)
        let maxAbsAngle = CGFloat.pi / 4.0
        if abs(angle) > maxAbsAngle {
            return nil
        }
        return angle
    }

    private static func angleFromQuad(
        tl: CGPoint,
        tr: CGPoint,
        br _: CGPoint,
        bl _: CGPoint,
        imageSize: CGSize
    ) -> CGFloat? {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)
        let dx = (tr.x - tl.x) * w
        let dy = (tr.y - tl.y) * h
        if abs(dx) <= 1e-6 { return nil }

        let angle = atan2(dy, dx)
        let maxAbsAngle = CGFloat.pi / 4.0
        if abs(angle) > maxAbsAngle {
            return nil
        }
        return angle
    }

    private static func buildLocalAngleModel(from candidates: [OCRCandidate], bandCount: Int) -> LocalAngleModel {
        let count = max(1, bandCount)
        let samples: [LineAngleSample] = candidates.compactMap { c in
            guard let angle = c.measuredAngle else { return nil }
            let maxAbsAngle = CGFloat.pi / 4.0
            if abs(angle) > maxAbsAngle { return nil }
            return LineAngleSample(yNorm: c.centerY, angle: angle)
        }

        guard !samples.isEmpty else {
            return LocalAngleModel(bandAngles: Array(repeating: 0, count: count))
        }

        var perBand: [[CGFloat]] = Array(repeating: [], count: count)
        for s in samples {
            let y = min(max(s.yNorm, 0), 1)
            var idx = Int((y * CGFloat(count)).rounded(.down))
            if idx >= count { idx = count - 1 }
            if idx < 0 { idx = 0 }
            perBand[idx].append(s.angle)
        }

        var bandAngles: [CGFloat?] = perBand.map { list in
            guard !list.isEmpty else { return nil }
            return median(list)
        }

        // Fill empty bands by linear interpolation between nearest non-empty neighbors.
        for i in 0..<count where bandAngles[i] == nil {
            var left = i - 1
            while left >= 0, bandAngles[left] == nil { left -= 1 }
            var right = i + 1
            while right < count, bandAngles[right] == nil { right += 1 }

            switch (left >= 0 ? bandAngles[left] : nil, right < count ? bandAngles[right] : nil) {
            case let (l?, r?):
                let t = CGFloat(i - left) / CGFloat(right - left)
                bandAngles[i] = l * (1 - t) + r * t
            case let (l?, nil):
                bandAngles[i] = l
            case let (nil, r?):
                bandAngles[i] = r
            default:
                bandAngles[i] = 0
            }
        }

        // Light smoothing to avoid abrupt band jumps.
        let raw = bandAngles.map { $0 ?? 0 }
        var smooth = raw
        if count >= 3 {
            for i in 0..<count {
                let left = raw[max(0, i - 1)]
                let mid = raw[i]
                let right = raw[min(count - 1, i + 1)]
                smooth[i] = left * 0.25 + mid * 0.5 + right * 0.25
            }
        }

        return LocalAngleModel(bandAngles: smooth)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5
    }

    // MARK: - Rendering

    private static func drawPDFPage(_ cgPage: CGPDFPage, into ctx: CGContext, box: CGPDFBox, targetRect: CGRect, rotate: Int32) {
        ctx.saveGState()
        // Use CGPDFPage’s drawing transform to map page space into our targetRect.
        let t = cgPage.getDrawingTransform(box, rect: targetRect, rotate: rotate, preserveAspectRatio: false)
        ctx.concatenate(t)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
    }

    private static func render(page cgPage: CGPDFPage, box: CGPDFBox, targetRect: CGRect, rotate: Int32, scale: CGFloat) -> CGImage? {
        let widthPx  = max(1, Int((targetRect.width  * scale).rounded(.up)))
        let heightPx = max(1, Int((targetRect.height * scale).rounded(.up)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let bm = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        bm.interpolationQuality = .high

        // White background
        bm.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bm.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        // Map PDF into bitmap
        bm.saveGState()
        bm.scaleBy(x: scale, y: scale)
        let t = cgPage.getDrawingTransform(box, rect: targetRect, rotate: rotate, preserveAspectRatio: false)
        bm.concatenate(t)
        bm.drawPDFPage(cgPage)
        bm.restoreGState()

        return bm.makeImage()
    }

    // MARK: - Invisible text overlay

    private static func overlayInvisibleText(
        _ boxes: [OCRBox],
        in ctx: CGContext,
        targetRect: CGRect,
        imageSize: CGSize,
        renderScale: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 10.0, nil)

        ctx.saveGState()
        ctx.setTextDrawingMode(.fill)

        // Unsichtbar (aber im PDF auswählbar)
        ctx.setAlpha(0.0)

        for b in boxes {

            // Normalized -> pixel (Vision coords, origin bottom-left)
            func toPixel(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
            }

            let tlPx = toPixel(b.tl)
            let trPx = toPixel(b.tr)
            let brPx = toPixel(b.br)
            let blPx = toPixel(b.bl)

            // Pixel -> PDF (page coords): y-flip + /renderScale
            func toPDF(_ p: CGPoint) -> CGPoint {
                CGPoint(
                    x: p.x / renderScale + targetRect.origin.x,
                    y: (imageSize.height - p.y) / renderScale + targetRect.origin.y
                )
            }

            let tl = toPDF(tlPx)
            let tr = toPDF(trPx)
            let br = toPDF(brPx)
            let bl = toPDF(blPx)

            // Baseline: bl -> br
            let vx = br.x - bl.x
            let vy = br.y - bl.y
            let angle = atan2(vy, vx)

            let targetW = hypot(vx, vy)
            let leftH  = hypot(tl.x - bl.x, tl.y - bl.y)
            let rightH = hypot(tr.x - br.x, tr.y - br.y)
            let targetH = 0.5 * (leftH + rightH)

            if targetW <= 1 || targetH <= 1 { continue }

            // CTLine mit Basis-Font (wir skalieren gleich auf targetW/targetH)
            let attr: [CFString: Any] = [
                kCTFontAttributeName: font
            ]
            let attributed = CFAttributedStringCreate(nil, b.text as CFString, attr as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineH = max(1, ascent + descent)

            if lineW <= 1 { continue }

            let sx = targetW / lineW
            let sy = targetH / lineH

            ctx.saveGState()
            ctx.setAlpha(0.0)

            // Transformation: an bl setzen, drehen, skalieren
            ctx.translateBy(x: bl.x, y: bl.y)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: sx, y: sy)

            // Baseline: leicht nach oben (descent), damit Text nicht "absäuft"
            ctx.textPosition = CGPoint(x: 0, y: descent)

            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }
    
    // MARK: - Box selection (avoid cropping / wrong page size)

    private static func bestBox(for page: CGPDFPage) -> CGPDFBox {
        let candidates: [CGPDFBox] = [.mediaBox, .cropBox, .trimBox, .bleedBox, .artBox]

        var best: (box: CGPDFBox, area: CGFloat) = (.mediaBox, 0)

        for b in candidates {
            let r = page.getBoxRect(b)
            if r.isEmpty { continue }
            let area = abs(r.width * r.height)
            if area > best.area {
                best = (b, area)
            }
        }
        return best.box
    }

    private static func boxName(_ b: CGPDFBox) -> String {
        switch b {
        case .mediaBox: return "mediaBox"
        case .cropBox:  return "cropBox"
        case .trimBox:  return "trimBox"
        case .bleedBox: return "bleedBox"
        case .artBox:   return "artBox"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Image scaling
    private static func scaleCGImageLanczos(cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = maxDimension / max(w, h)
        guard scale < 1 else { return cgImage }

        let ci = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        let rect = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        return ctx.createCGImage(out, from: rect)
    }

    private static func scaleCGImageByRedraw(cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }

        let scale = maxDimension / max(w, h)
        guard scale < 1 else { return cgImage }

        let dstW = max(1, Int((w * scale).rounded()))
        let dstH = max(1, Int((h * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage()
    }

    private static func isLikelyAxisAlignedQuad(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint,
        imageSize: CGSize,
        maxAbsBaselineDegrees: Double = 0.25
    ) -> Bool {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        let tlPx = CGPoint(x: tl.x * w, y: tl.y * h)
        let trPx = CGPoint(x: tr.x * w, y: tr.y * h)
        let brPx = CGPoint(x: br.x * w, y: br.y * h)
        let blPx = CGPoint(x: bl.x * w, y: bl.y * h)

        let vx = brPx.x - blPx.x
        let vy = brPx.y - blPx.y
        guard abs(vx) > 1e-6 else { return false }

        let baselineDeg = Double(atan2(vy, vx) * 180.0 / .pi)
        if abs(baselineDeg) > maxAbsBaselineDegrees {
            return false
        }

        // Optional secondary check: top edge follows the same near-horizontal trend.
        let tvx = trPx.x - tlPx.x
        let tvy = trPx.y - tlPx.y
        if abs(tvx) <= 1e-6 { return false }
        let topDeg = Double(atan2(tvy, tvx) * 180.0 / .pi)
        return abs(topDeg) <= maxAbsBaselineDegrees
    }

    private static func rotateNormalizedQuadInImageSpace(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint,
        angleRadians: CGFloat,
        imageSize: CGSize
    ) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        func toPixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * w, y: p.y * h)
        }

        func toNormalized(_ p: CGPoint) -> CGPoint {
            let cx = min(max(p.x, 0), w)
            let cy = min(max(p.y, 0), h)
            return CGPoint(x: cx / w, y: cy / h)
        }

        let tlPx = toPixel(tl)
        let trPx = toPixel(tr)
        let brPx = toPixel(br)
        let blPx = toPixel(bl)

        let c = CGPoint(
            x: (tlPx.x + trPx.x + brPx.x + blPx.x) * 0.25,
            y: (tlPx.y + trPx.y + brPx.y + blPx.y) * 0.25
        )

        let ca = cos(angleRadians)
        let sa = sin(angleRadians)

        func rotate(_ p: CGPoint) -> CGPoint {
            let x = p.x - c.x
            let y = p.y - c.y
            return CGPoint(
                x: (x * ca - y * sa) + c.x,
                y: (x * sa + y * ca) + c.y
            )
        }

        return (
            toNormalized(rotate(tlPx)),
            toNormalized(rotate(trPx)),
            toNormalized(rotate(brPx)),
            toNormalized(rotate(blPx))
        )
    }
} // end of enum VisionOCRService
