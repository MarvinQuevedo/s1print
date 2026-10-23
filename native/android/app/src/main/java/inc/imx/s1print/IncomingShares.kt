package inc.imx.s1print

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File

object IncomingShares {
    fun uris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val streams: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            else -> return emptyList()
        }
        val clip = intent.clipData
        return (streams + (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }).distinct()
    }

    fun store(context: Context) = SharedImportStore(File(context.filesDir, "shared-inbox"))

    fun copy(context: Context, uris: List<Uri>, cancelled: () -> Boolean): List<Uri> {
        require(uris.size in 1..20) { "Share 1 to 20 files at a time" }
        val store = store(context)
        if (uris.isNotEmpty() && uris.all { it.scheme == "file" && store.owns(File(requireNotNull(it.path))) }) return uris
        val files = store.import(uris.map { uri ->
            require(uri.scheme == "content" || (uri.scheme == "file" &&
                File(requireNotNull(uri.path)).canonicalFile.toPath().startsWith(context.cacheDir.canonicalFile.toPath()))) { "Unsupported shared document URI" }
            val name = runCatching {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                }
            }.getOrNull() ?: uri.lastPathSegment ?: "document"
            SharedImportStore.IncomingFile(name) { requireNotNull(context.contentResolver.openInputStream(uri)) { "Cannot read shared document" } }
        }, cancelled)
        return files.map { Uri.fromFile(it) }
    }
}
