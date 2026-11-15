package ua.docreader.doc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ParsersTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun docx(documentXml: String, stylesXml: String? = null): File {
        val f = tmp.newFile("test.docx")
        ZipOutputStream(f.outputStream()).use { z ->
            fun put(name: String, text: String) {
                z.putNextEntry(ZipEntry(name)); z.write(text.toByteArray()); z.closeEntry()
            }
            put("[Content_Types].xml", "<Types/>")
            put("word/document.xml", documentXml)
            stylesXml?.let { put("word/styles.xml", it) }
        }
        return f
    }

    private val ns = """xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" """ +
        """xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" """ +
        """xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" """

    private fun texts(items: List<Item>) = items.filterIsInstance<TextItem>().map { it.text.toString() }

    @Test
    fun docxParagraphsHeadingsAndTables() {
        val xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document $ns><w:body>
              <w:p><w:pPr><w:pStyle w:val="1"/><w:jc w:val="center"/></w:pPr><w:r><w:t>Заголовок</w:t></w:r></w:p>
              <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Привіт, </w:t></w:r><w:r><w:t>світ!</w:t></w:r></w:p>
              <w:p/>
              <w:tbl><w:tr>
                <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc>
              </w:tr></w:tbl>
              <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:t>X</w:t></mc:Choice><mc:Fallback><w:t>Y</w:t></mc:Fallback></mc:AlternateContent></w:r></w:p>
            </w:body></w:document>"""
        val styles = """<?xml version="1.0" encoding="UTF-8"?>
            <w:styles $ns><w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style></w:styles>"""
        val items = ZipFile(docx(xml, styles)).use { DocxParser.parse(it) }
        val t = texts(items)
        assertEquals(listOf("Заголовок", "Привіт, світ!", "", "A1   │   B1", "X"), t)
        val heading = items.first() as TextItem
        assertEquals(1, heading.heading)
        assertEquals(TextItem.ALIGN_CENTER, heading.align)
        assertTrue((items[3] as TextItem).tableRow)
    }

    @Test(expected = DocException::class)
    fun emptyDocxReportsError() {
        val xml = """<?xml version="1.0"?><w:document $ns><w:body><w:p/></w:body></w:document>"""
        ZipFile(docx(xml)).use { DocxParser.parse(it) }
    }

    @Test
    fun rtfCyrillic() {
        val rtf = "{\\rtf1\\ansi\\ansicpg1251{\\fonttbl{\\f0 Times;}}\\f0 \\'cf\\'f0\\'e8\\'e2\\'b3\\'f2\\par \\u1057?\\u1074?\\u1110?\\u1090?}"
        val t = texts(RtfParser.parse(rtf.toByteArray(Charsets.ISO_8859_1)))
        assertEquals(listOf("Привіт", "Світ"), t)
    }
}
