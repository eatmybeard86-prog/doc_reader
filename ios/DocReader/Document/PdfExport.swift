import UIKit

/// Створення PDF з документа: для друку, «Поділитися як PDF» і «Зберегти як PDF».
enum PdfExport {
    /// A4 у пунктах.
    static let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    static let margin: CGFloat = 56

    /// Записує PDF у тимчасовий файл з іменем документа.
    static func export(_ doc: ReaderDocument) throws -> URL {
        let base = (doc.sources.first?.name ?? doc.title) as NSString
        var name = base.deletingPathExtension
        if name.isEmpty { name = "Документ" }
        let url = DocumentLoader.exportDir().appendingPathComponent(name + ".pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: name, kCGPDFContextCreator as String: "Читалка"]
        let renderer = UIGraphicsPDFRenderer(bounds: a4, format: format)
        if doc.paged {
            try writePaged(doc, renderer: renderer, to: url)
        } else {
            try writeText(doc, renderer: renderer, to: url)
        }
        return url
    }

    /// Кожна сторінка – растр оригіналу. Для фото ширина сторінки – як в A4.
    private static func writePaged(_ doc: ReaderDocument, renderer: UIGraphicsPDFRenderer, to url: URL) throws {
        try renderer.writePDF(to: url) { ctx in
            for i in 0..<doc.pageCount {
                autoreleasepool {
                    let size = doc.pageSizes[i]
                    let pw: CGFloat = doc.kind == .pdf ? size.width : 595
                    let ph = max(1, (pw * size.height / size.width).rounded())
                    let rect = CGRect(x: 0, y: 0, width: pw, height: ph)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    UIColor.white.setFill()
                    ctx.fill(rect)
                    if let img = doc.renderPage(i, width: min(pw * 2.5, 2400)) {
                        img.draw(in: rect)
                    }
                }
            }
        }
    }

    /// Верстка тексту на сторінки A4 з полями 2 см.
    private static func writeText(_ doc: ReaderDocument, renderer: UIGraphicsPDFRenderer, to url: URL) throws {
        var cache: [String: UIImage] = [:]
        let text = RichText.attributed(doc.blocks, images: doc.images,
                                       style: .init(fontSize: 11.5, ink: .black, imageTheme: nil, lineHeight: 1.15),
                                       recolored: &cache)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: a4.width - margin * 2, height: a4.height - margin * 2)
        var containers: [NSTextContainer] = []
        let total = layout.numberOfGlyphs
        var laidOut = 0
        while containers.count < 5000 {
            let tc = NSTextContainer(size: size)
            tc.lineFragmentPadding = 0
            layout.addTextContainer(tc)
            containers.append(tc)
            let range = layout.glyphRange(for: tc)
            if range.length == 0 && laidOut < total && containers.count > 1 { break }
            laidOut = NSMaxRange(range)
            if laidOut >= total { break }
        }
        let origin = CGPoint(x: margin, y: margin)
        try renderer.writePDF(to: url) { ctx in
            var pages = 0
            for tc in containers {
                let range = layout.glyphRange(for: tc)
                if range.length == 0 && pages > 0 { continue }
                ctx.beginPage()
                pages += 1
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            }
            if pages == 0 { ctx.beginPage() }
        }
    }
}
