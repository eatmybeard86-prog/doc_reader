import XCTest
import UIKit
@testable import DocReader

final class ParsersTests: XCTestCase {

    private let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" "#
        + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" "#
        + #"xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" "#

    private func docx(_ documentXml: String, styles: String? = nil) throws -> ZipArchive {
        var z = ZipWriter()
        z.add("[Content_Types].xml", Data("<Types/>".utf8))
        z.add("word/document.xml", Data(documentXml.utf8))
        if let s = styles { z.add("word/styles.xml", Data(s.utf8)) }
        return try ZipArchive(data: z.finish())
    }

    private func texts(_ blocks: [TextBlock]) -> [String] {
        blocks.compactMap { $0.paragraph?.plainText }
    }

    func testDocxParagraphsHeadingsAndTables() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(ns)><w:body>
          <w:p><w:pPr><w:pStyle w:val="1"/><w:jc w:val="center"/></w:pPr><w:r><w:t>Заголовок</w:t></w:r></w:p>
          <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Привіт, </w:t></w:r><w:r><w:t>світ!</w:t></w:r></w:p>
          <w:p/>
          <w:tbl><w:tr>
            <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc>
          </w:tr></w:tbl>
          <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:t>X</w:t></mc:Choice><mc:Fallback><w:t>Y</w:t></mc:Fallback></mc:AlternateContent></w:r></w:p>
        </w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles \(ns)><w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style></w:styles>
        """
        let blocks = try DocxParser.parse(try docx(xml, styles: styles))
        XCTAssertEqual(texts(blocks), ["Заголовок", "Привіт, світ!", "", "A1" + tableCellSeparator + "B1", "X"])
        let heading = blocks[0].paragraph!
        XCTAssertEqual(heading.heading, 1)
        XCTAssertEqual(heading.align, .center)
        XCTAssertTrue(blocks[3].paragraph!.tableRow)
        let second = blocks[1].paragraph!
        XCTAssertTrue(second.runs[0].bold)
        XCTAssertFalse(second.runs[1].bold)
    }

    func testEmptyDocxReportsError() throws {
        let xml = #"<?xml version="1.0"?><w:document "# + ns + #"><w:body><w:p/></w:body></w:document>"#
        XCTAssertThrowsError(try DocxParser.parse(try docx(xml)))
    }

    func testDeflatedDocx() throws {
        let zip = try ZipArchive(data: Fixtures.deflatedDocx)
        let blocks = try DocxParser.parse(zip)
        XCTAssertEqual(blocks.count, 40)
        XCTAssertEqual(texts(blocks).first, "Рядок номер 1 – стиснений текст.")
        XCTAssertTrue(blocks[0].paragraph!.runs[0].italic)
    }

    func testDocxWriterRoundTrip() throws {
        let paragraphs = [
            TextParagraph(runs: [TextRun(text: "Перший <рядок> & "), TextRun(text: "жирне", bold: true)], align: .center),
            TextParagraph(runs: [TextRun(text: "Другий\tрядок", underline: true)]),
        ]
        let data = DocxWriter.write(paragraphs)
        let blocks = try DocxParser.parse(try ZipArchive(data: data))
        XCTAssertEqual(texts(blocks), ["Перший <рядок> & жирне", "Другий\tрядок"])
        let first = blocks[0].paragraph!
        XCTAssertEqual(first.align, .center)
        XCTAssertTrue(first.runs.last!.bold)
        XCTAssertFalse(first.runs.first!.bold)
        XCTAssertTrue(blocks[1].paragraph!.runs.allSatisfy(\.underline))
    }

    func testWord97() throws {
        XCTAssertEqual(DocumentLoader.detect(head: [UInt8](Fixtures.doc.prefix(16)), name: "t.doc"), .doc)
        let t = texts(try DocParser.parse([UInt8](Fixtures.doc)))
        XCTAssertTrue(t.contains("Привіт, світ!"), "\(t)")
        XCTAssertTrue(t.contains("Другий абзац тексту."), "\(t)")
        XCTAssertTrue(t.contains("A1" + tableCellSeparator + "B1"), "\(t)")
        XCTAssertEqual(t.last, "Кінець")
    }

    func testRtfCyrillicFallbackParser() throws {
        let rtf = "{\\rtf1\\ansi\\ansicpg1251{\\fonttbl{\\f0 Times;}}\\f0 \\'cf\\'f0\\'e8\\'e2\\'b3\\'f2\\par \\u1057?\\u1074?\\u1110?\\u1090?}"
        let t = texts(try RtfParser.parse(Array(rtf.utf8)))
        XCTAssertEqual(t, ["Привіт", "Світ"])
    }

    func testRtfSystemParser() throws {
        let rtf = "{\\rtf1\\ansi\\ansicpg1251{\\fonttbl{\\f0 Times;}}\\f0\\fs24 \\'cf\\'f0\\'e8\\'e2\\'b3\\'f2 {\\b \\'f1\\'e2\\'b3\\'f2}\\par End}"
        let (blocks, _) = try RichText.blocks(fromRTF: Data(rtf.utf8))
        let t = texts(blocks)
        XCTAssertEqual(t.first, "Привіт світ")
        XCTAssertTrue(blocks[0].paragraph!.runs.contains { $0.bold && $0.text.contains("світ") })
    }

    func testEditedTextBackToParagraphs() {
        let blocks: [TextBlock] = [
            .paragraph(TextParagraph(runs: [TextRun(text: "Звичайний "), TextRun(text: "курсив", italic: true)])),
            .paragraph(TextParagraph(runs: [TextRun(text: "По центру")], align: .center)),
        ]
        var cache: [String: UIImage] = [:]
        let s = RichText.attributed(blocks, images: [:], style: .init(fontSize: 20, ink: .black, imageTheme: nil), recolored: &cache)
        let back = RichText.paragraphs(from: s, baseSize: 20)
        XCTAssertEqual(back.map(\.plainText), ["Звичайний курсив", "По центру"])
        XCTAssertTrue(back[0].runs.last!.italic)
        XCTAssertEqual(back[1].align, .center)
        XCTAssertEqual(back[0].runs[0].size, 1)
    }

    func testDetect() {
        XCTAssertEqual(DocumentLoader.detect(head: Array("%PDF-1.4".utf8), name: "x"), .pdf)
        XCTAssertEqual(DocumentLoader.detect(head: [0x50, 0x4B, 0x03, 0x04], name: "x"), .docx)
        XCTAssertEqual(DocumentLoader.detect(head: Array("{\\rtf1".utf8), name: "x.doc"), .rtf)
        XCTAssertEqual(DocumentLoader.detect(head: [0xFF, 0xD8, 0xFF, 0xE0], name: "x"), .image)
        XCTAssertEqual(DocumentLoader.detect(head: [1, 2, 3], name: "x.txt"), .unknown)
    }

    func testTextPdfExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blocks: [TextBlock] = (1...200).map { .paragraph(.plain("Абзац номер \($0) з достатньо довгим текстом, щоб зайняти рядок.")) }
        let doc = ReaderDocument(title: "Тест.docx", kind: .docx, directory: dir,
                                 sources: [.init(url: dir.appendingPathComponent("Тест.docx"), name: "Тест.docx")], blocks: blocks)
        let url = try PdfExport.export(doc)
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertGreaterThan(pdf.numberOfPages, 2)
        XCTAssertEqual(url.lastPathComponent, "Тест.pdf")
    }
}
