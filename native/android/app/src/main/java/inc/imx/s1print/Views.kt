package inc.imx.s1print

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.view.View
import android.view.View.MeasureSpec
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.LinearLayout
import android.widget.RadioGroup
import kotlin.math.ceil
import kotlin.math.roundToInt

/** Lazily looks up a view by id once the content view is set. */
internal fun <T : View> Activity.view(id: Int) = lazy(LazyThreadSafetyMode.NONE) { findViewById<T>(id) }

/**
 * Lays the window out edge-to-edge and reports system bar plus display cutout insets to [onInsets].
 * API 30+ uses the insets API; before that only the status bar is drawn behind and the navigation bar
 * keeps the theme color (a dark bar on API 26, a light bar from API 27).
 */
@Suppress("DEPRECATION")
internal fun Activity.enableEdgeToEdge(root: View, onInsets: (left: Int, top: Int, right: Int, bottom: Int) -> Unit) {
    if (Build.VERSION.SDK_INT >= 30) {
        window.setDecorFitsSystemWindows(false)
    } else {
        val decor = window.decorView
        decor.systemUiVisibility = decor.systemUiVisibility or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
    }
    root.setOnApplyWindowInsetsListener { _, insets ->
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            onInsets(bars.left, bars.top, bars.right, bars.bottom)
        } else {
            onInsets(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
        }
        insets
    }
    root.requestApplyInsets()
}

/**
 * Switches a LinearLayout between horizontal and vertical so children never need to truncate:
 * if their natural widths do not fit on one line (small screens, large fonts), they stack
 * full-width instead.
 */
private fun LinearLayout.adaptOrientation(widthSpec: Int, equalWidths: Boolean) {
    val gap = (8 * resources.displayMetrics.density).roundToInt()
    val available = MeasureSpec.getSize(widthSpec) - paddingLeft - paddingRight
    var widest = 0
    var total = 0
    var count = 0
    for (i in 0 until childCount) {
        val child = getChildAt(i)
        if (child.visibility == View.GONE) continue
        child.measure(MeasureSpec.UNSPECIFIED, MeasureSpec.UNSPECIFIED)
        widest = maxOf(widest, child.measuredWidth)
        total += child.measuredWidth
        count++
    }
    val needed = (if (equalWidths) widest * count else total) + gap * maxOf(0, count - 1)
    val vertical = MeasureSpec.getMode(widthSpec) != MeasureSpec.UNSPECIFIED && needed > available
    val target = if (vertical) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
    if (orientation != target) orientation = target
    var index = 0
    for (i in 0 until childCount) {
        val child = getChildAt(i)
        if (child.visibility == View.GONE) continue
        val params = child.layoutParams as LinearLayout.LayoutParams
        if (vertical) {
            params.width = ViewGroup.LayoutParams.MATCH_PARENT
            params.weight = 0f
            params.leftMargin = 0
            params.topMargin = if (index > 0) gap else 0
        } else {
            params.width = if (equalWidths) 0 else ViewGroup.LayoutParams.WRAP_CONTENT
            params.weight = if (equalWidths) 1f else 0f
            params.leftMargin = if (index > 0) gap else 0
            params.topMargin = 0
        }
        index++
    }
}

/** A row of buttons that wraps into a full-width column when it does not fit. */
class ActionRow @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : LinearLayout(context, attrs) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        adaptOrientation(widthMeasureSpec, equalWidths = false)
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}

/** A segmented radio group of equal-width options that stacks vertically when it does not fit. */
class SegmentGroup @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : RadioGroup(context, attrs) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        adaptOrientation(widthMeasureSpec, equalWidths = true)
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}

/**
 * Draws the 1-bit printer preview. The source bitmap is split into tiles of at most [TILE_ROWS] rows
 * so that very long output never creates a bitmap taller than the GPU texture limit, and only tiles
 * intersecting the clip are drawn. Scaling is nearest-neighbor: integer upscale when there is room,
 * fit-down when the available width is smaller than the printhead width.
 */
class PreviewView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private class Tile(val bitmap: Bitmap, val top: Int)

    private val paint = Paint().apply { isFilterBitmap = false; isAntiAlias = false; isDither = false }
    private val target = Rect()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var tiles = emptyList<Tile>()
    private var scale = 1f

    var dotsWide = 0
        private set
    var dotsTall = 0
        private set
    val tileCount: Int get() = tiles.size

    /** Takes ownership of [bitmap] (it is recycled after slicing) and shows it, or clears the view when null. */
    fun setPreview(bitmap: Bitmap?) {
        val created = ArrayList<Tile>()
        try {
            if (bitmap != null) {
                for (range in tileRanges(bitmap.height, TILE_ROWS)) {
                    val slice = Bitmap.createBitmap(bitmap, 0, range.first, bitmap.width, range.last - range.first + 1)
                    created += Tile(slice, range.first)
                }
            }
        } catch (e: Throwable) {
            created.forEach { it.bitmap.recycle() }
            throw e
        } finally {
            if (bitmap != null && created.none { it.bitmap === bitmap }) bitmap.recycle()
        }
        retire(tiles)
        tiles = created
        dotsWide = bitmap?.width ?: 0
        dotsTall = bitmap?.height ?: 0
        requestLayout()
        invalidate()
    }

    /** Releases all bitmaps. Call when the owning screen is destroyed. */
    fun release() {
        retire(tiles)
        tiles = emptyList()
        dotsWide = 0
        dotsTall = 0
    }

    // Recycling is delayed so a frame that already recorded these bitmaps can finish rendering first.
    private fun retire(old: List<Tile>) {
        if (old.isEmpty()) return
        mainHandler.postDelayed({ old.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() } }, RECYCLE_DELAY_MS)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val mode = MeasureSpec.getMode(widthMeasureSpec)
        val size = MeasureSpec.getSize(widthMeasureSpec)
        if (dotsWide == 0 || dotsTall == 0) {
            scale = 1f
            setMeasuredDimension(if (mode == MeasureSpec.UNSPECIFIED) 0 else size, 0)
            return
        }
        val available = if (mode == MeasureSpec.UNSPECIFIED) dotsWide else size
        scale = previewScale(available, dotsWide)
        val width = if (mode == MeasureSpec.UNSPECIFIED) ceil(dotsWide * scale).toInt() else size
        setMeasuredDimension(width, ceil(dotsTall * scale).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        if (tiles.isEmpty()) return
        val clip = canvas.clipBounds
        val left = (width - (dotsWide * scale).roundToInt()) / 2
        val right = left + (dotsWide * scale).roundToInt()
        for (tile in tiles) {
            val top = (tile.top * scale).roundToInt()
            val bottom = ((tile.top + tile.bitmap.height) * scale).roundToInt()
            if (bottom < clip.top || top > clip.bottom) continue
            target.set(left, top, right, bottom)
            canvas.drawBitmap(tile.bitmap, null, target, paint)
        }
    }

    private companion object {
        const val TILE_ROWS = 1024
        const val RECYCLE_DELAY_MS = 500L
    }
}
