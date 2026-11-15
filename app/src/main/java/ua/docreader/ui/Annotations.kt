package ua.docreader.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import ua.docreader.doc.Document
import ua.docreader.doc.PageItem
import java.io.OutputStream

/**
 * Текст, доданий поверх сторінки PDF/фото.
 * Координати й розмір – частки ширини/висоти сторінки, тож не залежать від масштабу.
 */
class Annotation(
    var fx: Float,
    var fy: Float,
    var text: String,
    /** розмір шрифту як частка ширини сторінки */
    var size: Float,
    /** біла підкладка, щоб закрити старий текст */
    var cover: Boolean,
)

object AnnotationDrawer {
    const val SIZE_SMALL = 0.018f
    const val SIZE_MEDIUM = 0.025f
    const val SIZE_LARGE = 0.035f

    /** Прямокутники анотацій (для визначення дотику), у координатах сторінки шириною [w]. */
    fun bounds(a: Annotation, w: Float, h: Float): RectF {
        val l = layout(a, w)
        val x = a.fx * w
        val y = a.fy * h
        val pad = a.size * w * 0.25f
        return RectF(x - pad, y - pad, x + l.width + pad, y + l.height + pad)
    }

    private fun paint(a: Annotation, w: Float, color: Int) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = (a.size * w).coerceAtLeast(1f)
        this.color = color
    }

    private fun layout(a: Annotation, w: Float, color: Int = Color.BLACK): StaticLayout {
        val p = paint(a, w, color)
        val maxW = ((1f - a.fx) * w - 2f).coerceAtLeast(p.textSize * 2)
        val textW = a.text.split('\n').maxOf { p.measureText(it) }
        val width = minOf(maxW, textW + 2f).toInt().coerceAtLeast(1)
        return StaticLayout.Builder.obtain(a.text, 0, a.text.length, p, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .build()
    }

    /** Малює анотації на полотні розміром [w]×[h]. */
    fun draw(c: Canvas, list: List<Annotation>, w: Float, h: Float, ink: Int = Color.BLACK, page: Int = Color.WHITE) {
        val box = Paint().apply { color = page }
        for (a in list) {
            val l = layout(a, w, ink)
            val x = a.fx * w
            val y = a.fy * h
            if (a.cover) {
                val pad = a.size * w * 0.25f
                c.drawRect(x - pad, y - pad, x + l.width + pad, y + l.height + pad, box)
            }
            c.save()
            c.translate(x, y)
            l.draw(c)
            c.restore()
        }
    }

    /**
     * Записує новий PDF: кожна сторінка – растр оригіналу (≈180 dpi) + анотації у векторі.
     * Розміри сторінок зберігаються.
     */
    fun exportPdf(doc: Document, notes: Map<Int, List<Annotation>>, out: OutputStream) {
        val pdf = PdfDocument()
        try {
            val pages = doc.items.filterIsInstance<PageItem>()
            for (item in pages) {
                // для фото задаємо сторінку з шириною A4 (595 pt)
                val pw: Int
                val ph: Int
                if (doc.pdfFile != null) {
                    pw = item.width; ph = item.height
                } else {
                    pw = 595; ph = (595L * item.height / item.width).toInt().coerceAtLeast(1)
                }
                val page = pdf.startPage(PdfDocument.PageInfo.Builder(pw, ph, item.index + 1).create())
                val c = page.canvas
                c.drawColor(Color.WHITE)
                val bmp: Bitmap? = doc.renderPage(item, (pw * 2.5f).toInt().coerceAtMost(2400))
                if (bmp != null) {
                    c.drawBitmap(bmp, null, RectF(0f, 0f, pw.toFloat(), ph.toFloat()), Paint(Paint.FILTER_BITMAP_FLAG))
                    bmp.recycle()
                }
                notes[item.index]?.let { draw(c, it, pw.toFloat(), ph.toFloat()) }
                pdf.finishPage(page)
            }
            pdf.writeTo(out)
        } finally {
            pdf.close()
        }
    }
}
