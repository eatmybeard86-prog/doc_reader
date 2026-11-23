import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Проста обгортка над XMLParser: події початку/кінця елемента та тексту.
/// Простори імен не обробляються, тож імена приходять з префіксами ("w:p").
final class SaxParser: NSObject, XMLParserDelegate {
    var onStart: (String, [String: String]) -> Void = { _, _ in }
    var onEnd: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    @discardableResult
    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.shouldReportNamespacePrefixes = false
        p.shouldResolveExternalEntities = false
        p.delegate = self
        return p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        onStart(elementName, attributeDict)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onEnd(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        onText(string)
    }
}

/// Атрибут за повним іменем або за локальною частиною ("w:val" ≈ "val").
private func attr(_ a: [String: String], _ name: String) -> String? {
    if let v = a[name] { return v }
    let local = name.split(separator: ":").last.map(String.init) ?? name
    for (k, v) in a where (k.split(separator: ":").last.map(String.init) ?? k) == local {
        return v
    }
    return nil
}

private func isOn(_ a: [String: String]) -> Bool {
    guard let v = attr(a, "w:val") else { return true }
    return v != "0" && v != "false" && v != "none" && v != "off"
}

/// Простий розбір DOCX (Office Open XML): абзаци, жирний/курсив/підкреслення,
/// розмір шрифту, заголовки, списки, таблиці (рядок таблиці = один абзац), зображення.
enum DocxParser {

    static func parse(_ zip: ZipArchive) throws -> [TextBlock] {
        let rels = readRels(zip)
        let styles = readStyles(zip)
        guard let doc = zip.read("word/document.xml") else {
            throw DocError("Файл не схожий на документ Word (немає word/document.xml).")
        }
        let builder = Builder(rels: rels, styles: styles)
        let sax = SaxParser()
        sax.onStart = { builder.start($0, $1) }
        sax.onEnd = { builder.end($0) }
        sax.onText = { builder.text($0) }
        sax.parse(doc)
        let blocks = builder.out
        let hasContent = blocks.contains { b in
            switch b {
            case .image: return true
            case .paragraph(let p): return !p.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        if !hasContent { throw DocError("У документі не знайдено тексту.") }
        return blocks
    }

    struct Styles {
        var headings: [String: Int] = [:]
        var defaultSize = 22
    }

    static func readStyles(_ zip: ZipArchive) -> Styles {
        var styles = Styles()
        guard let data = zip.read("word/styles.xml") else { return styles }
        var styleId: String?
        var inDefaults = false
        let sax = SaxParser()
        sax.onStart = { name, a in
            switch name {
            case "w:style": styleId = attr(a, "w:styleId")
            case "w:name":
                let n = (attr(a, "w:val") ?? "").lowercased()
                var level = 0
                if n == "title" { level = 1 }
                else if n == "subtitle" { level = 2 }
                else if n.hasPrefix("heading ") { level = Int(n.dropFirst("heading ".count).trimmingCharacters(in: .whitespaces)) ?? 0 }
                if level > 0, let id = styleId { styles.headings[id] = level }
            case "w:outlineLvl":
                if let lvl = attr(a, "w:val").flatMap({ Int($0) }), lvl < 9, let id = styleId, styles.headings[id] == nil {
                    styles.headings[id] = lvl + 1
                }
            case "w:rPrDefault": inDefaults = true
            case "w:sz": if inDefaults, let v = attr(a, "w:val").flatMap({ Int($0) }), v > 0 { styles.defaultSize = v }
            default: break
            }
        }
        sax.onEnd = { name in
            if name == "w:style" { styleId = nil }
            if name == "w:rPrDefault" { inDefaults = false }
        }
        sax.parse(data)
        return styles
    }

    static func readRels(_ zip: ZipArchive) -> [String: String] {
        var map: [String: String] = [:]
        guard let data = zip.read("word/_rels/document.xml.rels") else { return map }
        let sax = SaxParser()
        sax.onStart = { name, a in
            guard name == "Relationship" || name.hasSuffix(":Relationship") else { return }
            if attr(a, "TargetMode") == "External" { return }
            guard let id = attr(a, "Id"), let target = attr(a, "Target") else { return }
            map[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
        }
        sax.parse(data)
        return map
    }

    private final class Builder {
        let rels: [String: String]
        let styles: Styles
        var out: [TextBlock] = []

        // абзац
        var para: [TextRun] = []
        var pDepth = 0
        var align = TextAlign.start
        var heading = 0
        var listItem = false
        var inPPr = false

        // фрагмент (run)
        var inRun = false
        var inRPr = false
        var inT = false
        var run = TextRun(text: "")

        // пропуск елементів: глибина вкладеності
        var skipDepth = 0

        // таблиці
        var tblDepth = 0
        var cells: [[TextRun]] = []
        var cell: [TextRun] = []
        var pendingImages: [String] = []

        init(rels: [String: String], styles: Styles) {
            self.rels = rels
            self.styles = styles
        }

        func appendText(_ s: String) {
            if inRun { run.text += s } else { para.append(TextRun(text: s)) }
        }

        func start(_ name: String, _ a: [String: String]) {
            if skipDepth > 0 { skipDepth += 1; return }
            switch name {
            // альтернативний вміст дублює текст у текстових полях – беремо лише основний варіант
            case "mc:Fallback", "w:delText", "w:instrText", "w:footnoteReference", "w:endnoteReference":
                skipDepth = 1
            case "w:p":
                pDepth += 1
                if pDepth == 1 {
                    para = []
                    align = .start
                    heading = 0
                    listItem = false
                } else if !para.isEmpty {
                    flushRun()
                    para.append(TextRun(text: "\n"))
                }
            case "w:pPr": inPPr = true
            case "w:pStyle":
                if inPPr && pDepth == 1, let v = attr(a, "w:val"), let h = styles.headings[v] { heading = h }
            case "w:outlineLvl":
                if inPPr && pDepth == 1, let v = attr(a, "w:val").flatMap({ Int($0) }), v < 9 { heading = v + 1 }
            case "w:jc":
                if inPPr && pDepth == 1 {
                    switch attr(a, "w:val") {
                    case "center": align = .center
                    case "right", "end": align = .end
                    case "both", "distribute": align = .justify
                    default: align = .start
                    }
                }
            case "w:numPr": if inPPr && pDepth == 1 { listItem = true }
            case "w:r":
                inRun = true
                run = TextRun(text: "")
            case "w:rPr": if inRun && !inPPr { inRPr = true }
            case "w:b": if inRPr { run.bold = isOn(a) }
            case "w:i": if inRPr { run.italic = isOn(a) }
            case "w:u": if inRPr { run.underline = isOn(a) }
            case "w:strike", "w:dstrike": if inRPr { run.strike = isOn(a) }
            case "w:sz":
                if inRPr, let v = attr(a, "w:val").flatMap({ Int($0) }), v > 0, v != styles.defaultSize {
                    run.size = min(max(Double(v) / Double(styles.defaultSize), 0.6), 2.5)
                }
            case "w:t": if inRun { inT = true }
            case "w:tab": if inRun && !inPPr { appendText("\t") }
            case "w:br", "w:cr": if inRun { appendText("\n") }
            case "w:noBreakHyphen": if inRun { appendText("-") }
            case "w:sym": if inRun { appendText("•") } // символ зі шрифтів Symbol/Wingdings
            case "a:blip": if let id = attr(a, "r:embed") { addImage(id) }
            case "v:imagedata": if let id = attr(a, "r:id") { addImage(id) }
            case "w:tbl": tblDepth += 1
            case "w:tc": if tblDepth == 1 { cell = [] }
            case "w:tr": if tblDepth == 1 { cells = [] }
            default: break
            }
        }

        func text(_ s: String) {
            if skipDepth == 0 && inT { run.text += s }
        }

        func flushRun() {
            if inRun && !run.text.isEmpty {
                para.append(run)
                run.text = ""
            }
        }

        func addImage(_ relId: String) {
            guard let path = rels[relId] else { return }
            if tblDepth > 0 {
                pendingImages.append(path)
                return
            }
            // розриваємо абзац навколо зображення
            flushRun()
            if !isBlank(para) {
                out.append(.paragraph(makeParagraph(para)))
            }
            para = []
            out.append(.image(path))
        }

        func end(_ name: String) {
            if skipDepth > 0 { skipDepth -= 1; return }
            switch name {
            case "w:pPr": inPPr = false
            case "w:rPr": inRPr = false
            case "w:t": inT = false
            case "w:r":
                flushRun()
                inRun = false
            case "w:p":
                pDepth -= 1
                if pDepth == 0 { finishParagraph() }
            case "w:tc":
                if tblDepth == 1 { cells.append(trimEnd(cell)) }
            case "w:tr":
                if tblDepth == 1 {
                    var row: [TextRun] = []
                    for (i, c) in cells.enumerated() {
                        if i > 0 { row.append(TextRun(text: tableCellSeparator)) }
                        row.append(contentsOf: c)
                    }
                    if !isBlank(row) {
                        out.append(.paragraph(TextParagraph(runs: row, align: .start, heading: 0, tableRow: true)))
                    }
                    cells = []
                    flushPendingImages()
                }
            case "w:tbl":
                tblDepth -= 1
                if tblDepth == 0 { flushPendingImages() }
            default: break
            }
        }

        func flushPendingImages() {
            for p in pendingImages { out.append(.image(p)) }
            pendingImages = []
        }

        func finishParagraph() {
            if tblDepth > 0 {
                if !isBlank(para) {
                    if !cell.isEmpty { cell.append(TextRun(text: " ")) }
                    cell.append(contentsOf: para)
                }
                return
            }
            out.append(.paragraph(makeParagraph(para)))
        }

        func makeParagraph(_ runs: [TextRun]) -> TextParagraph {
            var t = trimEnd(runs)
            if listItem && !t.isEmpty { t.insert(TextRun(text: "•  "), at: 0) }
            if heading > 0 && !t.isEmpty {
                let rel: Double
                switch heading {
                case 1: rel = 1.6
                case 2: rel = 1.4
                case 3: rel = 1.2
                default: rel = 1.1
                }
                for i in t.indices {
                    t[i].bold = true
                    t[i].size = rel
                }
            }
            return TextParagraph(runs: t, align: align, heading: heading, tableRow: false)
        }

        func isBlank(_ runs: [TextRun]) -> Bool {
            runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// Прибирає переноси й пробіли в кінці.
        func trimEnd(_ runs: [TextRun]) -> [TextRun] {
            var r = runs
            while var last = r.last {
                while let c = last.text.last, c == "\n" || c == " " || c == "\r\n" { last.text.removeLast() }
                if last.text.isEmpty { r.removeLast() } else { r[r.count - 1] = last; break }
            }
            return r
        }
    }
}
