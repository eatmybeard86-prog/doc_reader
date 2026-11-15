package ua.docreader

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import ua.docreader.doc.Document
import java.io.File
import java.io.FileNotFoundException

/**
 * Мінімальний провайдер файлів (замість androidx FileProvider):
 * віддає копії документів з cache/share іншим застосункам для «Поділитися».
 */
class ShareProvider : ContentProvider() {
    override fun onCreate() = true

    private fun fileFor(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        val dir = shareDir(ctx).canonicalFile
        val segs = uri.pathSegments
        if (segs.size != 2) throw FileNotFoundException()
        val f = File(File(dir, segs[0]), segs[1]).canonicalFile
        if (f.parentFile?.parentFile != dir || !f.isFile) throw FileNotFoundException()
        return f
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = fileFor(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val c = MatrixCursor(cols)
        c.addRow(cols.map { col ->
            when (col) {
                OpenableColumns.DISPLAY_NAME -> f.name
                OpenableColumns.SIZE -> f.length()
                else -> null
            }
        })
        return c
    }

    override fun getType(uri: Uri): String? = uri.getQueryParameter("mime")

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        private fun shareDir(ctx: Context) = File(ctx.cacheDir, "share")

        /** Готує Intent «Поділитися» для відкритого документа. */
        fun shareIntent(ctx: Context, doc: Document): Intent? {
            if (doc.sources.isEmpty()) return null
            val root = shareDir(ctx)
            root.deleteRecursively()
            val uris = ArrayList<Uri>()
            doc.sources.forEachIndexed { i, s ->
                val dir = File(root, i.toString()).apply { mkdirs() }
                val safeName = s.name.replace('/', '_').ifBlank { "file" }
                val dest = File(dir, safeName)
                s.file.copyTo(dest, overwrite = true)
                uris += Uri.Builder()
                    .scheme("content")
                    .authority(ctx.packageName + ".share")
                    .appendPath(i.toString())
                    .appendPath(safeName)
                    .appendQueryParameter("mime", s.mime)
                    .build()
            }
            val mimes = doc.sources.map { it.mime }.distinct()
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            }
            intent.type = if (mimes.size == 1) mimes[0] else "image/*"
            intent.putExtra(Intent.EXTRA_SUBJECT, doc.title)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // щоб дозвіл на читання дійшов до вибраного застосунку
            intent.clipData = android.content.ClipData.newRawUri(doc.title, uris[0]).apply {
                for (k in 1 until uris.size) addItem(android.content.ClipData.Item(uris[k]))
            }
            return Intent.createChooser(intent, "Поділитися").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}
