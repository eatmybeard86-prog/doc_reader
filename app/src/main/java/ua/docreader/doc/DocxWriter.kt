package ua.docreader.doc

import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.AlignmentSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Збереження відредагованого тексту у простий DOCX.
 * Зберігаються абзаци, жирний, курсив, підкреслення, закреслення, розмір шрифту та вирівнювання.
 */
object DocxWriter {
    /** Розмір основного шрифту у половинах пункту (24 = 12 pt). */
    private const val BASE_SIZE = 24

    /** Перетворює абзаци документа на один редагований текст. */
    fun toEditable(items: List<Item>): SpannableStringBuilder {
        val sb = SpannableStringBuilder()
        var first = true
        for (item in items) {
            if (item !is TextItem) continue
            if (!first) sb.append('\n')
            first = false
            val start = sb.length
            sb.append(item.text)
            val align = when (item.align) {
                TextItem.ALIGN_CENTER -> Layout.Alignment.ALIGN_CENTER
                TextItem.ALIGN_END -> Layout.Alignment.ALIGN_OPPOSITE
                else -> null
            }
            if (align != null && sb.length > start) {
                sb.setSpan(AlignmentSpan.Standard(align), start, sb.length, Spanned.SPAN_PARAGRAPH)
            }
        }
        return sb
    }

    fun write(text: CharSequence, out: OutputStream) {
        ZipOutputStream(out).use { z ->
            fun put(name: String, content: String) {
                z.putNextEntry(ZipEntry(name))
                z.write(content.toByteArray(Charsets.UTF_8))
                z.closeEntry()
            }
            put(
                "[Content_Types].xml",
                """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"""
            )
            put(
                "_rels/.rels",
                """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"""
            )
            put("word/document.xml", documentXml(text))
        }
    }

    fun toBytes(text: CharSequence): ByteArray = ByteArrayOutputStream().also { write(text, it) }.toByteArray()

    private fun documentXml(text: CharSequence): String {
        val spanned = text as? Spanned
        val sb = StringBuilder()
        sb.append("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""")
        sb.append("""<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>""")
        var start = 0
        while (start <= text.length) {
            var end = text.indexOf('\n', start)
            if (end < 0) end = text.length
            sb.append("<w:p>")
            paragraphProps(spanned, start, end)?.let { sb.append(it) }
            appendRuns(sb, text, spanned, start, end)
            sb.append("</w:p>")
            start = end + 1
        }
        sb.append("""<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1418" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>""")
        sb.append("</w:body></w:document>")
        return sb.toString()
    }

    private fun CharSequence.indexOf(c: Char, from: Int): Int {
        for (i in from until length) if (this[i] == c) return i
        return -1
    }

    private fun paragraphProps(s: Spanned?, start: Int, end: Int): String? {
        s ?: return null
        val spans = s.getSpans(start, maxOf(start, end), AlignmentSpan::class.java)
        val a = spans.lastOrNull()?.alignment ?: return null
        val jc = when (a) {
            Layout.Alignment.ALIGN_CENTER -> "center"
            Layout.Alignment.ALIGN_OPPOSITE -> "right"
            else -> return null
        }
        return """<w:pPr><w:jc w:val="$jc"/></w:pPr>"""
    }

    private fun appendRuns(sb: StringBuilder, text: CharSequence, s: Spanned?, start: Int, end: Int) {
        if (end <= start) return
        // межі фрагментів з однаковим форматуванням
        val cuts = sortedSetOf(start, end)
        if (s != null) {
            for (span in s.getSpans(start, end, Any::class.java)) {
                if (span !is StyleSpan && span !is UnderlineSpan && span !is StrikethroughSpan && span !is RelativeSizeSpan) continue
                cuts += s.getSpanStart(span).coerceIn(start, end)
                cuts += s.getSpanEnd(span).coerceIn(start, end)
            }
        }
        val points = cuts.toList()
        for (k in 0 until points.size - 1) {
            val a = points[k]
            val b = points[k + 1]
            if (b <= a) continue
            var bold = false; var italic = false; var underline = false; var strike = false; var rel = 1f
            if (s != null) {
                for (span in s.getSpans(a, b, Any::class.java)) {
                    if (s.getSpanStart(span) > a || s.getSpanEnd(span) < b) continue
                    when (span) {
                        is StyleSpan -> {
                            if (span.style and Typeface.BOLD != 0) bold = true
                            if (span.style and Typeface.ITALIC != 0) italic = true
                        }
                        is UnderlineSpan -> underline = true
                        is StrikethroughSpan -> strike = true
                        is RelativeSizeSpan -> rel *= span.sizeChange
                    }
                }
            }
            sb.append("<w:r>")
            val props = StringBuilder()
            if (bold) props.append("<w:b/>")
            if (italic) props.append("<w:i/>")
            if (strike) props.append("<w:strike/>")
            if (underline) props.append("""<w:u w:val="single"/>""")
            val size = (BASE_SIZE * rel).toInt().coerceIn(8, 144)
            props.append("""<w:sz w:val="$size"/><w:szCs w:val="$size"/>""")
            sb.append("<w:rPr>").append(props).append("</w:rPr>")
            // табуляції – окремими елементами
            val chunk = text.subSequence(a, b).toString()
            chunk.split('\t').forEachIndexed { i, part ->
                if (i > 0) sb.append("<w:tab/>")
                if (part.isNotEmpty()) sb.append("""<w:t xml:space="preserve">""").append(escape(part)).append("</w:t>")
            }
            sb.append("</w:r>")
        }
    }

    private fun escape(s: String): String {
        val sb = StringBuilder(s.length)
        for (c in s) {
            when {
                c == '&' -> sb.append("&amp;")
                c == '<' -> sb.append("&lt;")
                c == '>' -> sb.append("&gt;")
                c == '"' -> sb.append("&quot;")
                c.code < 0x20 -> {}
                c.code == 0xFFFE || c.code == 0xFFFF -> {}
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
