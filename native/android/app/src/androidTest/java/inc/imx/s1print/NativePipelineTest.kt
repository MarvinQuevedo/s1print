package inc.imx.s1print

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.print.PageRange
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

@Suppress("DEPRECATION")
class NativePipelineTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    @Test fun testJniProducesExactRasterBlockAndPreview() {
        val bitmap = Bitmap.createBitmap(384, 3, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.BLACK)
        val result = NativeCore.build(JSONArray().put(NativeCore.grayPage(bitmap)), JSONObject()
            .put("density", 1).put("fitContentWidth", false).put("trimBottom", false))
        bitmap.recycle()
        val chunks = result.getJSONArray("chunks")
        val raster = NativeCore.bytes(chunks.getString(3))
        assertTrue(raster.take(8).toByteArray().contentEquals(byteArrayOf(0x1d,0x76,0x30,0,48,0,3,0)))
        assertTrue(raster.drop(8).all { it == 0xff.toByte() })
        val preview = NativeCore.preview(result)
        assertEquals(384, preview.width); assertEquals(3, preview.height)
        assertEquals(Color.BLACK, preview.getPixel(383,2)); preview.recycle()
        assertTrue(NativeCore.bytes(chunks.getString(chunks.length()-1)).contentEquals(byteArrayOf(0x10,0xff.toByte(),0xf1.toByte(),0x45)))
    }
    @Test fun testPdfRenderingAndSelectedPagesReachRust() {
        val file = File.createTempFile("native-test-", ".pdf", instrumentation.targetContext.cacheDir)
        try {
            val pdf = PdfDocument()
            try {
                for (i in 0..1) {
                    val p = pdf.startPage(PdfDocument.PageInfo.Builder(164, 300, i+1).create())
                    p.canvas.drawColor(Color.WHITE)
                    p.canvas.drawRect(20f,30f,140f,90f,Paint().apply { color = Color.BLACK })
                    pdf.finishPage(p)
                }
                file.outputStream().use { pdf.writeTo(it) }
            } finally { pdf.close() }
            val selected = Documents.pdf(file, arrayOf(PageRange(1,1))) { false }
            assertEquals(1, selected.length())
            val result = NativeCore.build(selected, JSONObject().put("density",1))
            assertEquals(1,result.getInt("sourcePages"));assertTrue(result.getJSONObject("preview").getInt("height") > 0)
            val shared = Documents.read(instrumentation.targetContext, android.net.Uri.fromFile(file)) { false }
            assertEquals(2,shared.length())
        } finally { file.delete() }
    }
    @Test fun testInvalidRequestsReturnNativeErrors() {
        val result=JSONObject(NativeCore.processJson("{\"op\":\"build\",\"pages\":[]}"))
        assertFalse(result.getBoolean("ok"));assertTrue(result.has("error"))
    }
    @Test fun testPrintServiceIsRegistered() {
        val info=instrumentation.targetContext.packageManager.getServiceInfo(android.content.ComponentName(instrumentation.targetContext,S1PrintService::class.java),0)
        assertEquals("android.permission.BIND_PRINT_SERVICE",info.permission)
        assertTrue(info.exported)
    }
}
