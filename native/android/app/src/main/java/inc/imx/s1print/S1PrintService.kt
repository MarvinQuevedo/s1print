package inc.imx.s1print

import android.os.Handler
import android.os.Looper
import android.print.PrintAttributes
import android.print.PrinterCapabilitiesInfo
import android.print.PrinterId
import android.print.PrinterInfo
import android.printservice.PrintJob
import android.printservice.PrintService
import android.printservice.PrinterDiscoverySession
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class S1PrintService : PrintService() {
    private val main = Handler(Looper.getMainLooper())
    private val signals = ConcurrentHashMap<String, CancelSignal>()
    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession = object : PrinterDiscoverySession() {
        fun publish() {
            val id = generatePrinterId("s1")
            val caps = PrinterCapabilitiesInfo.Builder(id)
                .addMediaSize(PrintAttributes.MediaSize("roll58", "58 mm roll", 2283, 23622), true)
                .addMediaSize(PrintAttributes.MediaSize("roll80", "80 mm roll (scaled)", 3150, 23622), false)
                .addMediaSize(PrintAttributes.MediaSize("label30", "58 × 30 mm label", 2283, 1181), false)
                .addMediaSize(PrintAttributes.MediaSize("label40", "58 × 40 mm label", 2283, 1575), false)
                .addMediaSize(PrintAttributes.MediaSize("label50", "58 × 50 mm label", 2283, 1969), false)
                .addMediaSize(PrintAttributes.MediaSize("label80", "58 × 80 mm label", 2283, 3150), false)
                .addResolution(PrintAttributes.Resolution("406", "406 dpi", 406, 406), true)
                .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                .setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME).build()
            val configured = PrinterEngine.hasPermission(this@S1PrintService) && PrinterEngine.prefs(this@S1PrintService).contains("address")
            addPrinters(listOf(PrinterInfo.Builder(id, "S1 Bluetooth", if (configured) PrinterInfo.STATUS_IDLE else PrinterInfo.STATUS_UNAVAILABLE)
                .setDescription(if (configured) "Luck Jingle S1" else "Open S1Print to select a paired printer")
                .setCapabilities(caps).build()))
        }
        override fun onStartPrinterDiscovery(priorityList: MutableList<PrinterId>) = publish()
        override fun onStopPrinterDiscovery() {}
        override fun onValidatePrinters(printerIds: MutableList<PrinterId>) = publish()
        override fun onStartPrinterStateTracking(printerId: PrinterId) = publish()
        override fun onStopPrinterStateTracking(printerId: PrinterId) {}
        override fun onDestroy() {}
    }
    override fun onPrintJobQueued(job: PrintJob) {
        val key = job.id.toString()
        val signal = CancelSignal(); signals[key] = signal
        val address = PrinterEngine.prefs(this).getString("address", "")
        val info = job.info
        val descriptor = job.document.data
        if (descriptor == null) { signals.remove(key); job.fail("Cannot read print document"); return }
        job.start()
        PrinterEngine.executor.execute {
            val file = File.createTempFile("spool-", ".pdf", cacheDir)
            val result = runCatching {
                android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input -> file.outputStream().use { out ->
                    val buffer = ByteArray(65536); var total = 0L
                    while (true) {
                        signal.check(); val n = input.read(buffer); if (n < 0) break
                        total += n; require(total <= 64L * 1024 * 1024) { "Document exceeds 64 MiB" }; out.write(buffer, 0, n)
                    }
                } }
                val pages = Documents.pdf(file, info.pages) { signal.cancelled.get() }
                val label = info.attributes?.mediaSize?.id?.startsWith("label") == true
                val prepared = NativeCore.build(pages, PrinterEngine.options(this, label)).put("printerAddress", address)
                PrinterEngine.print(this, prepared, info.copies, signal) { p -> main.post { job.setProgress(p / 100f) } }
            }
            file.delete(); signals.remove(key)
            main.post {
                if (signal.cancelled.get()) job.cancel()
                else if (result.isSuccess) job.complete()
                else job.fail(result.exceptionOrNull()?.message ?: "Printing failed")
            }
        }
    }
    override fun onRequestCancelPrintJob(job: PrintJob) { signals[job.id.toString()]?.cancel() }
    override fun onDestroy() { signals.values.forEach { it.cancel() }; super.onDestroy() }
}
