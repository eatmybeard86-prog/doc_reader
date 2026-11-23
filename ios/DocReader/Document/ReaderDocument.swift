import UIKit
import ImageIO

/// Відкритий документ. Файли документа скопійовано в окрему теку застосунку.
final class ReaderDocument: Identifiable, @unchecked Sendable {
    enum Kind { case pdf, docx, doc, rtf, image }

    struct Source {
        let url: URL
        let name: String
    }

    let id = UUID()
    let title: String
    let kind: Kind
    /// Тека з копіями файлів.
    let directory: URL
    /// Оригінальні файли (з іменами) – для «Поділитися».
    let sources: [Source]

    // растрові документи (PDF, фото)
    /// Розміри сторінок (важливі лише пропорції).
    let pageSizes: [CGSize]
    private let pdf: CGPDFDocument?
    private let imageURLs: [URL]

    // текстові документи (DOC, DOCX, RTF)
    let blocks: [TextBlock]
    /// Вбудовані зображення за ключем.
    let images: [String: UIImage]

    var paged: Bool { kind == .pdf || kind == .image }
    var isPhoto: Bool { kind == .image }
    var pageCount: Int { pageSizes.count }

    /// Ключ для збереження позиції читання.
    var positionKey: String {
        let parts = sources.map { s -> String in
            let size = (try? s.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(s.name)#\(size)"
        }
        return "pos:" + parts.joined(separator: "|")
    }

    init(title: String, kind: Kind, directory: URL, sources: [Source], pdf: CGPDFDocument? = nil,
         imageURLs: [URL] = [], pageSizes: [CGSize] = [], blocks: [TextBlock] = [], images: [String: UIImage] = [:]) {
        self.title = title
        self.kind = kind
        self.directory = directory
        self.sources = sources
        self.pdf = pdf
        self.imageURLs = imageURLs
        self.pageSizes = pageSizes
        self.blocks = blocks
        self.images = images
    }

    private let renderLock = NSLock()

    /// Рендер сторінки шириною [width] пікселів (білий фон, оригінальні кольори).
    func renderPage(_ index: Int, width: CGFloat) -> UIImage? {
        guard index >= 0, index < pageSizes.count else { return nil }
        if kind == .image {
            return Images.downsample(url: imageURLs[index], width: width)
        }
        guard let pdf = pdf else { return nil }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let page = pdf.page(at: index + 1) else { return nil }
        let size = pageSizes[index]
        let w = max(1, width.rounded())
        let scale = w / size.width
        let h = max(1, (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            cg.interpolationQuality = .high
            // система координат PDF: початок унизу
            cg.translateBy(x: 0, y: h)
            cg.scaleBy(x: scale, y: -scale)
            let rect = CGRect(origin: .zero, size: size)
            cg.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            cg.clip(to: page.getBoxRect(.cropBox))
            cg.drawPDFPage(page)
        }
    }

    /// Видаляє копії файлів.
    func deleteFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Розмір сторінки PDF з урахуванням повороту.
    static func pdfPageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let size = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        return CGSize(width: max(1, size.width), height: max(1, size.height))
    }
}
