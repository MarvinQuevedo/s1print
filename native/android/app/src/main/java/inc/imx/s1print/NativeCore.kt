package inc.imx.s1print

import android.graphics.Bitmap
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

object NativeCore {
    init { System.loadLibrary("s1_native") }
    @JvmStatic external fun processJson(input: String): String
    fun call(input: JSONObject): JSONObject {
        val result = JSONObject(processJson(input.toString()))
        check(result.optBoolean("ok")) { result.optString("error", "Native processing failed") }
        check(result.optInt("apiVersion") == 1) { "Unsupported native API version" }
        return result
    }
    fun bytes(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)
    fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    fun grayPage(bitmap: Bitmap): JSONObject {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val gray = ByteArray(pixels.size) { i ->
            val p = pixels[i]
            val a = (p ushr 24) and 255
            val r = ((p ushr 16) and 255) * a / 255 + 255 - a
            val g = ((p ushr 8) and 255) * a / 255 + 255 - a
            val b = (p and 255) * a / 255 + 255 - a
            ((r * 299 + g * 587 + b * 114) / 1000).toByte()
        }
        return JSONObject().put("width", bitmap.width).put("height", bitmap.height).put("dpi", 406).put("pixels", encode(gray))
    }
    fun build(pages: JSONArray, options: JSONObject): JSONObject = call(JSONObject().put("op", "build").put("pages", pages).put("options", options))
    fun preview(result: JSONObject): Bitmap {
        val p = result.getJSONObject("preview")
        val width = p.getInt("width")
        val height = p.getInt("height")
        val bits = bytes(p.getString("rows"))
        val pixels = IntArray(width * height) { i ->
            if ((bits[i / 8].toInt() and (0x80 ushr (i % 8))) != 0) android.graphics.Color.BLACK else android.graphics.Color.WHITE
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }
}
