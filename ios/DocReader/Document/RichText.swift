import UIKit

/// Вбудоване зображення, що зменшується до ширини рядка.
final class FitAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let img = image, img.size.width > 0, img.size.height > 0 else {
            return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag,
                                          glyphPosition: position, characterIndex: charIndex)
        }
        let maxW = max(20, lineFrag.width - 4)
        var maxH = CGFloat.greatestFiniteMagnitude
        if let h = textContainer?.size.height, h < 100_000 { maxH = max(20, h - 8) }
        let scale = min(1, maxW / img.size.width, maxH / img.size.height)
        return CGRect(x: 0, y: 0, width: (img.size.width * scale).rounded(.down), height: (img.size.height * scale).rounded(.down))
    }
}

/// Перетворення між абзацами документа та NSAttributedString.
enum RichText {
    struct Style {
        /// Основний розмір шрифту, pt.
        var fontSize: CGFloat
        var ink: UIColor
        /// Тема для перефарбування вбудованих зображень (nil – оригінальні кольори).
        var imageTheme: ReaderTheme?
        var lineHeight: CGFloat = 1.25
    }

    private static var fontCache: [String: UIFont] = [:]
    private static let fontLock = NSLock()

    static func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> UIFont {
        let key = "\(size)|\(bold)|\(italic)|\(mono)"
        fontLock.lock()
        defer { fontLock.unlock() }
        if let f = fontCache[key] { return f }
        let base = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size)
        var desc = base.fontDescriptor
        if !mono, let serif = desc.withDesign(.serif) { desc = serif }
        var traits = desc.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let d = desc.withSymbolicTraits(traits) { desc = d }
        let f = UIFont(descriptor: desc, size: size)
        fontCache[key] = f
        return f
    }

    /// Текст документа з шрифтами й кольорами для показу, редагування або друку.
    static func attributed(_ blocks: [TextBlock], images: [String: UIImage], style: Style,
                           recolored: inout [String: UIImage]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let count = blocks.count
        for (i, block) in blocks.enumerated() {
            let last = i == count - 1
            switch block {
            case .paragraph(let p):
                let ps = NSMutableParagraphStyle()
                ps.alignment = nsAlign(p.align)
                ps.lineHeightMultiple = style.lineHeight
                ps.paragraphSpacing = style.fontSize * 0.3
                if p.heading > 0 { ps.paragraphSpacingBefore = style.fontSize * 0.6 }
                let mono = p.tableRow
                let start = out.length
                for r in p.runs where !r.text.isEmpty {
                    var size = style.fontSize * CGFloat(r.size)
                    if mono { size *= 0.9 }
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font(size: size, bold: r.bold, italic: r.italic, mono: mono),
                        .foregroundColor: style.ink,
                        .paragraphStyle: ps,
                    ]
                    if r.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if r.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    out.append(NSAttributedString(string: r.text, attributes: attrs))
                }
                let tail: [NSAttributedString.Key: Any] = [
                    .font: font(size: style.fontSize, bold: false, italic: false, mono: mono),
                    .foregroundColor: style.ink,
                    .paragraphStyle: ps,
                ]
                if !last {
                    out.append(NSAttributedString(string: "\n", attributes: tail))
                } else if out.length == start {
                    out.append(NSAttributedString(string: " ", attributes: tail))
                }
            case .image(let key):
                guard var img = images[key] else { continue }
                if let theme = style.imageTheme, theme.recolor {
                    let k = key + "|" + theme.rawValue
                    if let cached = recolored[k] { img = cached } else {
                        img = Recolor.apply(img, theme: theme)
                        recolored[k] = img
                    }
                }
                let att = FitAttachment()
                att.image = img
                let ps = NSMutableParagraphStyle()
                ps.alignment = .center
                ps.paragraphSpacing = style.fontSize * 0.5
                ps.paragraphSpacingBefore = style.fontSize * 0.3
                let s = NSMutableAttributedString(attachment: att)
                s.append(NSAttributedString(string: last ? "" : "\n"))
                s.addAttributes([.paragraphStyle: ps, .font: font(size: style.fontSize, bold: false, italic: false, mono: false),
                                 .foregroundColor: style.ink], range: NSRange(location: 0, length: s.length))
                out.append(s)
            }
        }
        return out
    }

    private static func nsAlign(_ a: TextAlign) -> NSTextAlignment {
        switch a {
        case .start: return .natural
        case .center: return .center
        case .end: return .right
        case .justify: return .justified
        }
    }

    private static func textAlign(_ a: NSTextAlignment) -> TextAlign {
        switch a {
        case .center: return .center
        case .right: return .end
        case .justified: return .justify
        default: return .start
        }
    }

    /// Абзаци з (відредагованого) тексту. [baseSize] – розмір звичайного шрифту в цьому тексті.
    static func paragraphs(from s: NSAttributedString, baseSize: CGFloat) -> [TextParagraph] {
        let ns = s.string as NSString
        var result: [TextParagraph] = []
        var start = 0
        let length = ns.length
        while start <= length {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
            let end = nl.location == NSNotFound ? length : nl.location
            let range = NSRange(location: start, length: end - start)
            var p = TextParagraph()
            if range.length > 0 {
                if let ps = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle {
                    p.align = textAlign(ps.alignment)
                }
                s.enumerateAttributes(in: range, options: []) { attrs, r, _ in
                    var text = ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
                    text = text.replacingOccurrences(of: "\u{2028}", with: "\n")
                    if text.isEmpty { return }
                    var run = TextRun(text: text)
                    if let f = attrs[.font] as? UIFont {
                        let t = f.fontDescriptor.symbolicTraits
                        run.bold = t.contains(.traitBold)
                        run.italic = t.contains(.traitItalic)
                        let rel = Double(f.pointSize / max(1, baseSize))
                        run.size = abs(rel - 1) < 0.04 ? 1 : min(max(rel, 0.4), 4)
                    }
                    run.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
                    run.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
                    p.runs.append(run)
                }
            }
            result.append(p)
            if nl.location == NSNotFound { break }
            start = end + 1
        }
        while let last = result.last, last.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.count > 1 {
            result.removeLast()
        }
        return result
    }

    /// RTF: спершу системний розбір (зберігає форматування), за невдачі – власний простий.
    static func blocks(fromRTF data: Data) throws -> ([TextBlock], [String: UIImage]) {
        if let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                           documentAttributes: nil), s.length > 0 {
            let (blocks, images) = blocks(fromAttributed: s)
            let hasText = blocks.contains { $0.paragraph.map { !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true }
            if hasText { return (blocks, images) }
        }
        return (try RtfParser.parse([UInt8](data)), [:])
    }

    /// Переводить довільний форматований текст у абзаци документа (розміри – відносно найчастішого).
    static func blocks(fromAttributed s: NSAttributedString) -> ([TextBlock], [String: UIImage]) {
        var counts: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length), options: []) { v, r, _ in
            if let f = v as? UIFont { counts[f.pointSize.rounded(), default: 0] += r.length }
        }
        let base = counts.max { $0.value < $1.value }?.key ?? 12

        var blocks: [TextBlock] = []
        var images: [String: UIImage] = [:]
        let ns = s.string as NSString
        let length = ns.length
        var start = 0
        while start <= length {
            let nl = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\u{2029}"), options: [],
                                         range: NSRange(location: start, length: length - start))
            let end = nl.location == NSNotFound ? length : nl.location
            let range = NSRange(location: start, length: end - start)
            var p = TextParagraph()
            if range.length > 0 {
                if let ps = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle {
                    p.align = textAlign(ps.alignment)
                }
                s.enumerateAttributes(in: range, options: []) { attrs, r, _ in
                    if let att = attrs[.attachment] as? NSTextAttachment {
                        let img = att.image ?? att.fileWrapper?.regularFileContents.flatMap { UIImage(data: $0) }
                        if let img = img {
                            if !p.runs.isEmpty { blocks.append(.paragraph(p)); p.runs = [] }
                            let key = "rtf-\(images.count)"
                            images[key] = img
                            blocks.append(.image(key))
                        }
                        return
                    }
                    let text = ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
                    if text.isEmpty { return }
                    var run = TextRun(text: text)
                    if let f = attrs[.font] as? UIFont {
                        let t = f.fontDescriptor.symbolicTraits
                        run.bold = t.contains(.traitBold)
                        run.italic = t.contains(.traitItalic)
                        let rel = Double(f.pointSize / max(1, base))
                        run.size = abs(rel - 1) < 0.04 ? 1 : min(max(rel, 0.6), 2.5)
                    }
                    run.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
                    run.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
                    p.runs.append(run)
                }
            }
            p.tableRow = p.plainText.contains(tableCellSeparator)
            blocks.append(.paragraph(p))
            if nl.location == NSNotFound { break }
            start = end + 1
        }
        trimTrailingEmpty(&blocks)
        return (blocks, images)
    }
}
