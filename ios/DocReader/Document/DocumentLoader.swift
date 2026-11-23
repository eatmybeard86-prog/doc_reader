import UIKit
import ImageIO

enum DocumentLoader {
    enum Kind { case pdf, docx, doc, rtf, image, unknown }

    /// Тека, де зберігаються копії відкритого документа (переживає перезапуск застосунку).
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenDocuments", isDirectory: true)
    }

    /// Тимчасова тека для файлів, які створюються для «Поділитися», друку та збереження.
    static func exportDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Видаляє копії всіх документів, крім [keep].
    static func cleanup(keep: URL?) {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in list where url.standardizedFileURL != keep?.standardizedFileURL {
            try? fm.removeItem(at: url)
        }
    }

    /// Копіює файли в теку застосунку та відкриває їх.
    static func open(urls: [URL]) throws -> ReaderDocument {
        if urls.isEmpty { throw DocError("Файл не вибрано.") }
        let fm = FileManager.default
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for (i, url) in urls.enumerated() {
                let sub = dir.appendingPathComponent("\(i)", isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                var name = url.lastPathComponent
                if name.isEmpty || name == "/" { name = "Документ" }
                try copy(url, to: sub.appendingPathComponent(name))
            }
            return try load(directory: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    private static func copy(_ url: URL, to dest: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordError: NSError?
        var copyError: Error?
        // координатор завантажить файл з iCloud, якщо його ще немає на пристрої
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { src in
            do {
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                copyError = error
            }
        }
        if coordError != nil || copyError != nil {
            if (try? FileManager.default.copyItem(at: url, to: dest)) == nil {
                throw DocError("Немає доступу до файлу. Відкрийте його ще раз через кнопку «Відкрити».")
            }
        }
    }

    /// Відкриває документ з уже скопійованих файлів (тека з підтеками 0, 1, …).
    static func load(directory dir: URL) throws -> ReaderDocument {
        let fm = FileManager.default
        let subs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { Int($0.lastPathComponent) != nil }
            .sorted { Int($0.lastPathComponent)! < Int($1.lastPathComponent)! }
        let files: [URL] = subs.compactMap { sub in
            (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil))?.first
        }
        if files.isEmpty { throw DocError("Файл не знайдено – можливо, його переміщено або видалено.") }
        let kinds = files.map(detect)

        if files.count > 1 {
            let idx = kinds.indices.filter { kinds[$0] == .image }
            if idx.isEmpty { throw DocError("Кілька файлів можна відкрити разом лише якщо це зображення.") }
            let title = "\(files[idx[0]].lastPathComponent) (+\(idx.count - 1))"
            return try imageDoc(title: title, files: idx.map { files[$0] }, dir: dir)
        }

        let file = files[0]
        let name = file.lastPathComponent
        let sources = [ReaderDocument.Source(url: file, name: name)]
        switch kinds[0] {
        case .pdf:
            guard let pdf = CGPDFDocument(file as CFURL) else { throw DocError("Не вдалося прочитати PDF.") }
            if pdf.isEncrypted && !pdf.isUnlocked { _ = pdf.unlockWithPassword("") }
            if !pdf.isUnlocked { throw DocError("PDF захищено паролем.") }
            var sizes: [CGSize] = []
            for i in 0..<pdf.numberOfPages {
                if let page = pdf.page(at: i + 1) { sizes.append(ReaderDocument.pdfPageSize(page)) }
                else { sizes.append(CGSize(width: 595, height: 842)) }
            }
            if sizes.isEmpty { throw DocError("У PDF немає сторінок.") }
            return ReaderDocument(title: name, kind: .pdf, directory: dir, sources: sources, pdf: pdf, pageSizes: sizes)
        case .image:
            return try imageDoc(title: name, files: [file], dir: dir)
        case .docx:
            let zip = try ZipArchive(data: try Data(contentsOf: file))
            let blocks = try DocxParser.parse(zip)
            var images: [String: UIImage] = [:]
            for case .image(let key) in blocks where images[key] == nil {
                if let data = zip.read(key), let img = Images.downsample(data: data, width: 1600) {
                    images[key] = img
                }
            }
            let shown = blocks.filter { if case .image(let k) = $0 { return images[k] != nil } else { return true } }
            return ReaderDocument(title: name, kind: .docx, directory: dir, sources: sources, blocks: shown, images: images)
        case .doc:
            let blocks = try DocParser.parse([UInt8](try Data(contentsOf: file)))
            return ReaderDocument(title: name, kind: .doc, directory: dir, sources: sources, blocks: blocks)
        case .rtf:
            let data = try Data(contentsOf: file)
            let (blocks, images) = try RichText.blocks(fromRTF: data)
            return ReaderDocument(title: name, kind: .rtf, directory: dir, sources: sources, blocks: blocks, images: images)
        case .unknown:
            throw DocError("Непідтримуваний формат файлу. Підтримуються PDF, DOC, DOCX, RTF, JPG, PNG.")
        }
    }

    private static func imageDoc(title: String, files: [URL], dir: URL) throws -> ReaderDocument {
        var urls: [URL] = []
        var sizes: [CGSize] = []
        for f in files {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let size = Images.orientedSize(src) else { continue }
            urls.append(f)
            sizes.append(size)
        }
        if urls.isEmpty { throw DocError("Не вдалося прочитати зображення.") }
        let sources = urls.map { ReaderDocument.Source(url: $0, name: $0.lastPathComponent) }
        return ReaderDocument(title: title, kind: .image, directory: dir, sources: sources, imageURLs: urls, pageSizes: sizes)
    }

    static func detect(_ file: URL) -> Kind {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        let head = [UInt8](handle.readData(ofLength: 1024))
        try? handle.close()
        return detect(head: head, name: file.lastPathComponent)
    }

    static func detect(head: [UInt8], name: String) -> Kind {
        func starts(_ b: [UInt8]) -> Bool { head.count >= b.count && Array(head.prefix(b.count)) == b }
        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf } // %PDF
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .docx } // ZIP
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return .doc }
        if starts([0x7B, 0x5C, 0x72, 0x74, 0x66]) { return .rtf } // {\rtf
        if starts([0xFF, 0xD8, 0xFF]) { return .image } // JPEG
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .image } // PNG
        if starts([0x47, 0x49, 0x46]) { return .image } // GIF
        if starts([0x42, 0x4D]) { return .image } // BMP
        if head.count >= 12 && starts([0x52, 0x49, 0x46, 0x46]) && head[8] == 0x57 { return .image } // WEBP
        if head.count >= 12 && Array(head[4..<8]) == Array("ftyp".utf8) { return .image } // HEIC/HEIF
        // PDF може мати сміття перед заголовком
        if String(decoding: head, as: UTF8.self).contains("%PDF-") { return .pdf }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "bmp", "gif", "heic", "heif", "tif", "tiff": return .image
        default: return .unknown
        }
    }
}
