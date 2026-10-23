package inc.imx.s1print

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class DirectPrintService : Service() {
    private val signals = ConcurrentHashMap<Int, CancelSignal>()
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "cancel") { signals.values.forEach { it.cancel() }; if (signals.isEmpty()) stopSelf(); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("printing", "Printing", NotificationManager.IMPORTANCE_LOW))
        fun notification(text: String) = Notification.Builder(this, "printing").setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("S1Print").setContentText(text).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Cancel", PendingIntent.getService(this, 0,
                Intent(this, DirectPrintService::class.java).setAction("cancel"), PendingIntent.FLAG_IMMUTABLE)).build()).build()
        startForeground(1, notification("Connecting to printer…"))
        val signal = CancelSignal(); signals[startId] = signal
        val path = intent?.getStringExtra("job")
        PrinterEngine.executor.execute {
            val result = runCatching {
                val file = File(requireNotNull(path)).canonicalFile
                require(file.parentFile == File(filesDir, "jobs").canonicalFile) { "Invalid job path" }
                try {
                    PrinterEngine.print(this, JSONObject(file.readText()), 1, signal) { p -> manager.notify(1, notification("Sending $p%")) }
                } finally { file.delete() }
                "Printing completed"
            }.getOrElse { it.message ?: "Printing failed" }
            PrinterEngine.prefs(this).edit().putString("lastResult", result).apply()
            signals.remove(startId)
            if (signals.isEmpty()) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() { signals.values.forEach { it.cancel() }; super.onDestroy() }
}
