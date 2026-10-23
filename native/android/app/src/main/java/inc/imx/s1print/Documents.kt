package inc.imx.s1print

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.print.PageRange
import org.json.JSONArray
import java.io.File

object Documents {
    const val MAX_PIXELS = 32 * 1024 * 1024
    fun read(context: Context, uri: Uri, cancelled: () -> Boolean): JSONArray =
        readWithLimits(context, uri, MAX_PIXELS, 100, cancelled)

    fun readWithLimits(context: Context, uri: Uri, maxPixels: Int, maxPages: Int, cancelled: () -> Boolean): JSONArray {
        require(maxPixels > 0 && maxPages > 0) { "Shared job exceeds 100 pages or 32 Mi pixels" }
        // Copy content providers to a seekable private file; PdfRenderer requires seeking.
        val file = File.createTempFile("document-", ".input", context.cacheDir)
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Cannot open document" }
                file.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    var total = 0L
                    while (true) {
                        check(!cancelled()) { "Canceled" }
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 64L * 1024 * 1024) { "Document exceeds 64 MiB" }
                        output.write(buffer, 0, count)
                    }
                }
            }
            val magic = file.inputStream().use { input -> ByteArray(5).also { input.read(it) } }
            return if (magic.contentEquals("%PDF-".toByteArray())) pdfWithLimits(file, null, maxPixels, maxPages, cancelled) else image(file, maxPixels)
        } finally { file.delete() }
    }
    fun pdf(file: File, ranges: Array<PageRange>?, cancelled: () -> Boolean): JSONArray =
        pdfWithLimits(file, ranges, MAX_PIXELS, 100, cancelled)

    private fun pdfWithLimits(file: File, ranges: Array<PageRange>?, maxPixels: Int, maxPages: Int, cancelled: () -> Boolean): JSONArray {
        val result = JSONArray()
        var total = 0L
        PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)).use { renderer ->
            require(renderer.pageCount <= maxPages) { "Document exceeds 100 pages" }
            for (i in 0 until renderer.pageCount) {
                if (ranges != null && ranges.none { i >= it.start && i <= it.end }) continue
                check(!cancelled()) { "Canceled" }
                renderer.openPage(i).use { page ->
                    val width = 768
                    val height = maxOf(1, (page.height.toDouble() * width / page.width).toInt())
                    total += width.toLong() * height
                    require(total <= maxPixels) { "Document exceeds 32 Mi pixels" }
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        result.put(NativeCore.grayPage(bitmap))
                    } finally { bitmap.recycle() }
                }
            }
        }
        return result
    }
    private fun image(file: File, maxPixels: Int): JSONArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported image" }
        var sample = 1
        while (bounds.outWidth.toLong() * bounds.outHeight / sample / sample > maxPixels) sample *= 2
        val bitmap = requireNotNull(BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }))
        try { return JSONArray().put(NativeCore.grayPage(bitmap)) } finally { bitmap.recycle() }
    }
    fun testPage(): JSONArray {
        val bitmap = Bitmap.createBitmap(768, 700, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 48f }
        canvas.drawText("S1Print / Rust", 32f, 85f, paint)
        paint.textSize = 30f
        canvas.drawText("Bluetooth test - 384 dots / 203 dpi", 32f, 145f, paint)
        for (i in 0..15) { paint.color = Color.rgb(i*17,i*17,i*17); canvas.drawRect(32f+i*44,200f,76f+i*44,330f,paint) }
        paint.color = Color.BLACK
        for (i in 0..8) canvas.drawRect(32f,380f+i*26,730f,383f+i*26,paint)
        try { return JSONArray().put(NativeCore.grayPage(bitmap)) } finally { bitmap.recycle() }
    }
}
