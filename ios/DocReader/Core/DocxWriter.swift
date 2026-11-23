import Foundation

/// Збереження відредагованого тексту у простий DOCX.
/// Зберігаються абзаци, жирний, курсив, підкреслення, закреслення, розмір шрифту та вирівнювання.
enum DocxWriter {
    /// Розмір основного шрифту у половинах пункту (24 = 12 pt).
    private static let baseSize = 24.0

    static func write(_ paragraphs: [TextParagraph]) -> Data {
        var z = ZipWriter()
        z.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.utf8))
        z.add("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.utf8))
        z.add("word/document.xml", Data(documentXml(paragraphs).utf8))
        return z.finish()
    }

    static func documentXml(_ paragraphs: [TextParagraph]) -> String {
        var sb = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        sb += #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
        for p in paragraphs {
            sb += "<w:p>"
            switch p.align {
            case .center: sb += #"<w:pPr><w:jc w:val="center"/></w:pPr>"#
            case .end: sb += #"<w:pPr><w:jc w:val="right"/></w:pPr>"#
            case .justify: sb += #"<w:pPr><w:jc w:val="both"/></w:pPr>"#
            case .start: break
            }
            for r in p.runs where !r.text.isEmpty {
                sb += "<w:r><w:rPr>"
                if r.bold { sb += "<w:b/>" }
                if r.italic { sb += "<w:i/>" }
                if r.strike { sb += "<w:strike/>" }
                if r.underline { sb += #"<w:u w:val="single"/>"# }
                let size = min(max(Int(baseSize * r.size), 8), 144)
                sb += #"<w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/>"#
                sb += "</w:rPr>"
                // табуляції – окремими елементами
                for (i, part) in r.text.components(separatedBy: "\t").enumerated() {
                    if i > 0 { sb += "<w:tab/>" }
                    if !part.isEmpty { sb += #"<w:t xml:space="preserve">"# + escape(part) + "</w:t>" }
                }
                sb += "</w:r>"
            }
            sb += "</w:p>"
        }
        sb += #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1418" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>"#
        sb += "</w:body></w:document>"
        return sb
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf16.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF || u.value == 0xFFFC { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}
