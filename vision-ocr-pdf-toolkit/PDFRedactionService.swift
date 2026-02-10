import Foundation
import PDFKit
import CoreGraphics

enum PDFRedactionService {
    struct RedactionMark {
        let pageIndex: Int
        let rect: CGRect
    }

    struct Options {
        var renderScale: CGFloat = 2.5
        var redactionColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    enum RedactionError: Error, LocalizedError {
        case cannotOpenPDF
        case cannotCreateOutputContext
        case cannotGetPage(Int)
        case cannotRenderPage(Int)
        case noRedactions

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF:
                return "PDF konnte nicht geöffnet werden."
            case .cannotCreateOutputContext:
                return "Output-PDF konnte nicht erzeugt werden."
            case .cannotGetPage(let i):
                return "PDF-Seite \(i) konnte nicht gelesen werden."
            case .cannotRenderPage(let i):
                return "PDF-Seite \(i) konnte nicht verarbeitet werden."
            case .noRedactions:
                return "Keine Schwärzungsbereiche vorhanden."
            }
        }
    }

    /// Applies permanent redactions by rasterizing each page and burning redaction rectangles into pixels.
    /// This removes original vector/text content from the resulting PDF pages.
    static func applyPermanentRedactions(
        inputPDF: URL,
        outputPDF: URL,
        redactions: [RedactionMark],
        options: Options = Options(),
        progress: @escaping (_ currentPage: Int, _ totalPages: Int) -> Void,
        log: ((_ line: String) -> Void)? = nil
    ) throws {
        guard !redactions.isEmpty else { throw RedactionError.noRedactions }
        guard let doc = PDFDocument(url: inputPDF) else { throw RedactionError.cannotOpenPDF }

        let total = doc.pageCount
        guard total > 0 else { throw RedactionError.cannotOpenPDF }

        guard let consumer = CGDataConsumer(url: outputPDF as CFURL) else {
            throw RedactionError.cannotCreateOutputContext
        }

        guard let firstRef = doc.page(at: 0)?.pageRef else {
            throw RedactionError.cannotGetPage(1)
        }
        let firstRect = resolvedPageRect(for: firstRef)
        var mediaBox = CGRect(x: 0, y: 0, width: firstRect.width, height: firstRect.height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RedactionError.cannotCreateOutputContext
        }

        var grouped: [Int: [CGRect]] = [:]
        for mark in redactions {
            guard mark.pageIndex >= 0, mark.pageIndex < total else { continue }
            let standardized = mark.rect.standardized
            guard !standardized.isEmpty, standardized.width > 0.5, standardized.height > 0.5 else { continue }
            grouped[mark.pageIndex, default: []].append(standardized)
        }

        for pageIndex in 0..<total {
            progress(pageIndex + 1, total)

            guard let page = doc.page(at: pageIndex), let cgPage = page.pageRef else {
                throw RedactionError.cannotGetPage(pageIndex + 1)
            }

            let box = preferredBox(for: cgPage)
            let pageRect = resolvedPageRect(for: cgPage, preferred: box)
            let targetRect = CGRect(x: 0, y: 0, width: pageRect.width, height: pageRect.height)
            let pageMarks = grouped[pageIndex] ?? []

            guard let rendered = renderPageWithRedactions(
                cgPage: cgPage,
                box: box,
                targetRect: targetRect,
                rotate: cgPage.rotationAngle,
                scale: max(1.0, options.renderScale),
                redactions: pageMarks,
                redactionColor: options.redactionColor
            ) else {
                throw RedactionError.cannotRenderPage(pageIndex + 1)
            }

            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: targetRect,
                kCGPDFContextCropBox: targetRect,
                kCGPDFContextTrimBox: targetRect,
                kCGPDFContextBleedBox: targetRect,
                kCGPDFContextArtBox: targetRect
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            drawRenderedImagePage(rendered, into: ctx, targetRect: targetRect)
            ctx.endPDFPage()

            if !pageMarks.isEmpty {
                log?("Page \(pageIndex + 1): \(pageMarks.count) Schwärzungsbereich(e) angewendet.")
            }
        }

        ctx.closePDF()
    }

    private static func preferredBox(for page: CGPDFPage) -> CGPDFBox {
        let crop = page.getBoxRect(.cropBox)
        if !crop.isEmpty { return .cropBox }
        return .mediaBox
    }

    private static func resolvedPageRect(for page: CGPDFPage, preferred: CGPDFBox = .mediaBox) -> CGRect {
        var rect = page.getBoxRect(preferred)
        if rect.isEmpty { rect = page.getBoxRect(.cropBox) }
        if rect.isEmpty { rect = page.getBoxRect(.mediaBox) }
        if rect.isEmpty { rect = CGRect(x: 0, y: 0, width: 612, height: 792) }
        return rect
    }

    private static func renderPageWithRedactions(
        cgPage: CGPDFPage,
        box: CGPDFBox,
        targetRect: CGRect,
        rotate: Int32,
        scale: CGFloat,
        redactions: [CGRect],
        redactionColor: CGColor
    ) -> CGImage? {
        let widthPx = max(1, Int((targetRect.width * scale).rounded(.up)))
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
        bm.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bm.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        bm.saveGState()
        bm.scaleBy(x: scale, y: scale)

        let drawTransform = cgPage.getDrawingTransform(
            box,
            rect: targetRect,
            rotate: rotate,
            preserveAspectRatio: false
        )
        bm.concatenate(drawTransform)
        bm.drawPDFPage(cgPage)

        if !redactions.isEmpty {
            bm.setFillColor(redactionColor)
            for r in redactions {
                bm.fill(r)
            }
        }

        bm.restoreGState()
        return bm.makeImage()
    }

    private static func drawRenderedImagePage(_ image: CGImage, into ctx: CGContext, targetRect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(targetRect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: targetRect)
        ctx.restoreGState()
    }
}
