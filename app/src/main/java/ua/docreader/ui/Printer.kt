package ua.docreader.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.print.pdf.PrintedPdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import ua.docreader.doc.Document
import ua.docreader.doc.InlineImageItem
import ua.docreader.doc.PageItem
import ua.docreader.doc.TextItem
import java.io.FileOutputStream
import kotlin.concurrent.thread

/**
 * Друк через системний сервіс Android: на будь-який підключений принтер
 * або «Зберегти як PDF». Друкується в оригінальних кольорах (чорне на білому).
 */
object Printer {

    fun print(ctx: Context, doc: Document) {
        val pm = ctx.getSystemService(Context.PRINT_SERVICE) as PrintManager
        val name = doc.title.substringBeforeLast('.').ifBlank { "Документ" }
        val adapter = if (doc.pdfFile != null) PdfCopyAdapter(doc, name) else GeneratedAdapter(ctx, doc, name)
        val attrs = PrintAttributes.Builder()
            .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
            .build()
        pm.print(name, adapter, attrs)
    }

    private val main = Handler(Looper.getMainLooper())

    /** PDF друкується як є – без втрати якості. */
    private class PdfCopyAdapter(val doc: Document, val name: String) : PrintDocumentAdapter() {
        override fun onLayout(
            oldAttributes: PrintAttributes?, newAttributes: PrintAttributes,
            cancellationSignal: CancellationSignal, callback: LayoutResultCallback, extras: Bundle?,
        ) {
            if (cancellationSignal.isCanceled) { callback.onLayoutCancelled(); return }
            val info = PrintDocumentInfo.Builder("$name.pdf")
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(doc.items.size)
                .build()
            callback.onLayoutFinished(info, oldAttributes == null)
        }

        override fun onWrite(
            pages: Array<out PageRange>, destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal, callback: WriteResultCallback,
        ) {
            thread {
                try {
                    doc.pdfFile!!.inputStream().use { input ->
                        FileOutputStream(destination.fileDescriptor).use { out -> input.copyTo(out) }
                    }
                    main.post { callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES)) }
                } catch (e: Exception) {
                    main.post { callback.onWriteFailed(e.message) }
                }
            }
        }
    }

    /** DOC/DOCX/RTF і фото: формуємо PDF самі. */
    private class GeneratedAdapter(val ctx: Context, val doc: Document, val name: String) : PrintDocumentAdapter() {
        private var attributes: PrintAttributes? = null

        override fun onLayout(
            oldAttributes: PrintAttributes?, newAttributes: PrintAttributes,
            cancellationSignal: CancellationSignal, callback: LayoutResultCallback, extras: Bundle?,
        ) {
            if (cancellationSignal.isCanceled) { callback.onLayoutCancelled(); return }
            attributes = newAttributes
            val count = if (doc.paged) doc.items.size else PrintDocumentInfo.PAGE_COUNT_UNKNOWN
            val info = PrintDocumentInfo.Builder("$name.pdf")
                .setContentType(if (doc.paged && doc.isPhoto) PrintDocumentInfo.CONTENT_TYPE_PHOTO else PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(count)
                .build()
            callback.onLayoutFinished(info, oldAttributes != newAttributes)
        }

        override fun onWrite(
            pages: Array<out PageRange>, destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal, callback: WriteResultCallback,
        ) {
            val attrs = attributes ?: run { callback.onWriteFailed("Немає параметрів друку"); return }
            thread {
                val pdf = PrintedPdfDocument(ctx, attrs)
                try {
                    if (doc.paged) writeBitmapPages(pdf, cancellationSignal) else writeText(pdf, cancellationSignal)
                    if (cancellationSignal.isCanceled) {
                        main.post { callback.onWriteCancelled() }
                    } else {
                        FileOutputStream(destination.fileDescriptor).use { pdf.writeTo(it) }
                        main.post { callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES)) }
                    }
                } catch (e: Throwable) {
                    main.post { callback.onWriteFailed(e.message ?: e.javaClass.simpleName) }
                } finally {
                    pdf.close()
                }
            }
        }

        private fun writeBitmapPages(pdf: PrintedPdfDocument, cancel: CancellationSignal) {
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            doc.items.filterIsInstance<PageItem>().forEachIndexed { i, item ->
                if (cancel.isCanceled) return
                val page = pdf.startPage(i)
                val area = RectF(page.info.contentRect)
                val bmp = doc.renderPage(item, 2000)
                if (bmp != null) {
                    page.canvas.drawBitmap(bmp, null, fit(bmp, area), paint)
                    bmp.recycle()
                }
                pdf.finishPage(page)
            }
        }

        private fun fit(bmp: Bitmap, area: RectF): RectF {
            val scale = minOf(area.width() / bmp.width, area.height() / bmp.height)
            val w = bmp.width * scale
            val h = bmp.height * scale
            val l = area.left + (area.width() - w) / 2
            val t = area.top + (area.height() - h) / 2
            return RectF(l, t, l + w, t + h)
        }

        private fun writeText(pdf: PrintedPdfDocument, cancel: CancellationSignal) {
            var pageNo = 0
            var page = pdf.startPage(pageNo)
            // поля 2 см (у точках, 1/72 дюйма), якщо принтер не задав більші
            val margin = 56f
            val r = page.info.contentRect
            val left = maxOf(r.left.toFloat(), margin)
            val top = maxOf(r.top.toFloat(), margin)
            val right = minOf(r.right.toFloat(), page.info.pageWidth - margin)
            val bottom = minOf(r.bottom.toFloat(), page.info.pageHeight - margin)
            val width = (right - left).toInt().coerceAtLeast(50)
            var y = top

            fun newPage() {
                pdf.finishPage(page)
                pageNo++
                page = pdf.startPage(pageNo)
                y = top
            }

            val base = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK
                textSize = 11.5f
                typeface = Typeface.SERIF
            }
            val mono = TextPaint(base).apply { typeface = Typeface.MONOSPACE; textSize = 10f }
            val imgPaint = Paint(Paint.FILTER_BITMAP_FLAG)

            for (item in doc.items) {
                if (cancel.isCanceled) break
                when (item) {
                    is TextItem -> {
                        val text = if (item.text.isEmpty()) " " else item.text
                        val align = when (item.align) {
                            TextItem.ALIGN_CENTER -> Layout.Alignment.ALIGN_CENTER
                            TextItem.ALIGN_END -> Layout.Alignment.ALIGN_OPPOSITE
                            else -> Layout.Alignment.ALIGN_NORMAL
                        }
                        val layout = StaticLayout.Builder.obtain(text, 0, text.length, if (item.tableRow) mono else base, width)
                            .setAlignment(align)
                            .setLineSpacing(0f, 1.15f)
                            .setJustificationMode(
                                if (item.align == TextItem.ALIGN_JUSTIFY) Layout.JUSTIFICATION_MODE_INTER_WORD else Layout.JUSTIFICATION_MODE_NONE
                            )
                            .build()
                        if (item.heading > 0) y += 6f
                        for (line in 0 until layout.lineCount) {
                            val lt = layout.getLineTop(line).toFloat()
                            val lb = layout.getLineBottom(line).toFloat()
                            if (y + (lb - lt) > bottom && y > top) newPage()
                            val c = page.canvas
                            c.save()
                            c.translate(left, y - lt)
                            c.clipRect(0f, lt, width.toFloat(), lb)
                            layout.draw(c)
                            c.restore()
                            y += lb - lt
                        }
                        y += if (item.heading > 0) 6f else 3f
                    }
                    is InlineImageItem -> {
                        val bmp = doc.loadInlineImage(item.key, 1600) ?: continue
                        val maxH = bottom - top
                        val scale = minOf(width.toFloat() / bmp.width, maxH / bmp.height, 1f * 72f / 96f * 2f)
                        val w = bmp.width * scale
                        val h = bmp.height * scale
                        if (y + h > bottom && y > top) newPage()
                        val l = left + (width - w) / 2
                        page.canvas.drawBitmap(bmp, null, RectF(l, y, l + w, y + h), imgPaint)
                        bmp.recycle()
                        y += h + 6f
                    }
                    is PageItem -> {}
                }
            }
            pdf.finishPage(page)
        }
    }
}
