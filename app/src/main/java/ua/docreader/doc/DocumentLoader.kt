package ua.docreader.doc

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.util.zip.ZipFile

object DocumentLoader {
    enum class Kind { PDF, DOCX, DOC, RTF, IMAGE, UNKNOWN }

    private fun docsDir(ctx: Context) = File(ctx.cacheDir, "docs")

    /** Видаляє тимчасові копії від попередніх запусків. */
    fun clearCache(ctx: Context) {
        docsDir(ctx).deleteRecursively()
    }

    fun displayName(ctx: Context, uri: Uri): String {
        try {
            ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { if (it.isNotBlank()) return it }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Документ"
    }

    fun open(ctx: Context, uris: List<Uri>): Document {
        if (uris.isEmpty()) throw DocException("Файл не вибрано.")
        val dir = File(docsDir(ctx), System.nanoTime().toString()).apply { mkdirs() }
        try {
            val files = uris.mapIndexed { i, uri -> copy(ctx, uri, File(dir, "f$i")) }
            val names = uris.map { displayName(ctx, it) }
            if (files.size > 1) {
                val images = files.filterIndexed { i, f -> detect(f, names[i]) == Kind.IMAGE }
                if (images.isEmpty()) throw DocException("Кілька файлів можна відкрити разом лише якщо це зображення.")
                return ImageDoc("${names.first()} (+${images.size - 1})", images, dir)
            }
            val file = files.first()
            val name = names.first()
            return when (detect(file, name)) {
                Kind.PDF -> PdfDoc(name, file, dir)
                Kind.IMAGE -> ImageDoc(name, listOf(file), dir)
                Kind.DOCX -> {
                    val zip = ZipFile(file)
                    try {
                        TextDoc(name, DocxParser.parse(zip), zip, dir)
                    } catch (e: Throwable) {
                        zip.close(); throw e
                    }
                }
                Kind.DOC -> TextDoc(name, DocParser.parse(file.readBytes()), null, dir)
                Kind.RTF -> TextDoc(name, RtfParser.parse(file.readBytes()), null, dir)
                Kind.UNKNOWN -> throw DocException("Непідтримуваний формат файлу. Підтримуються PDF, DOC, DOCX, RTF, JPG, PNG.")
            }
        } catch (e: Throwable) {
            dir.deleteRecursively()
            throw e
        }
    }

    private fun copy(ctx: Context, uri: Uri, dest: File): File {
        val input = try {
            ctx.contentResolver.openInputStream(uri)
        } catch (e: SecurityException) {
            throw DocException("Немає доступу до файлу. Відкрийте його ще раз через кнопку «Відкрити».")
        } catch (e: java.io.FileNotFoundException) {
            throw DocException("Файл не знайдено – можливо, його переміщено або видалено.")
        } ?: throw DocException("Не вдалося прочитати файл.")
        input.use { i -> dest.outputStream().use { o -> i.copyTo(o, 64 * 1024) } }
        return dest
    }

    fun detect(file: File, name: String): Kind {
        val head = ByteArray(16)
        val n = file.inputStream().use { it.read(head) }
        fun starts(vararg b: Int) = n >= b.size && b.indices.all { head[it].toInt() and 0xFF == b[it] }
        return when {
            starts(0x25, 0x50, 0x44, 0x46) -> Kind.PDF // %PDF
            starts(0x50, 0x4B, 0x03, 0x04) -> Kind.DOCX // ZIP
            starts(0xD0, 0xCF, 0x11, 0xE0) -> Kind.DOC
            starts(0x7B, 0x5C, 0x72, 0x74, 0x66) -> Kind.RTF // {\rtf
            starts(0xFF, 0xD8, 0xFF) -> Kind.IMAGE // JPEG
            starts(0x89, 0x50, 0x4E, 0x47) -> Kind.IMAGE // PNG
            starts(0x47, 0x49, 0x46) -> Kind.IMAGE // GIF
            starts(0x42, 0x4D) -> Kind.IMAGE // BMP
            n >= 12 && starts(0x52, 0x49, 0x46, 0x46) && head[8].toInt() == 0x57 -> Kind.IMAGE // WEBP
            else -> {
                // PDF може мати сміття перед заголовком – шукаємо в перших 1024 байтах
                val more = ByteArray(1024)
                val m = file.inputStream().use { it.read(more) }
                if (m > 0 && String(more, 0, m, Charsets.ISO_8859_1).contains("%PDF-")) return Kind.PDF
                when (name.substringAfterLast('.', "").lowercase()) {
                    "jpg", "jpeg", "png", "webp", "bmp", "gif", "heic", "heif" -> Kind.IMAGE
                    else -> Kind.UNKNOWN
                }
            }
        }
    }
}
