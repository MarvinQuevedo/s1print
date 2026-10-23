package inc.imx.s1print

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File

/*
 * UI flow tests. They only exercise import, preview, options and navigation: no print job is ever
 * queued and no printer is queried, so they are safe to run without a paired S1.
 */

private val instrumentation: Instrumentation get() = InstrumentationRegistry.getInstrumentation()
private val appContext get() = instrumentation.targetContext

@Suppress("UNCHECKED_CAST")
private fun <T> onMain(block: () -> T): T {
    var result: Any? = null
    instrumentation.runOnMainSync { result = block() }
    return result as T
}

private fun waitUntil(message: String, timeoutMs: Long = 25_000, condition: () -> Boolean) {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
        if (onMain(condition)) return
        Thread.sleep(100)
    }
    fail("Timed out waiting for: $message")
}

private fun launchMain(configure: Intent.() -> Unit = {}): MainActivity {
    val intent = Intent(appContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).apply(configure)
    return instrumentation.startActivitySync(intent) as MainActivity
}

private fun Activity.text(id: Int) = findViewById<TextView>(id).text.toString()
private fun Activity.visible(id: Int) = findViewById<View>(id).visibility == View.VISIBLE
private fun Activity.click(id: Int) = onMain { findViewById<View>(id).performClick() }
private fun str(id: Int, vararg args: Any) = appContext.getString(id, *args)

private fun waitForPreviewReady(activity: Activity) = waitUntil("preview ready") {
    activity.visible(R.id.previewCard) && !activity.visible(R.id.documentProgress)
}

class MainScreenTest {
    private val optionKeys = listOf("density", "fit", "label")
    private val saved = HashMap<String, Any?>()
    private val files = mutableListOf<File>()
    private var activity: MainActivity? = null
    private var inboxBackup: File? = null

    @Before fun saveOptions() {
        val inbox = File(appContext.filesDir, "shared-inbox")
        if (inbox.exists()) {
            inboxBackup = File(appContext.filesDir, "inbox-test-backup-${java.util.UUID.randomUUID()}")
            check(inbox.renameTo(inboxBackup!!))
        }
        val prefs = PrinterEngine.prefs(appContext)
        optionKeys.forEach { saved[it] = prefs.all[it] }
    }

    @After fun restoreOptions() {
        activity?.let { a -> onMain { a.finish() } }
        val editor = PrinterEngine.prefs(appContext).edit()
        optionKeys.forEach { key ->
            when (val value = saved[key]) {
                null -> editor.remove(key)
                is Int -> editor.putInt(key, value)
                is Boolean -> editor.putBoolean(key, value)
            }
        }
        editor.commit()
        files.forEach { it.delete() }
        // Ensure preparation has stopped before restoring the user's persisted inbox.
        instrumentation.waitForIdleSync()
        val barrier = java.util.concurrent.CountDownLatch(1)
        PrinterEngine.executor.execute { barrier.countDown() }
        check(barrier.await(30, java.util.concurrent.TimeUnit.SECONDS))
        File(appContext.filesDir, "shared-inbox").deleteRecursively()
        inboxBackup?.let { check(it.renameTo(File(appContext.filesDir, "shared-inbox"))) }
    }

    private fun start(configure: Intent.() -> Unit = {}) = launchMain(configure).also { activity = it }

    private fun imageFile(valid: Boolean): File {
        val file = File.createTempFile(if (valid) "ui-image-" else "ui-broken-", if (valid) ".png" else ".bin", appContext.cacheDir)
        files += file
        if (valid) {
            val bitmap = Bitmap.createBitmap(120, 60, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE)
            for (x in 10 until 110) for (y in 20 until 40) bitmap.setPixel(x, y, Color.BLACK)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        } else {
            file.writeBytes(ByteArray(64) { it.toByte() })
        }
        return file
    }

    @Test fun testEmptyStateGuidesImportAndDisablesPrint() {
        val a = start()
        assertEquals(str(R.string.document_empty_title), a.text(R.id.documentTitle))
        assertEquals(str(R.string.document_choose), a.text(R.id.documentPrimary))
        assertFalse(a.visible(R.id.previewCard))
        assertFalse(onMain { a.findViewById<View>(R.id.printButton).isEnabled })
        assertTrue(a.text(R.id.helper).isNotBlank())
    }

    @Test fun testTestPageProducesExactPrinterWidthPreview() {
        val a = start()
        a.click(R.id.toolTest)
        waitForPreviewReady(a)
        val preview = a.findViewById<PreviewView>(R.id.preview)
        assertEquals(384, onMain { preview.dotsWide })
        assertTrue(onMain { preview.dotsTall } > 0)
        assertEquals(str(R.string.tool_test_title), a.text(R.id.documentTitle))
        assertTrue(a.text(R.id.previewCaption).contains("384"))
        assertNotNull(onMain { preview.contentDescription })
    }

    @Test fun testImageImportShowsNameAndMetadata() {
        val file = imageFile(valid = true)
        val a = start { action = Intent.ACTION_VIEW; data = Uri.fromFile(file) }
        waitForPreviewReady(a)
        assertEquals(file.name, a.text(R.id.documentTitle))
        assertTrue(a.text(R.id.documentBody).startsWith(str(R.string.kind_image)))
        assertEquals(384, onMain { a.findViewById<PreviewView>(R.id.preview).dotsWide })
    }

    @Test fun testUnsupportedFileShowsErrorStateWithRecovery() {
        val file = imageFile(valid = false)
        val a = start { action = Intent.ACTION_VIEW; data = Uri.fromFile(file) }
        waitUntil("failed state") { a.text(R.id.documentTitle) == str(R.string.document_failed_title) }
        assertEquals(str(R.string.document_try_again), a.text(R.id.documentPrimary))
        assertEquals(str(R.string.document_choose_another), a.text(R.id.documentSecondary))
        assertFalse(a.visible(R.id.previewCard))
        assertFalse(onMain { a.findViewById<View>(R.id.printButton).isEnabled })
    }

    @Test fun testOptionChangesPersistAndRepreparePreview() {
        val a = start()
        a.click(R.id.toolTest)
        waitForPreviewReady(a)
        a.click(R.id.optionsHeader)
        assertTrue(a.visible(R.id.optionsBody))
        // Changing an option must immediately put the document back into preparing state.
        val preparing = onMain {
            a.findViewById<View>(R.id.densityDark).performClick()
            a.findViewById<View>(R.id.documentProgress).visibility == View.VISIBLE
        }
        assertTrue(preparing)
        // Rapid successive changes must settle on the last one.
        a.click(R.id.densityLight)
        a.click(R.id.densityDark)
        assertEquals(2, PrinterEngine.prefs(appContext).getInt("density", -1))
        val fitBefore = PrinterEngine.prefs(appContext).getBoolean("fit", true)
        a.click(R.id.fitSwitch)
        assertEquals(!fitBefore, PrinterEngine.prefs(appContext).getBoolean("fit", true))
        waitForPreviewReady(a)
        val summary = a.text(R.id.optionsSummary)
        assertTrue(summary.contains(str(R.string.density_dark)))
        assertTrue(summary.contains(str(if (fitBefore) R.string.fit_summary_off else R.string.fit_summary_on)))
        assertFalse(onMain { a.findViewById<View>(R.id.printButton).isEnabled && a.visible(R.id.cancelButton) })
    }

    @Test fun testSavedInstanceStateKeepsOnlySmallValues() {
        val a = start()
        a.click(R.id.toolTest)
        waitForPreviewReady(a)
        val state = Bundle()
        onMain { instrumentation.callActivityOnSaveInstanceState(a, state) }
        assertTrue(state.getBoolean("sourceTest"))
        for (key in state.keySet()) {
            @Suppress("DEPRECATION")
            val value = state.get(key)
            if (value is String) assertTrue("$key is too large for a Bundle", value.length < 2000)
        }
    }

    @Test fun testHeaderShowsLogoResourceAndAboutEntryPoints() {
        val a = start()
        assertNotNull(appContext.getDrawable(R.drawable.app_icon))
        assertTrue(a.visible(R.id.aboutButton))
        assertTrue(a.visible(R.id.toolAbout))
        assertEquals(str(R.string.about_open), onMain { a.findViewById<View>(R.id.aboutButton).contentDescription.toString() })
    }
}

class AboutScreenTest {
    private var main: MainActivity? = null
    private var about: AboutActivity? = null

    @After fun close() {
        about?.let { a -> onMain { a.finish() } }
        main?.let { a -> onMain { a.finish() } }
    }

    private fun openAbout(viaToolRow: Boolean): AboutActivity {
        val monitor = instrumentation.addMonitor(AboutActivity::class.java.name, null, false)
        val m = launchMain().also { main = it }
        m.click(if (viaToolRow) R.id.toolAbout else R.id.aboutButton)
        val opened = monitor.waitForActivityWithTimeout(15_000) as? AboutActivity
        instrumentation.removeMonitor(monitor)
        return requireNotNull(opened) { "About screen did not open" }.also { about = it }
    }

    @Test fun testAboutShowsInstalledVersionAuthorAndCredits() {
        val a = openAbout(viaToolRow = false)
        val info = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        waitUntil("about content") { a.text(R.id.aboutVersion).isNotEmpty() }
        assertEquals("S1Print", a.text(R.id.aboutName))
        assertEquals(str(R.string.about_version, info.versionName.orEmpty(), code), a.text(R.id.aboutVersion))
        val developer = onMain { a.findViewById<View>(R.id.aboutDeveloper) }
        assertEquals("Marvin Quevedo", developer.findViewById<TextView>(R.id.toolTitle).text.toString())
        assertEquals("Source Code", onMain { a.findViewById<View>(R.id.aboutSource).findViewById<TextView>(R.id.toolTitle).text.toString() })
        assertEquals("Report an Issue", onMain { a.findViewById<View>(R.id.aboutIssue).findViewById<TextView>(R.id.toolTitle).text.toString() })
        assertEquals("fichero-printer by 0xMH", onMain { a.findViewById<View>(R.id.aboutCredit).findViewById<TextView>(R.id.toolTitle).text.toString() })
        assertEquals("https://github.com/MarvinQuevedo", AboutActivity.DEVELOPER_URL)
        assertEquals("https://github.com/MarvinQuevedo/s1print", AboutActivity.REPOSITORY_URL)
        assertEquals("https://github.com/MarvinQuevedo/s1print/issues/new", AboutActivity.ISSUES_URL)
        assertEquals("https://github.com/0xMH/fichero-printer", AboutActivity.CREDIT_URL)
        assertTrue(str(R.string.about_notice_affiliation).contains("Not affiliated with Luck Jingle or Xiamen Lujiang Technology."))
    }

    @Test fun testOfflineLicenseExpandsAndBackReturnsToMain() {
        val a = openAbout(viaToolRow = true)
        assertFalse(a.visible(R.id.aboutLicenseText))
        a.click(R.id.aboutLicenseRow)
        waitUntil("license text") { a.visible(R.id.aboutLicenseText) }
        val license = a.text(R.id.aboutLicenseText)
        assertTrue(license.contains("MIT License"))
        assertTrue(license.contains("Copyright (c) 2026 Marvin Quevedo"))
        assertTrue(license.contains("Permission is hereby granted"))
        @Suppress("DEPRECATION")
        onMain { a.onBackPressed() }
        waitUntil("about closed") { a.isFinishing || a.isDestroyed }
        val m = requireNotNull(main)
        waitUntil("main visible again") { !m.isFinishing && m.findViewById<View>(R.id.title).isShown }
    }
}

class UiLogicTest {
    @Test fun testPrintBlockReportsFirstBlockingReason() {
        val ready = PrintInputs(true, true, true, DocumentPhase.READY, false)
        assertEquals(null, printBlock(ready))
        assertEquals(PrintBlock.PRINTING, printBlock(ready.copy(printing = true)))
        assertEquals(PrintBlock.PERMISSION, printBlock(ready.copy(permissionGranted = false)))
        assertEquals(PrintBlock.BLUETOOTH, printBlock(ready.copy(bluetoothReady = false)))
        assertEquals(PrintBlock.NO_PRINTER, printBlock(ready.copy(printerSelected = false)))
        assertEquals(PrintBlock.NO_DOCUMENT, printBlock(ready.copy(document = DocumentPhase.NONE)))
        assertEquals(PrintBlock.PREPARING, printBlock(ready.copy(document = DocumentPhase.PREPARING)))
        assertEquals(PrintBlock.DOCUMENT_FAILED, printBlock(ready.copy(document = DocumentPhase.FAILED)))
    }

    @Test fun testPrinterPhaseNeverDropsSavedPrinterSilently() {
        assertEquals(PrinterPhase.NEEDS_PERMISSION, printerPhase(false, false, true, true, 0, false, false))
        assertEquals(PrinterPhase.PERMISSION_BLOCKED, printerPhase(false, true, true, true, 0, false, false))
        assertEquals(PrinterPhase.BLUETOOTH_UNAVAILABLE, printerPhase(true, false, false, false, 0, false, false))
        assertEquals(PrinterPhase.BLUETOOTH_OFF, printerPhase(true, false, true, false, 0, false, false))
        assertEquals(PrinterPhase.SELECTED, printerPhase(true, false, true, true, 2, true, false))
        assertEquals(PrinterPhase.NO_PAIRED, printerPhase(true, false, true, true, 0, false, true))
        assertEquals(PrinterPhase.SAVED_MISSING, printerPhase(true, false, true, true, 2, false, true))
        assertEquals(PrinterPhase.CHOOSE, printerPhase(true, false, true, true, 2, false, false))
    }

    @Test fun testServiceResultsAreClassified() {
        assertEquals(ResultKind.SUCCESS, classifyResult("Printing completed"))
        assertEquals(ResultKind.CANCELED, classifyResult("Canceled"))
        assertEquals(ResultKind.FAILURE, classifyResult("Printer did not answer"))
    }

    @Test fun testPrintTrackerStaysPendingUntilCleared() {
        try {
            PrintTracker.start("S1")
            assertTrue(PrintTracker.inFlight)
            assertEquals("S1", PrintTracker.printerName)
        } finally {
            PrintTracker.clear()
        }
        assertFalse(PrintTracker.inFlight)
    }

    @Test fun testPreviewScaleUsesIntegerUpscaleAndFitsDown() {
        assertEquals(1f, previewScale(384, 384), 0f)
        assertEquals(1f, previewScale(700, 384), 0f)
        assertEquals(2f, previewScale(800, 384), 0f)
        assertEquals(0.5f, previewScale(192, 384), 0f)
    }

    @Test fun testTileRangesCoverEveryRowOnce() {
        val tiles = tileRanges(2500, 1024)
        assertEquals(3, tiles.size)
        assertEquals(0, tiles.first().first)
        assertEquals(2499, tiles.last().last)
        tiles.zipWithNext().forEach { (a, b) -> assertEquals(a.last + 1, b.first) }
        assertTrue(tiles.all { it.last - it.first + 1 <= 1024 })
        assertTrue(tileRanges(0, 1024).isEmpty())
    }

    @Test fun testVeryLongPreviewIsTiledAndMeasuredWithoutOversizedBitmap() {
        val view = onMain { PreviewView(appContext) }
        val tall = Bitmap.createBitmap(384, 20_000, Bitmap.Config.ARGB_8888)
        try {
            onMain {
                view.setPreview(tall)
                view.measure(View.MeasureSpec.makeMeasureSpec(384, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
            }
            assertEquals(20, onMain { view.tileCount })
            assertEquals(20_000, onMain { view.measuredHeight })
            // Narrower than the printhead: fit down instead of overflowing.
            onMain { view.measure(View.MeasureSpec.makeMeasureSpec(192, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED) }
            assertEquals(10_000, onMain { view.measuredHeight })
        } finally {
            onMain { view.release() }
        }
        assertEquals(0, onMain { view.tileCount })
    }
}
