package inc.imx.s1print

import android.net.Uri

/** Pure UI decisions kept free of Android views so they can be tested directly. */

/** Where the current document comes from. Small enough to survive configuration changes in a Bundle. */
sealed class Source {
    object TestPage : Source()
    data class Document(val uri: Uri) : Source()
    data class Documents(val uris: List<Uri>) : Source()
}

enum class DocumentKind { TEST, PDF, IMAGE, MIXED }

enum class DocumentPhase { NONE, PREPARING, READY, FAILED }

enum class PrinterPhase {
    NEEDS_PERMISSION, PERMISSION_BLOCKED, BLUETOOTH_UNAVAILABLE, BLUETOOTH_OFF,
    NO_PAIRED, CHOOSE, SAVED_MISSING, SELECTED
}

/** Why the Print button is disabled. Null from [printBlock] means printing may start. */
enum class PrintBlock { PRINTING, PERMISSION, BLUETOOTH, NO_PRINTER, NO_DOCUMENT, PREPARING, DOCUMENT_FAILED }

enum class ResultKind { SUCCESS, CANCELED, FAILURE }

data class PrintInputs(
    val permissionGranted: Boolean,
    val bluetoothReady: Boolean,
    val printerSelected: Boolean,
    val document: DocumentPhase,
    val printing: Boolean,
)

fun printBlock(inputs: PrintInputs): PrintBlock? = when {
    inputs.printing -> PrintBlock.PRINTING
    !inputs.permissionGranted -> PrintBlock.PERMISSION
    !inputs.bluetoothReady -> PrintBlock.BLUETOOTH
    !inputs.printerSelected -> PrintBlock.NO_PRINTER
    inputs.document == DocumentPhase.NONE -> PrintBlock.NO_DOCUMENT
    inputs.document == DocumentPhase.PREPARING -> PrintBlock.PREPARING
    inputs.document == DocumentPhase.FAILED -> PrintBlock.DOCUMENT_FAILED
    else -> null
}

fun printerPhase(
    permissionGranted: Boolean,
    permissionBlocked: Boolean,
    adapterPresent: Boolean,
    bluetoothEnabled: Boolean,
    pairedCount: Int,
    selected: Boolean,
    savedMissing: Boolean,
): PrinterPhase = when {
    !permissionGranted -> if (permissionBlocked) PrinterPhase.PERMISSION_BLOCKED else PrinterPhase.NEEDS_PERMISSION
    !adapterPresent -> PrinterPhase.BLUETOOTH_UNAVAILABLE
    !bluetoothEnabled -> PrinterPhase.BLUETOOTH_OFF
    selected -> PrinterPhase.SELECTED
    pairedCount == 0 -> PrinterPhase.NO_PAIRED
    savedMissing -> PrinterPhase.SAVED_MISSING
    else -> PrinterPhase.CHOOSE
}

/** DirectPrintService reports its outcome as a plain string in the "lastResult" preference. */
const val RESULT_COMPLETED = "Printing completed"
const val RESULT_CANCELED = "Canceled"

fun classifyResult(raw: String): ResultKind = when (raw) {
    RESULT_COMPLETED -> ResultKind.SUCCESS
    RESULT_CANCELED -> ResultKind.CANCELED
    else -> ResultKind.FAILURE
}

/**
 * In-process record that a direct print job was handed to DirectPrintService. It survives Activity
 * recreation (the service runs in the same process) and is cleared only when a result is observed.
 */
object PrintTracker {
    @Volatile var inFlight = false
        private set
    @Volatile var printerName: String? = null
        private set

    fun start(printerName: String) { this.printerName = printerName; inFlight = true }
    fun clear() { inFlight = false; printerName = null }
}

/** Integer upscale when at least one full printhead width fits, otherwise a fit-down fraction. */
fun previewScale(availablePixels: Int, contentWidth: Int): Float = when {
    contentWidth <= 0 || availablePixels <= 0 -> 1f
    availablePixels >= contentWidth -> (availablePixels / contentWidth).toFloat()
    else -> availablePixels.toFloat() / contentWidth
}

/** Inclusive row ranges that split [rows] into tiles of at most [tileRows]. */
fun tileRanges(rows: Int, tileRows: Int): List<IntRange> {
    if (rows <= 0 || tileRows <= 0) return emptyList()
    return (0 until rows step tileRows).map { it..minOf(rows, it + tileRows) - 1 }
}
