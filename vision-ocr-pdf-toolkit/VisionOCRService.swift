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
        var enableDeskewPreprocessing: Bool = true

        // NEU:
        /// Unterhalb dieser Schwelle wird nicht gedreht. Default 0.0 = keine Deadzone.
        var minDeskewDegrees: Double = 0.0
        /// Schutzgrenze gegen völlig absurde Schätzungen.
        var maxDeskewDegrees: Double = 30.0
    }
    
    private struct OCRBox {
        let text: String
        // Vision-normalized Quad (origin bottom-left)
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
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
            if options.skipPagesWithExistingText {
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
            guard let cgImage = render(page: cgPage, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle, scale: options.renderScale) else {
                throw OCRError.cannotRenderPage(pageIndex + 1)
            }

            // 1) optional deskew für OCR (Original-PDF bleibt unverändert)
            let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
            let (ocrImage, appliedSkew): (CGImage, CGFloat)
            if options.enableDeskewPreprocessing {
                (ocrImage, appliedSkew) = Self.deskewForOCRIfNeeded(
                    cgImage: cgImage,
                    options: options,
                    logger: { line in log?("Page \(pageIndex + 1) skew: \(line)") }
                )
            } else {
                log?("Page \(pageIndex + 1) skew: disabled (enableDeskewPreprocessing=false)")
                (ocrImage, appliedSkew) = (cgImage, 0)
            }

            // 2) OCR genau einmal ausführen
            let observations = try recognizeText(on: ocrImage, options: options)

            // 3) Beobachtungen -> OCRBox (Quad am Ende immer bezogen aufs ORIGINALBILD)
            let boxes: [OCRBox] = observations.compactMap { obs in
                guard let best = obs.topCandidates(1).first else { return nil }

                // Versuche ein rotierbares Quad aus VNRecognizedText zu holen (Preview-Pfad)
                let fullRange = best.string.startIndex..<best.string.endIndex
                let rectObs: VNRectangleObservation? = (try? best.boundingBox(for: fullRange))

                // Fallback: axis-aligned bbox -> Quad daraus bauen
                func quadFromAxisAligned(_ bb: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
                    let tl = CGPoint(x: bb.minX, y: bb.maxY)
                    let tr = CGPoint(x: bb.maxX, y: bb.maxY)
                    let br = CGPoint(x: bb.maxX, y: bb.minY)
                    let bl = CGPoint(x: bb.minX, y: bb.minY)
                    return (tl, tr, br, bl)
                }

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
                    let (qtl, qtr, qbr, qbl) = quadFromAxisAligned(obs.boundingBox)
                    tl = qtl; tr = qtr; br = qbr; bl = qbl
                }

                // Wenn deskew angewandt wurde: Quad zurück in ORIGINAL-Koordinaten rotieren
                if appliedSkew != 0 {
                    tl = Self.mapNormalizedPointFromDeskewedToOriginal(tl, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    tr = Self.mapNormalizedPointFromDeskewedToOriginal(tr, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    br = Self.mapNormalizedPointFromDeskewedToOriginal(br, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    bl = Self.mapNormalizedPointFromDeskewedToOriginal(bl, skewAngleRadians: appliedSkew, imageSize: originalSize)
                }

                return OCRBox(text: best.string, tl: tl, tr: tr, br: br, bl: bl)
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
            overlayInvisibleText(boxes, in: ctx, targetRect: targetRect, imageSize: originalSize, renderScale: options.renderScale)
            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    // MARK: - Vision

    private static func recognizeText(on image: CGImage, options: Options) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = options.languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return request.results ?? []
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
    
    private static func deskewForOCRIfNeeded(
        cgImage: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) -> (CGImage, CGFloat) {
        // Winkel schätzen (radians); 0 wenn nicht zuverlässig
        guard let angle = estimateSkewAngleRadians(cgImage: cgImage, logger: logger) else {
            logger?("estimate=nil (zu wenig/kein Text) -> no deskew")
            return (cgImage, 0)
        }

        let absA = abs(angle)
        let deg = Double(angle * 180.0 / .pi)

        // LOG mit mehr Auflösung
        logger?(String(format: "estimate=%.6f rad (%.3f°)", Double(angle), deg))

        let minA = options.minDeskewDegrees * .pi / 180.0
        if Double(absA) < minA {
            logger?(String(format: "below threshold (<%.3f°) -> no deskew", options.minDeskewDegrees))
            return (cgImage, 0)
        }

        let maxA = options.maxDeskewDegrees * .pi / 180.0
        if Double(absA) > maxA {
            logger?(String(format: "above threshold (>%.1f°) -> no deskew", options.maxDeskewDegrees))
            return (cgImage, 0)
        }

        if let rotated = rotateImageKeepingExtent(cgImage: cgImage, radians: -angle) {
            logger?(String(format: "applied deskew: rotate by %.3f°", -deg))
            return (rotated, angle)
        }
        return (cgImage, 0)
    }

    private static func estimateSkewAngleRadians(
        cgImage: CGImage,
        logger: ((String) -> Void)? = nil
    ) -> CGFloat? {

        // Optional: downscale für Performance (z.B. max 1400px)
        let maxDim: CGFloat = 1400
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        var workImage = cgImage

        if max(w, h) > maxDim,
           let scaled = scaleCGImageLanczos(cgImage: cgImage, maxDimension: maxDim) {
            workImage = scaled
            logger?("skew: downscale to \(workImage.width)x\(workImage.height)")
        }

        // Winkel aus RecognizeText + Quad-Geometrie ziehen (Preview-nahe)
        let handler = VNImageRequestHandler(cgImage: workImage, options: [:])

        func run(_ level: VNRequestTextRecognitionLevel, minHeight: Float) -> [VNRecognizedTextObservation] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = level
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["de-DE", "en-US"]
            req.minimumTextHeight = minHeight

            do {
                try handler.perform([req])
                return req.results ?? []
            } catch {
                logger?("skew: VNRecognizeTextRequest(\(level)) failed: \(error.localizedDescription)")
                return []
            }
        }

        // Pass 1: schnell, aber nicht zu streng (Fax/Scan!)
        var results = run(.fast, minHeight: 0.004)

        // Pass 2: falls zu wenig/leer -> accurate, ohne Mindesthöhe
        if results.isEmpty {
            results = run(.accurate, minHeight: 0.0)
        }

        guard !results.isEmpty else {
            logger?("skew: no recognized text observations")
            return nil
        }

        let W = CGFloat(workImage.width)
        let H = CGFloat(workImage.height)

        var angles: [CGFloat] = []
        angles.reserveCapacity(256)

        for obs in results {
            guard let best = obs.topCandidates(1).first else { continue }
            let fullRange = best.string.startIndex..<best.string.endIndex
            guard let rect = try? best.boundingBox(for: fullRange) else { continue }

            let dx = (rect.topRight.x - rect.topLeft.x) * W
            let dy = (rect.topRight.y - rect.topLeft.y) * H
            if abs(dx) < 1e-6 { continue }

            let a = atan2(dy, dx)
            if abs(a) < (.pi / 2.0) {
                angles.append(a)
            }
        }

        guard angles.count >= 4 else {
            logger?("skew: too few angle samples (\(angles.count)) -> nil")
            return nil
        }

        // =========================
        // Sofortdiagnose (Signalqualität)
        // =========================
        let degSamples = angles.map { Double($0 * 180.0 / .pi) }
        let small = degSamples.filter { abs($0) < 0.5 }.count
        let pct = Int((Double(small) / Double(max(1, degSamples.count))) * 100.0)

        let mean = degSamples.reduce(0.0, +) / Double(degSamples.count)
        let varSum = degSamples.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let stdev = sqrt(varSum / Double(max(1, degSamples.count - 1)))

        // Sortieren + robuste Kennwerte
        angles.sort()
        let n = angles.count

        func q(_ p: Double) -> CGFloat {
            let idx = Int(Double(n - 1) * p)
            return angles[max(0, min(n - 1, idx))]
        }

        let minA = angles.first ?? 0
        let maxA = angles.last ?? 0
        let p10  = q(0.10)
        let med  = angles[n / 2]
        let p90  = q(0.90)

        logger?(
            String(
                format: "skew: angle-signal count=%d | <0.5°=%d (%d%%) | stdev=%.3f° | min=%.2f° p10=%.2f° med=%.2f° p90=%.2f° max=%.2f°",
                n,
                small,
                pct,
                stdev,
                Double(minA * 180.0 / .pi),
                Double(p10  * 180.0 / .pi),
                Double(med  * 180.0 / .pi),
                Double(p90  * 180.0 / .pi),
                Double(maxA * 180.0 / .pi)
            )
        )

        if stdev < 0.01 {
            logger?("skew: NOTE: angle signal too flat (stdev < 0.01°) -> nil")
            return nil
        }

        return med
    }

    private static func rotateImageKeepingExtent(cgImage: CGImage, radians: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)

        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)

        // clamp -> rotate -> crop: kein „leerer“ Rand durch Rotation
        let rotated = ci.clampedToExtent().transformed(by: t).cropped(to: extent)

        let ctx = CIContext(options: nil)
        return ctx.createCGImage(rotated, from: extent)
    }

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

    private static func mapNormalizedPointFromDeskewedToOriginal(
        _ p: CGPoint,
        skewAngleRadians: CGFloat,
        imageSize: CGSize
    ) -> CGPoint {
        let W = imageSize.width
        let H = imageSize.height

        // normalized -> pixel (Vision coords)
        let px = p.x * W
        let py = p.y * H

        let c = CGPoint(x: W / 2.0, y: H / 2.0)
        let ca = cos(skewAngleRadians)
        let sa = sin(skewAngleRadians)

        // deskewed -> original: rotate by +skewAngle around center
        let x = px - c.x
        let y = py - c.y
        let xr = x * ca - y * sa
        let yr = x * sa + y * ca

        let outX = xr + c.x
        let outY = yr + c.y

        // clamp + back to normalized
        let clampedX = min(max(outX, 0), W)
        let clampedY = min(max(outY, 0), H)

        return CGPoint(x: clampedX / W, y: clampedY / H)
    }
    
    private static func mapNormalizedRectFromDeskewedToOriginal(
        _ rect: CGRect,
        skewAngleRadians: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        let W = imageSize.width
        let H = imageSize.height

        // rect (normalized) -> pixel rect (Vision coords, origin bottom-left)
        let r = VNImageRectForNormalizedRect(rect, Int(W), Int(H))

        let corners = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY)
        ]

        let c = CGPoint(x: W / 2.0, y: H / 2.0)
        let ca = cos(skewAngleRadians)
        let sa = sin(skewAngleRadians)

        func rotBack(_ p: CGPoint) -> CGPoint {
            // deskewed -> original: rotate by +skewAngle around center
            let x = p.x - c.x
            let y = p.y - c.y
            let xr = x * ca - y * sa
            let yr = x * sa + y * ca
            return CGPoint(x: xr + c.x, y: yr + c.y)
        }

        let pts = corners.map(rotBack)
        let minX = pts.map(\.x).min() ?? 0
        let maxX = pts.map(\.x).max() ?? 0
        let minY = pts.map(\.y).min() ?? 0
        let maxY = pts.map(\.y).max() ?? 0

        var mapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        mapped = mapped.intersection(CGRect(x: 0, y: 0, width: W, height: H))

        // pixel -> normalized (Vision coords)
        return CGRect(
            x: mapped.origin.x / W,
            y: mapped.origin.y / H,
            width: mapped.size.width / W,
            height: mapped.size.height / H
        )
    }
    
}
