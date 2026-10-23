package inc.imx.s1print

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CancelSignal {
    val cancelled = AtomicBoolean(false)
    @Volatile var closeConnection: (() -> Unit)? = null
    fun cancel() { cancelled.set(true); closeConnection?.invoke() }
    fun check() { check(!cancelled.get()) { "Canceled" } }
}
object PrinterEngine {
    val executor = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    fun prefs(context: Context) = context.getSharedPreferences("s1print", Context.MODE_PRIVATE)
    fun options(context: Context, label: Boolean = prefs(context).getBoolean("label", false)): JSONObject = JSONObject()
        .put("density", prefs(context).getInt("density", 1)).put("fitContentWidth", prefs(context).getBoolean("fit", true))
        .put("trimBottom", !label).put("labelPaper", label)
    fun hasPermission(context: Context) = Build.VERSION.SDK_INT < 31 || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    fun paired(context: Context): List<Pair<String, String>> {
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) error("Allow Nearby devices in S1Print settings")
        val adapter = context.getSystemService(BluetoothManager::class.java).adapter ?: error("Bluetooth is unavailable")
        return adapter.bondedDevices.map { (it.name ?: it.address) to it.address }.sortedBy { it.first }
    }
    private class Connection(val socket: BluetoothSocket, val signal: CancelSignal) : AutoCloseable {
        val inbox = LinkedBlockingQueue<Int>()
        val closed = AtomicBoolean(false)
        init {
            Thread({
                try {
                    val buffer = ByteArray(1024)
                    while (!closed.get()) {
                        val n = socket.inputStream.read(buffer)
                        if (n < 0) break
                        for (i in 0 until n) inbox.offer(buffer[i].toInt() and 255)
                    }
                } catch (_: Exception) { } finally { closed.set(true) }
            }, "s1-bluetooth-read").apply { isDaemon = true; start() }
        }
        fun write(bytes: ByteArray) {
            signal.check()
            check(!closed.get()) { "Printer disconnected" }
            for (offset in bytes.indices step 240) {
                signal.check()
                socket.outputStream.write(bytes, offset, minOf(240, bytes.size-offset))
            }
            socket.outputStream.flush()
        }
        fun query(command: ByteArray, minBytes: Int): ByteArray {
            inbox.clear(); write(command)
            val result = java.io.ByteArrayOutputStream()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (System.nanoTime() < deadline) {
                signal.check()
                val b = inbox.poll(50, TimeUnit.MILLISECONDS)
                if (b != null) result.write(b) else if (result.size() >= minBytes) break
                check(!closed.get()) { "Printer disconnected" }
            }
            check(result.size() >= minBytes) { "Printer did not answer" }
            return result.toByteArray()
        }
        fun waitOK(seconds: Long) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
            var previous = -1
            while (System.nanoTime() < deadline) {
                signal.check()
                check(!closed.get()) { "Printer disconnected before confirming completion" }
                val b = inbox.poll(50, TimeUnit.MILLISECONDS) ?: continue
                if (previous == 0x4f && b == 0x4b) return
                previous = b
            }
            error("Printer did not confirm completion. Check the printed receipt before retrying.")
        }
        override fun close() { closed.set(true); runCatching { socket.close() }; signal.closeConnection = null }
    }
    private fun connect(context: Context, signal: CancelSignal, selectedAddress: String? = null): Connection {
        signal.check()
        check(hasPermission(context)) { "Allow Nearby devices in S1Print" }
        val adapter = context.getSystemService(BluetoothManager::class.java).adapter ?: error("Bluetooth is unavailable")
        check(adapter.isEnabled) { "Turn on Bluetooth" }
        val address = selectedAddress ?: prefs(context).getString("address", null) ?: error("Select a paired printer in S1Print")
        val socket = adapter.getRemoteDevice(address).createRfcommSocketToServiceRecord(UUID.fromString("00001101-0000-1000-8000-00805f9b34fb"))
        signal.closeConnection = { runCatching { socket.close() } }
        val timeout = timer.schedule({ runCatching { socket.close() } }, 8, TimeUnit.SECONDS)
        try { socket.connect(); signal.check() } catch (e: Exception) { socket.close(); throw e } finally { timeout.cancel(false) }
        return Connection(socket, signal)
    }
    fun status(context: Context, signal: CancelSignal): String = connect(context, signal).use { c ->
        val commands = NativeCore.call(JSONObject().put("op", "commands"))
        val raw = c.query(NativeCore.bytes(commands.getString("status")), 1)[0].toInt() and 255
        val state = NativeCore.call(JSONObject().put("op", "status").put("raw", raw)).getString("description")
        val battery = c.query(NativeCore.bytes(commands.getString("battery")), 2).last().toInt() and 255
        val model = c.query(NativeCore.bytes(commands.getString("model")), 1).toString(Charsets.UTF_8).trim()
        "$model: $state, battery $battery%"
    }
    fun print(context: Context, job: JSONObject, copies: Int, signal: CancelSignal, progress: (Int) -> Unit) {
        require(copies in 1..99) { "Copies must be 1 to 99" }
        val array = job.getJSONArray("chunks")
        val chunks = (0 until array.length()).map { NativeCore.bytes(array.getString(it)) }
        val commands = NativeCore.call(JSONObject().put("op", "commands"))
        connect(context, signal, job.optString("printerAddress").takeIf { it.isNotEmpty() }).use { c ->
            val raw = c.query(NativeCore.bytes(commands.getString("status")), 1)[0].toInt() and 255
            val state = NativeCore.call(JSONObject().put("op", "status").put("raw", raw))
            check(state.getBoolean("ready") && !state.getBoolean("printing")) { state.getString("description") }
            for (copy in 0 until copies) {
                c.inbox.clear(); c.write(chunks.first()); c.waitOK(3)
                for (i in 1 until chunks.size) {
                    signal.check()
                    if (i == chunks.lastIndex) c.inbox.clear()
                    c.write(chunks[i])
                    progress(((copy * chunks.size + i + 1) * 100) / (copies * chunks.size))
                }
                c.waitOK(90)
                Thread.sleep(1500)
            }
        }
    }
}
