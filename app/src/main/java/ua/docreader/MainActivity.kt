package ua.docreader

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsetsController
import android.widget.AbsListView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toolbar
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ua.docreader.doc.DocException
import ua.docreader.doc.Document
import ua.docreader.doc.DocumentLoader
import ua.docreader.ui.PageAdapter
import ua.docreader.ui.ZoomContainer
import java.util.concurrent.Executors
import kotlin.math.abs

class MainActivity : Activity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val renderExecutor = Executors.newSingleThreadExecutor()
    private val renderDispatcher = renderExecutor.asCoroutineDispatcher()

    private lateinit var prefs: SharedPreferences
    private lateinit var toolbar: Toolbar
    private lateinit var content: FrameLayout
    private lateinit var container: ZoomContainer
    private lateinit var list: ListView
    private lateinit var emptyView: LinearLayout
    private lateinit var emptyText: TextView
    private lateinit var progress: ProgressBar
    private lateinit var pageLabel: TextView

    private var doc: Document? = null
    private var adapter: PageAdapter? = null
    private var docKey: String? = null
    private var loadJob: Job? = null

    private var readerTheme = ReaderTheme.DAY
    private var tintPhotos = true
    private var zoom = 1f

    private val hideLabel = Runnable { pageLabel.animate().alpha(0f).setDuration(300).start() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = getSharedPreferences("reader", MODE_PRIVATE)
        readerTheme = ReaderTheme.byName(prefs.getString(KEY_THEME, null))
        tintPhotos = prefs.getBoolean(KEY_TINT_PHOTOS, true)
        DocumentLoader.clearCache(this)
        buildUi()
        applyTheme()

        if (!handleIntent(intent)) {
            // відкриваємо останній документ
            val last = prefs.getString(KEY_LAST, null)
            if (!last.isNullOrBlank()) {
                openUris(last.split('\n').map(Uri::parse), silent = true)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun handleIntent(intent: Intent?): Boolean {
        intent ?: return false
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            else -> emptyList()
        }
        if (uris.isEmpty()) return false
        openUris(uris, silent = false)
        return true
    }

    // ---------------------------------------------------------------- UI

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun buildUi() {
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        toolbar = Toolbar(this).apply {
            title = getString(R.string.app_name)
            elevation = dp(2).toFloat()
        }
        root.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setActionBar(toolbar)

        content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        container = ZoomContainer(this)
        list = ListView(this).apply {
            selector = ColorDrawable(0)
            cacheColorHint = 0
            isVerticalScrollBarEnabled = true
            setOnScrollListener(object : AbsListView.OnScrollListener {
                override fun onScrollStateChanged(view: AbsListView, state: Int) {}
                override fun onScroll(view: AbsListView, first: Int, visible: Int, total: Int) = updatePageLabel()
            })
        }
        container.addView(list, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        container.onScale = { f, x, y -> setZoom(zoom * f, x, y) }
        container.onDoubleTap = { x, y ->
            val d = doc
            if (d != null && d.paged) setZoom(if (zoom > 1.05f) 1f else 2.5f, x, y)
        }
        container.addOnLayoutChangeListener { _, l, _, r, _, ol, _, or, _ ->
            if (r - l != or - ol) container.post { relayout() }
        }
        content.addView(container, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        emptyView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32), dp(32), dp(32), dp(32))
        }
        emptyText = TextView(this).apply {
            text = "Відкрийте документ для читання\n\nPDF · DOC · DOCX · RTF · JPG · PNG\n\nМожна вибрати кілька фото одразу – вони відкриються як сторінки."
            textSize = 17f
            gravity = Gravity.CENTER
        }
        emptyView.addView(emptyText)
        val openBtn = Button(this).apply {
            text = "Відкрити файл"
            setOnClickListener { pickFile() }
        }
        emptyView.addView(openBtn, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(24)
        })
        content.addView(emptyView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        progress = ProgressBar(this).apply { visibility = View.GONE }
        content.addView(progress, FrameLayout.LayoutParams(dp(56), dp(56), Gravity.CENTER))

        pageLabel = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 14f
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0xAA000000.toInt())
            }
            alpha = 0f
        }
        content.addView(pageLabel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
            setMargins(dp(16), dp(16), dp(16), dp(16))
        })

        setContentView(root)
        showEmpty(true)
    }

    private fun showEmpty(empty: Boolean) {
        emptyView.visibility = if (empty) View.VISIBLE else View.GONE
        container.visibility = if (empty) View.GONE else View.VISIBLE
    }

    @Suppress("DEPRECATION")
    private fun applyTheme() {
        val t = readerTheme
        toolbar.setBackgroundColor(t.bar)
        toolbar.setTitleTextColor(t.barText)
        toolbar.setSubtitleTextColor((t.barText and 0x00FFFFFF) or 0xB0000000.toInt())
        toolbar.overflowIcon?.mutate()?.setTint(t.barText)
        window.statusBarColor = t.bar
        window.navigationBarColor = t.bar
        val light = !ReaderTheme.luminance(t.bar).let { it < 0.5f }
        if (Build.VERSION.SDK_INT >= 30) {
            val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(if (light) mask else 0, mask)
        } else {
            var flags = window.decorView.systemUiVisibility
            flags = if (light) flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            else flags and (View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR).inv()
            window.decorView.systemUiVisibility = flags
        }
        content.setBackgroundColor(t.page)
        emptyText.setTextColor(t.ink)
        styleList()
        adapter?.let {
            it.theme = t
            it.tintPhotos = tintPhotos
            it.notifyDataSetChanged()
        }
        invalidateOptionsMenu()
    }

    private fun styleList() {
        val paged = doc?.paged ?: true
        list.setBackgroundColor(if (paged) readerTheme.outer else readerTheme.page)
        container.setBackgroundColor(if (paged) readerTheme.outer else readerTheme.page)
        list.divider = ColorDrawable(readerTheme.outer)
        list.dividerHeight = if (paged) dp(6) else 0
    }

    // ---------------------------------------------------------------- меню

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        val d = doc
        fun tinted(item: MenuItem, icon: Int) {
            item.icon = getDrawable(icon)?.mutate()?.apply { setTint(readerTheme.barText) }
        }
        menu.add(0, M_OPEN, 0, "Відкрити").also {
            tinted(it, R.drawable.ic_open)
            it.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        }
        menu.add(0, M_THEME, 1, "Колір сторінки").also {
            tinted(it, R.drawable.ic_palette)
            it.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        }
        if (d != null) {
            menu.add(0, M_ZOOM_IN, 2, if (d.paged) "Збільшити" else "Більший шрифт")
            menu.add(0, M_ZOOM_OUT, 3, if (d.paged) "Зменшити" else "Менший шрифт")
            menu.add(0, M_ZOOM_RESET, 4, "Звичайний масштаб")
            if (d.paged && d.items.size > 1) menu.add(0, M_GOTO, 5, "Перейти до сторінки…")
            if (d.isPhoto) {
                menu.add(0, M_TINT, 6, "Застосовувати колір до фото").apply {
                    isCheckable = true
                    isChecked = tintPhotos
                }
            }
            menu.add(0, M_CLOSE, 7, "Закрити документ")
        }
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        val cx = container.width / 2f
        val cy = container.height / 2f
        when (item.itemId) {
            M_OPEN -> pickFile()
            M_THEME -> chooseTheme()
            M_ZOOM_IN -> setZoom(zoom * 1.25f, cx, 0f)
            M_ZOOM_OUT -> setZoom(zoom / 1.25f, cx, 0f)
            M_ZOOM_RESET -> setZoom(1f, cx, cy)
            M_GOTO -> goToPage()
            M_TINT -> {
                tintPhotos = !tintPhotos
                prefs.edit().putBoolean(KEY_TINT_PHOTOS, tintPhotos).apply()
                applyTheme()
            }
            M_CLOSE -> closeDocument()
            else -> return super.onOptionsItemSelected(item)
        }
        return true
    }

    private fun chooseTheme() {
        val themes = ReaderTheme.entries
        val rowAdapter = object : ArrayAdapter<ReaderTheme>(this, android.R.layout.simple_list_item_1, themes) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val v = super.getView(position, convertView, parent) as TextView
                val t = themes[position]
                v.text = (if (t == readerTheme) "✓  " else "     ") + t.title
                v.setTextColor(t.ink)
                v.typeface = Typeface.SERIF
                v.background = GradientDrawable().apply {
                    setColor(t.page)
                    setStroke(dp(1), t.outer)
                    cornerRadius = dp(6).toFloat()
                }
                v.setPadding(dp(16), dp(14), dp(16), dp(14))
                return v
            }
        }
        val listView = ListView(this).apply {
            this.adapter = rowAdapter
            divider = ColorDrawable(0)
            dividerHeight = dp(8)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            clipToPadding = false
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Колір сторінки")
            .setView(listView)
            .setNegativeButton("Скасувати", null)
            .create()
        listView.setOnItemClickListener { _, _, pos, _ ->
            readerTheme = themes[pos]
            prefs.edit().putString(KEY_THEME, readerTheme.name).apply()
            applyTheme()
            dialog.dismiss()
        }
        dialog.show()
    }

    private fun goToPage() {
        val d = doc ?: return
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = "1 – ${d.items.size}"
        }
        val frame = FrameLayout(this).apply {
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(input)
        }
        AlertDialog.Builder(this)
            .setTitle("Перейти до сторінки")
            .setView(frame)
            .setPositiveButton("Перейти") { _, _ ->
                val n = input.text.toString().toIntOrNull() ?: return@setPositiveButton
                list.setSelection((n - 1).coerceIn(0, d.items.size - 1))
            }
            .setNegativeButton("Скасувати", null)
            .show()
    }

    // ---------------------------------------------------------------- відкриття файлів

    private fun pickFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES, arrayOf(
                    "application/pdf",
                    "application/msword",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/rtf", "text/rtf",
                    "image/jpeg", "image/png", "image/*",
                )
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_OPEN)
        } catch (e: Exception) {
            showError("Не знайдено програму для вибору файлів.")
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_OPEN || resultCode != RESULT_OK || data == null) return
        val uris = ArrayList<Uri>()
        val clip = data.clipData
        if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris += it }
        else data.data?.let { uris += it }
        for (u in uris) {
            try {
                contentResolver.takePersistableUriPermission(u, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {
            }
        }
        if (uris.isNotEmpty()) openUris(uris, silent = false)
    }

    private fun openUris(uris: List<Uri>, silent: Boolean) {
        loadJob?.cancel()
        savePosition()
        progress.visibility = View.VISIBLE
        loadJob = scope.launch {
            try {
                val newDoc = withContext(Dispatchers.IO) { DocumentLoader.open(this@MainActivity, uris) }
                val key = uris.joinToString("\n")
                prefs.edit().putString(KEY_LAST, key).apply()
                setDocument(newDoc, key)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: DocException) {
                if (silent) prefs.edit().remove(KEY_LAST).apply() else showError(e.message ?: "Помилка")
            } catch (e: OutOfMemoryError) {
                if (!silent) showError("Файл завеликий – не вистачає пам'яті.")
            } catch (e: Throwable) {
                if (silent) prefs.edit().remove(KEY_LAST).apply()
                else showError("Не вдалося відкрити файл.\n\n${e.javaClass.simpleName}: ${e.message ?: ""}")
            } finally {
                progress.visibility = View.GONE
            }
        }
    }

    private fun setDocument(newDoc: Document, key: String) {
        val old = doc
        if (old != null) scope.launch(renderDispatcher) { old.close() }
        adapter?.clear()

        doc = newDoc
        docKey = key
        val a = PageAdapter(newDoc, scope, renderDispatcher)
        a.theme = readerTheme
        a.tintPhotos = tintPhotos
        adapter = a

        // відновлюємо позицію і масштаб
        val saved = prefs.getString(posKey(key), null)?.split(',')
        zoom = saved?.getOrNull(2)?.toFloatOrNull() ?: 1f
        zoom = clampZoom(zoom)

        toolbar.title = newDoc.title
        toolbar.subtitle = if (newDoc.paged && newDoc.items.size > 1) "${newDoc.items.size} стор." else null
        list.isFastScrollEnabled = newDoc.items.size > 8
        styleList()
        list.adapter = a
        showEmpty(false)
        relayout()
        val first = saved?.getOrNull(0)?.toIntOrNull()
        val top = saved?.getOrNull(1)?.toIntOrNull() ?: 0
        if (first != null && first < newDoc.items.size) list.setSelectionFromTop(first, top)
        else list.setSelection(0)
        container.scrollXAfterLayout(0)
        invalidateOptionsMenu()
    }

    private fun closeDocument() {
        savePosition()
        val old = doc ?: return
        doc = null
        adapter?.clear()
        adapter = null
        list.adapter = null
        scope.launch(renderDispatcher) { old.close() }
        prefs.edit().remove(KEY_LAST).apply()
        toolbar.title = getString(R.string.app_name)
        toolbar.subtitle = null
        showEmpty(true)
        invalidateOptionsMenu()
    }

    private fun showError(msg: String) {
        if (isFinishing) return
        AlertDialog.Builder(this).setTitle("Не вдалося відкрити").setMessage(msg).setPositiveButton("OK", null).show()
    }

    // ---------------------------------------------------------------- масштаб

    private fun clampZoom(z: Float): Float {
        val paged = doc?.paged ?: true
        return if (paged) z.coerceIn(1f, 5f) else z.coerceIn(0.6f, 3f)
    }

    private fun relayout() {
        val a = adapter ?: return
        val d = doc ?: return
        val vw = container.width
        if (vw <= 0) return
        a.viewportWidth = vw
        a.zoom = zoom
        val w = if (d.paged) (vw * zoom).toInt() else vw
        a.pageWidth = w
        val lp = list.layoutParams
        if (lp.width != w) {
            lp.width = w
            list.layoutParams = lp
        }
        a.notifyDataSetChanged()
    }

    private fun setZoom(target: Float, focusX: Float, focusY: Float) {
        val d = doc ?: return
        val newZoom = clampZoom(target)
        if (abs(newZoom - zoom) < 0.001f) return
        val ratio = newZoom / zoom
        val first = list.firstVisiblePosition
        val top = list.getChildAt(0)?.top ?: 0
        val oldScrollX = container.scrollX
        zoom = newZoom
        relayout()
        if (d.paged) {
            list.setSelectionFromTop(first, ((top - focusY) * ratio + focusY).toInt())
            container.scrollXAfterLayout(((oldScrollX + focusX) * ratio - focusX).toInt())
        } else {
            list.setSelectionFromTop(first, top)
        }
    }

    // ---------------------------------------------------------------- позиція

    private fun updatePageLabel() {
        val d = doc ?: return
        val total = d.items.size
        if (total <= 1) return
        val text = if (d.paged) {
            // сторінка, що займає середину екрана
            val mid = list.height / 2
            var page = list.firstVisiblePosition
            for (i in 0 until list.childCount) {
                val c = list.getChildAt(i)
                if (c.top <= mid && c.bottom >= mid) { page = list.firstVisiblePosition + i; break }
            }
            "${page + 1} / $total"
        } else {
            val last = list.lastVisiblePosition
            val pct = if (last >= total - 1) 100 else (list.firstVisiblePosition * 100 / total)
            "$pct%"
        }
        pageLabel.text = text
        pageLabel.animate().cancel()
        pageLabel.alpha = 1f
        pageLabel.removeCallbacks(hideLabel)
        pageLabel.postDelayed(hideLabel, 1500)
    }

    private fun posKey(key: String) = "pos:" + key.hashCode()

    private fun savePosition() {
        val key = docKey ?: return
        if (doc == null) return
        val first = list.firstVisiblePosition
        val top = list.getChildAt(0)?.top ?: 0
        prefs.edit().putString(posKey(key), "$first,$top,$zoom").apply()
    }

    override fun onPause() {
        super.onPause()
        savePosition()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        container.post { relayout() }
    }

    override fun onDestroy() {
        super.onDestroy()
        val d = doc
        doc = null
        scope.cancel()
        renderExecutor.execute { d?.close() }
        renderExecutor.shutdown()
    }

    companion object {
        private const val REQ_OPEN = 1
        private const val KEY_THEME = "theme"
        private const val KEY_TINT_PHOTOS = "tint_photos"
        private const val KEY_LAST = "last_uris"

        private const val M_OPEN = 1
        private const val M_THEME = 2
        private const val M_ZOOM_IN = 3
        private const val M_ZOOM_OUT = 4
        private const val M_ZOOM_RESET = 5
        private const val M_GOTO = 6
        private const val M_TINT = 7
        private const val M_CLOSE = 8
    }
}
