package ua.docreader.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.widget.ImageView

/** Сторінка-зображення, поверх якої малюються додані анотації. */
@SuppressLint("ViewConstructor", "AppCompatCustomView")
class PageImageView(ctx: Context) : ImageView(ctx) {
    var annotations: List<Annotation>? = null
    var ink: Int = Color.BLACK
    var paper: Int = Color.WHITE

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val list = annotations
        if (!list.isNullOrEmpty()) {
            AnnotationDrawer.draw(canvas, list, width.toFloat(), height.toFloat(), ink, paper)
        }
    }
}
