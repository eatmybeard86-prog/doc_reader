package ua.docreader.ui

import android.graphics.Bitmap
import android.graphics.Typeface
import android.text.Layout
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.TextView
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ua.docreader.R
import ua.docreader.ReaderTheme
import ua.docreader.doc.Document
import ua.docreader.doc.InlineImageItem
import ua.docreader.doc.Item
import ua.docreader.doc.PageItem
import ua.docreader.doc.TextItem
import kotlin.math.ceil

class PageAdapter(
    private val doc: Document,
    private val scope: CoroutineScope,
    private val renderDispatcher: CoroutineDispatcher,
) : BaseAdapter() {

    /** Ширина сторінки в пікселях (= ширина екрана × масштаб). */
    var pageWidth = 1
    /** Ширина видимої області (для вибору роздільності рендеру). */
    var viewportWidth = 1
    var zoom = 1f
    var theme: ReaderTheme = ReaderTheme.DAY
    /** Чи перефарбовувати фото відповідно до теми. */
    var tintPhotos = true
    /** Базовий розмір шрифту в sp для текстових документів. */
    var baseTextSp = 17f

    private val maxCacheBytes = (Runtime.getRuntime().maxMemory() / 3).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    private val cache = object : LruCache<String, Bitmap>(maxCacheBytes) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    private val items: List<Item> = doc.items

    override fun getCount() = items.size
    override fun getItem(position: Int) = items[position]
    override fun getItemId(position: Int) = position.toLong()
    override fun getViewTypeCount() = 3
    override fun getItemViewType(position: Int) = when (items[position]) {
        is PageItem -> 0
        is TextItem -> 1
        is InlineImageItem -> 2
    }
    override fun areAllItemsEnabled() = false
    override fun isEnabled(position: Int) = false

    fun clear() = cache.evictAll()

    private fun renderBucket(): Int {
        // рендеримо з запасом під масштаб, але квантуємо, щоб не перерендерювати на кожному кадрі щипка
        val factor = ceil(zoom.coerceAtMost(3f).toDouble()).toInt().coerceAtLeast(1)
        return (viewportWidth * factor).coerceAtMost(2600).coerceAtLeast(200)
    }

    override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
        return when (val item = items[position]) {
            is PageItem -> pageView(item, convertView as? ImageView, parent)
            is TextItem -> textView(item, convertView as? TextView, parent)
            is InlineImageItem -> inlineImageView(item, convertView as? ImageView, parent)
        }
    }

    private fun filterFor() = if (doc.isPhoto && !tintPhotos) null else theme.bitmapFilter()

    private fun pageView(item: PageItem, convert: ImageView?, parent: ViewGroup): View {
        val v = convert ?: ImageView(parent.context).apply { scaleType = ImageView.ScaleType.FIT_XY }
        val h = (pageWidth.toLong() * item.height / item.width).toInt().coerceAtLeast(1)
        v.layoutParams = AbsListView.LayoutParams(pageWidth, h)
        v.setBackgroundColor(theme.page)
        v.colorFilter = filterFor()
        bind(v, "p${item.index}", renderBucket(), { w -> doc.renderPage(item, w) })
        return v
    }

    private fun inlineImageView(item: InlineImageItem, convert: ImageView?, parent: ViewGroup): View {
        val v = convert ?: ImageView(parent.context).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        val pad = dp(parent, 12)
        v.setPadding(pad, pad / 2, pad, pad / 2)
        v.layoutParams = AbsListView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        v.setBackgroundColor(theme.page)
        v.colorFilter = theme.bitmapFilter()
        v.maxHeight = parent.height.coerceAtLeast(dp(parent, 300)) * 2
        bind(v, "i${item.key}", viewportWidth, { w -> doc.loadInlineImage(item.key, w) })
        return v
    }

    /** Асинхронне завантаження бітмапа в ImageView з кешем. */
    private fun bind(v: ImageView, baseKey: String, width: Int, load: (Int) -> Bitmap?) {
        (v.getTag(TAG_JOB) as? Job)?.cancel()
        val key = "$baseKey@$width"
        v.setTag(TAG_KEY, key)
        val cached = cache.get(key)
        if (cached != null) {
            v.setImageBitmap(cached)
            return
        }
        // поки рендериться потрібна якість – показуємо будь-яку наявну версію
        v.setImageBitmap(cache.snapshot().entries.firstOrNull { it.key.startsWith("$baseKey@") }?.value)
        v.setTag(TAG_JOB, scope.launch {
            val bmp = withContext(renderDispatcher) {
                cache.get(key) ?: try {
                    load(width)
                } catch (e: OutOfMemoryError) {
                    cache.evictAll(); null
                } catch (e: Exception) {
                    null
                }?.also { cache.put(key, it) }
            }
            if (v.getTag(TAG_KEY) == key && bmp != null) v.setImageBitmap(bmp)
        })
    }

    private fun textView(item: TextItem, convert: TextView?, parent: ViewGroup): View {
        val v = convert ?: TextView(parent.context).apply {
            setLineSpacing(0f, 1.25f)
            layoutParams = AbsListView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val padH = dp(parent, 18)
        val padV = if (item.heading > 0) dp(parent, 10) else dp(parent, 4)
        v.setPadding(padH, padV, padH, padV)
        v.setTextSize(TypedValue.COMPLEX_UNIT_SP, baseTextSp * zoom * if (item.tableRow) 0.9f else 1f)
        v.typeface = if (item.tableRow) Typeface.MONOSPACE else Typeface.SERIF
        v.setTextColor(theme.ink)
        v.setBackgroundColor(theme.page)
        v.gravity = when (item.align) {
            TextItem.ALIGN_CENTER -> Gravity.CENTER_HORIZONTAL
            TextItem.ALIGN_END -> Gravity.END
            else -> Gravity.START
        }
        v.justificationMode = if (item.align == TextItem.ALIGN_JUSTIFY) Layout.JUSTIFICATION_MODE_INTER_WORD else Layout.JUSTIFICATION_MODE_NONE
        v.text = item.text
        return v
    }

    private fun dp(v: View, value: Int) = (value * v.resources.displayMetrics.density).toInt()

    companion object {
        private val TAG_JOB = R.id.tag_job
        private val TAG_KEY = R.id.tag_key
    }
}
