package ua.docreader.ui

import android.annotation.SuppressLint
import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.HorizontalScrollView

/**
 * Контейнер, що дає горизонтальну прокрутку збільшеного списку сторінок
 * і перехоплює жест «щипок» (pinch) та подвійний дотик.
 */
@SuppressLint("ViewConstructor")
class ZoomContainer(ctx: Context) : HorizontalScrollView(ctx) {
    var onScale: ((factor: Float, focusX: Float, focusY: Float) -> Unit)? = null
    var onDoubleTap: ((x: Float, y: Float) -> Unit)? = null

    private var scaling = false
    private var pendingScrollX = -1

    private val scaleDetector = ScaleGestureDetector(ctx, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            onScale?.invoke(d.scaleFactor, d.focusX, d.focusY)
            return true
        }
    })

    private val gestureDetector = GestureDetector(ctx, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDoubleTap(e: MotionEvent): Boolean {
            onDoubleTap?.invoke(e.x, e.y)
            return true
        }
    })

    init {
        isFillViewport = true
        isHorizontalScrollBarEnabled = true
        overScrollMode = OVER_SCROLL_NEVER
    }

    /** Прокрутити по горизонталі після наступного перерахунку розмітки. */
    fun scrollXAfterLayout(x: Int) {
        pendingScrollX = x.coerceAtLeast(0)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        if (pendingScrollX >= 0) {
            val x = pendingScrollX
            pendingScrollX = -1
            scrollTo(x, 0)
        }
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) scaling = false
        scaleDetector.onTouchEvent(ev)
        gestureDetector.onTouchEvent(ev)
        if (scaleDetector.isInProgress || ev.pointerCount > 1) {
            if (!scaling) {
                scaling = true
                val cancel = MotionEvent.obtain(ev)
                cancel.action = MotionEvent.ACTION_CANCEL
                super.dispatchTouchEvent(cancel)
                cancel.recycle()
            }
            return true
        }
        if (scaling) {
            // решту жесту після щипка ігноруємо, щоб не було ривка прокрутки
            if (ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL) scaling = false
            return true
        }
        return super.dispatchTouchEvent(ev)
    }
}
