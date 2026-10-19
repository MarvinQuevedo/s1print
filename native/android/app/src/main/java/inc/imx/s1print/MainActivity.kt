package inc.imx.s1print

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.bluetooth.BluetoothManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import android.text.format.DateFormat
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Switch
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import java.util.Date
import kotlin.math.roundToInt

class MainActivity : Activity() {
    private enum class ButtonKind { PRIMARY, SECONDARY, TEXT }
    private enum class BannerKind { INFO, SUCCESS, ERROR, NEUTRAL }
    private class Banner(val kind: BannerKind, val text: String, val dismissible: Boolean)
    private class Prepared(val job: JSONObject, val bitmap: Bitmap, val name: String, val kind: DocumentKind, val source: Source)

    private val root by view<FrameLayout>(R.id.root)
    private val content by view<LinearLayout>(R.id.content)
    private val statusScrim by view<View>(R.id.statusScrim)
    private val bottomBar by view<LinearLayout>(R.id.bottomBar)
    private val bannerView by view<LinearLayout>(R.id.banner)
    private val bannerIcon by view<ImageView>(R.id.bannerIcon)
    private val bannerText by view<TextView>(R.id.bannerText)
    private val bannerDismiss by view<Button>(R.id.bannerDismiss)
    private val printerTitle by view<TextView>(R.id.printerTitle)
    private val printerBody by view<TextView>(R.id.printerBody)
    private val printerAddress by view<TextView>(R.id.printerAddress)
    private val printerStatus by view<TextView>(R.id.printerStatus)
    private val printerProgress by view<ProgressBar>(R.id.printerProgress)
    private val printerActions by view<View>(R.id.printerActions)
    private val printerPrimary by view<Button>(R.id.printerPrimary)
    private val printerSecondary by view<Button>(R.id.printerSecondary)
    private val documentTitle by view<TextView>(R.id.documentTitle)
    private val documentBody by view<TextView>(R.id.documentBody)
    private val documentProgress by view<ProgressBar>(R.id.documentProgress)
    private val documentActions by view<View>(R.id.documentActions)
    private val documentPrimary by view<Button>(R.id.documentPrimary)
    private val documentSecondary by view<Button>(R.id.documentSecondary)
    private val previewCard by view<View>(R.id.previewCard)
    private val preview by view<PreviewView>(R.id.preview)
    private val previewSpinner by view<ProgressBar>(R.id.previewSpinner)
    private val previewCaption by view<TextView>(R.id.previewCaption)
    private val optionsHeader by view<View>(R.id.optionsHeader)
    private val optionsSummary by view<TextView>(R.id.optionsSummary)
    private val optionsChevron by view<ImageView>(R.id.optionsChevron)
    private val optionsBody by view<View>(R.id.optionsBody)
    private val densityGroup by view<SegmentGroup>(R.id.densityGroup)
    private val fitSwitch by view<Switch>(R.id.fitSwitch)
    private val labelSwitch by view<Switch>(R.id.labelSwitch)
    private val toolTest by view<View>(R.id.toolTest)
    private val toolBluetooth by view<View>(R.id.toolBluetooth)
    private val toolSystem by view<View>(R.id.toolSystem)
    private val toolAbout by view<View>(R.id.toolAbout)
    private val aboutButton by view<View>(R.id.aboutButton)
    private val footer by view<TextView>(R.id.footer)
    private val printProgress by view<ProgressBar>(R.id.printProgress)
    private val helper by view<TextView>(R.id.helper)
    private val printButton by view<Button>(R.id.printButton)
    private val cancelButton by view<Button>(R.id.cancelButton)

    private val handler = Handler(Looper.getMainLooper())
    private var destroyed = false
    private var insetLeft = 0
    private var insetTop = 0
    private var insetRight = 0
    private var insetBottom = 0

    // Document state
    private var source: Source? = null
    private var docPhase = DocumentPhase.NONE
    private var docName = ""
    private var docKind = DocumentKind.IMAGE
    private var docPages = 0
    private var docError: String? = null
    private var prepared: JSONObject? = null
    private var printedOnce = false
    private var generation = 0
    private var prepareSignal: CancelSignal? = null
    private val reprepare = Runnable { source?.let { prepare(it) } }

    // Printer state
    private var paired = emptyList<Pair<String, String>>()
    private var selectedPrinter: Pair<String, String>? = null
    private var savedPrinterMissing = false
    private var adapterPresent = true
    private var bluetoothEnabled = true
    private var permissionAsked = false
    private var permissionBlocked = false
    private var notificationsAsked = false
    private var checking = false
    private var statusText: String? = null
    private var statusError: String? = null
    private var statusSignal: CancelSignal? = null

    // Presentation state
    private var optionsExpanded = false
    private var bannerState: Banner? = null
    private var cancelRequested = false
    private var cancelStalled = false
    private var pickerDialog: AlertDialog? = null
    // After a cancel request with no reported result the job stays pending: the service or Bluetooth
    // transport may still be active, so only the explanatory copy changes and Print stays locked.
    private val cancelStalledNotice = Runnable {
        if (PrintTracker.inFlight) {
            reconcilePrintResult()
            if (PrintTracker.inFlight) { cancelStalled = true; render() }
        }
    }
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == LAST_RESULT && !destroyed) reconcilePrintResult()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        setupWindow()
        bindStaticViews()
        if (savedInstanceState != null) restoreState(savedInstanceState)
        render()
        if (savedInstanceState == null) {
            if (IncomingShares.uris(intent).isNotEmpty()) receive(intent)
            else IncomingShares.store(this).latest().takeIf { it.isNotEmpty() }?.let {
                setSource(Source.Documents(it.map(Uri::fromFile)))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        PrinterEngine.prefs(this).registerOnSharedPreferenceChangeListener(preferenceListener)
        reconcilePrintResult()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onStop() {
        PrinterEngine.prefs(this).unregisterOnSharedPreferenceChangeListener(preferenceListener)
        super.onStop()
    }

    override fun onDestroy() {
        destroyed = true
        handler.removeCallbacksAndMessages(null)
        pickerDialog?.dismiss()
        prepareSignal?.cancel()
        statusSignal?.cancel()
        preview.release()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        // Only small values are saved; the prepared job is rebuilt from the source on recreation.
        when (val current = source) {
            is Source.Document -> outState.putString(STATE_SOURCE_URI, current.uri.toString())
            is Source.Documents -> outState.putStringArrayList("sourceUris", ArrayList(current.uris.map { it.toString() }))
            Source.TestPage -> outState.putBoolean(STATE_SOURCE_TEST, true)
            null -> Unit
        }
        outState.putBoolean(STATE_OPTIONS_EXPANDED, optionsExpanded)
        outState.putBoolean(STATE_PERMISSION_ASKED, permissionAsked)
        outState.putBoolean(STATE_PERMISSION_BLOCKED, permissionBlocked)
        outState.putBoolean(STATE_NOTIFICATIONS_ASKED, notificationsAsked)
    }

    private fun restoreState(state: Bundle) {
        optionsExpanded = state.getBoolean(STATE_OPTIONS_EXPANDED)
        permissionAsked = state.getBoolean(STATE_PERMISSION_ASKED)
        permissionBlocked = state.getBoolean(STATE_PERMISSION_BLOCKED)
        notificationsAsked = state.getBoolean(STATE_NOTIFICATIONS_ASKED)
        val restored = state.getStringArrayList("sourceUris")?.let { Source.Documents(it.map(Uri::parse)) }
            ?: state.getString(STATE_SOURCE_URI)?.let { Source.Document(Uri.parse(it)) }
            ?: if (state.getBoolean(STATE_SOURCE_TEST)) Source.TestPage else null
        if (restored != null) prepare(restored)
    }

    // ---- Window and insets -------------------------------------------------------------------

    private fun setupWindow() {
        enableEdgeToEdge(root, ::updateInsets)
        root.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) applyInsets()
        }
        bottomBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top != oldBottom - oldTop) applyInsets()
        }
    }

    private fun updateInsets(left: Int, top: Int, right: Int, bottom: Int) {
        insetLeft = left; insetTop = top; insetRight = right; insetBottom = bottom
        applyInsets()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()

    private fun applyInsets() {
        // Keep content to a readable column on wide screens while respecting system bar and cutout insets.
        val usable = root.width - insetLeft - insetRight
        val extra = if (root.width > 0) maxOf(0, (usable - dp(MAX_CONTENT_DP)) / 2) else 0
        val left = insetLeft + extra + dp(16)
        val right = insetRight + extra + dp(16)
        val params = statusScrim.layoutParams
        if (params.height != insetTop) { params.height = insetTop; statusScrim.layoutParams = params }
        content.setPadding(left, insetTop + dp(16), right, bottomBar.height + dp(16))
        bottomBar.setPadding(left, dp(12), right, dp(12) + insetBottom)
    }

    // ---- Static wiring -----------------------------------------------------------------------

    private fun bindStaticViews() {
        val prefs = PrinterEngine.prefs(this)
        densityGroup.check(when (prefs.getInt("density", 1)) { 0 -> R.id.densityLight; 2 -> R.id.densityDark; else -> R.id.densityMedium })
        fitSwitch.isChecked = prefs.getBoolean("fit", true)
        labelSwitch.isChecked = prefs.getBoolean("label", false)
        densityGroup.setOnCheckedChangeListener { _, checkedId ->
            val density = when (checkedId) { R.id.densityLight -> 0; R.id.densityDark -> 2; else -> 1 }
            prefs.edit().putInt("density", density).apply()
            onOptionChanged()
        }
        fitSwitch.setOnCheckedChangeListener { _, checked -> prefs.edit().putBoolean("fit", checked).apply(); onOptionChanged() }
        labelSwitch.setOnCheckedChangeListener { _, checked -> prefs.edit().putBoolean("label", checked).apply(); onOptionChanged() }
        optionsHeader.setOnClickListener { optionsExpanded = !optionsExpanded; render() }
        bannerDismiss.setOnClickListener { bannerState = null; render() }
        printButton.setOnClickListener { startPrint() }
        cancelButton.setOnClickListener { cancelPrint() }
        bindTool(toolTest, R.drawable.ic_file, R.string.tool_test_title, R.string.tool_test_body) { setSource(Source.TestPage) }
        bindTool(toolBluetooth, R.drawable.ic_bluetooth, R.string.bluetooth_settings, R.string.tool_bluetooth_body) { openSettings(Settings.ACTION_BLUETOOTH_SETTINGS) }
        bindTool(toolSystem, R.drawable.ic_print, R.string.tool_system_title, R.string.tool_system_body) { openSettings(Settings.ACTION_PRINT_SETTINGS) }
        bindTool(toolAbout, R.drawable.ic_info, R.string.about_title, R.string.tool_about_body) { openAbout() }
        aboutButton.setOnClickListener { openAbout() }
        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull().orEmpty()
        footer.text = getString(R.string.footer_version, version)
        if (Build.VERSION.SDK_INT >= 28) {
            for (id in intArrayOf(R.id.title, R.id.previewTitle)) findViewById<View>(id).isAccessibilityHeading = true
        }
    }

    private fun openAbout() = startActivity(Intent(this, AboutActivity::class.java))

    private fun bindTool(row: View, icon: Int, title: Int, body: Int, action: () -> Unit) {
        row.findViewById<ImageView>(R.id.toolIcon).setImageResource(icon)
        row.findViewById<TextView>(R.id.toolTitle).setText(title)
        row.findViewById<TextView>(R.id.toolBody).setText(body)
        row.setOnClickListener { action() }
    }

    private fun openSettings(action: String, data: Uri? = null) {
        try {
            startActivity(Intent(action).apply { if (data != null) this.data = data })
        } catch (_: ActivityNotFoundException) {
            bannerState = Banner(BannerKind.ERROR, getString(R.string.settings_unavailable), true)
            render()
        }
    }

    // ---- Printer discovery -------------------------------------------------------------------

    private fun refresh() {
        if (destroyed) return
        paired = emptyList()
        selectedPrinter = null
        savedPrinterMissing = false
        adapterPresent = true
        bluetoothEnabled = true
        if (PrinterEngine.hasPermission(this)) {
            permissionBlocked = false
            val adapter = runCatching { getSystemService(BluetoothManager::class.java)?.adapter }.getOrNull()
            if (adapter == null) {
                adapterPresent = false
            } else if (!runCatching { adapter.isEnabled }.getOrDefault(false)) {
                bluetoothEnabled = false
            } else {
                runCatching { PrinterEngine.paired(this) }
                    .onSuccess { paired = it; resolveSelection() }
                    .onFailure { bannerState = Banner(BannerKind.ERROR, getString(R.string.printer_list_error, it.message.orEmpty()), true) }
            }
        } else if (!permissionAsked && !permissionBlocked) {
            permissionAsked = true
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_BLUETOOTH)
        }
        render()
    }

    // The saved address is only replaced by an explicit user choice or when none was ever saved.
    private fun resolveSelection() {
        val prefs = PrinterEngine.prefs(this)
        val saved = prefs.getString("address", null)
        val match = paired.firstOrNull { it.second == saved }
        when {
            match != null -> selectedPrinter = match
            saved == null -> paired.firstOrNull { it.first.startsWith("PPS1") || it.first.startsWith("S1_") }?.let {
                prefs.edit().putString("address", it.second).apply()
                selectedPrinter = it
            }
            else -> savedPrinterMissing = true
        }
    }

    private fun selectPrinter(printer: Pair<String, String>) {
        PrinterEngine.prefs(this).edit().putString("address", printer.second).apply()
        selectedPrinter = printer
        savedPrinterMissing = false
        statusText = null
        statusError = null
        render()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_BLUETOOTH || grantResults.isEmpty()) return
        permissionBlocked = !PrinterEngine.hasPermission(this) &&
            !shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_CONNECT)
        refresh()
    }

    private fun requestBluetoothPermission() {
        permissionAsked = true
        if (Build.VERSION.SDK_INT >= 31) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_BLUETOOTH)
        }
    }

    private fun checkStatus() {
        if (checking || PrintTracker.inFlight) return
        checking = true
        statusError = null
        render()
        val signal = CancelSignal()
        statusSignal = signal
        val app = applicationContext
        PrinterEngine.executor.execute {
            val result = runCatching { PrinterEngine.status(app, signal) }
            runOnUiThread {
                if (destroyed) return@runOnUiThread
                checking = false
                statusSignal = null
                result.onSuccess {
                    statusText = getString(R.string.status_result, it, DateFormat.getTimeFormat(this).format(Date()))
                    statusError = null
                }.onFailure {
                    statusText = null
                    statusError = getString(R.string.status_failed, it.message ?: it.javaClass.simpleName)
                }
                render()
            }
        }
    }

    private fun showPrinterPicker() {
        val items = paired
        val current = selectedPrinter?.second
        val adapter = object : BaseAdapter() {
            override fun getCount() = items.size
            override fun getItem(position: Int) = items[position]
            override fun getItemId(position: Int) = position.toLong()
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val row = convertView ?: LayoutInflater.from(parent.context).inflate(R.layout.item_printer, parent, false)
                val item = items[position]
                row.findViewById<TextView>(R.id.printerName).text = item.first
                row.findViewById<TextView>(R.id.printerAddress).text = item.second
                row.findViewById<View>(R.id.printerSelected).visibility = if (item.second == current) View.VISIBLE else View.INVISIBLE
                return row
            }
        }
        pickerDialog?.dismiss()
        pickerDialog = AlertDialog.Builder(this)
            .setTitle(R.string.picker_title)
            .setAdapter(adapter) { _, which -> selectPrinter(items[which]) }
            .setNeutralButton(R.string.bluetooth_settings) { _, _ -> openSettings(Settings.ACTION_BLUETOOTH_SETTINGS) }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    // ---- Document preparation ----------------------------------------------------------------

    @Deprecated("Activity result API is sufficient for this dependency-free native utility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_OPEN && resultCode == RESULT_OK) data?.data?.let { setSource(Source.Document(it)) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }

    private fun receive(value: Intent?) {
        val uris = IncomingShares.uris(value)
        if (uris.isNotEmpty()) setSource(Source.Documents(uris))
    }

    private fun pickDocument() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/pdf", "image/*"))
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_OPEN)
        } catch (_: ActivityNotFoundException) {
            bannerState = Banner(BannerKind.ERROR, getString(R.string.settings_unavailable), true)
            render()
        }
    }

    private fun setSource(next: Source) {
        docName = ""
        bannerState = null
        preview.setPreview(null)
        prepare(next)
    }

    private fun onOptionChanged() {
        if (source == null) { render(); return }
        // Invalidate any running preparation right away so it cannot apply results for old options.
        generation++
        prepareSignal?.cancel()
        docPhase = DocumentPhase.PREPARING
        docError = null
        handler.removeCallbacks(reprepare)
        handler.postDelayed(reprepare, DEBOUNCE_MS)
        render()
    }

    private fun prepare(next: Source) {
        handler.removeCallbacks(reprepare)
        source = next
        prepareSignal?.cancel()
        val signal = CancelSignal()
        prepareSignal = signal
        val token = ++generation
        val app = applicationContext
        val options = PrinterEngine.options(this)
        docPhase = DocumentPhase.PREPARING
        docError = null
        printedOnce = false
        render()
        PrinterEngine.executor.execute {
            val result = runCatching {
                signal.check()
                val local = when (next) {
                    Source.TestPage -> next
                    is Source.Document -> Source.Document(IncomingShares.copy(app, listOf(next.uri)) { signal.cancelled.get() }.single())
                    is Source.Documents -> Source.Documents(IncomingShares.copy(app, next.uris) { signal.cancelled.get() })
                }
                val (name, kind) = describe(app, local)
                val pages = when (local) {
                    Source.TestPage -> Documents.testPage()
                    is Source.Document -> Documents.read(app, local.uri) { signal.cancelled.get() }
                    is Source.Documents -> org.json.JSONArray().also { combined ->
                        var pixels = 0L
                        for (uri in local.uris) {
                            val items = Documents.readWithLimits(app, uri, Documents.MAX_PIXELS - pixels.toInt(), 100 - combined.length()) { signal.cancelled.get() }
                            for (i in 0 until items.length()) {
                                val page = items.getJSONObject(i)
                                pixels += page.getInt("width").toLong() * page.getInt("height")
                                require(combined.length() < 100 && pixels <= Documents.MAX_PIXELS) { "Shared job exceeds 100 pages or 32 Mi pixels" }
                                combined.put(page)
                            }
                        }
                    }
                }
                signal.check()
                val job = NativeCore.build(pages, options)
                Prepared(job, NativeCore.preview(job), name, kind, local)
            }
            runOnUiThread {
                if (destroyed || token != generation) {
                    result.getOrNull()?.bitmap?.recycle()
                    return@runOnUiThread
                }
                result.onSuccess { applyPrepared(it) }.onFailure { applyFailure(it) }
            }
        }
    }

    private fun describe(context: Context, src: Source): Pair<String, DocumentKind> = when (src) {
        Source.TestPage -> context.getString(R.string.tool_test_title) to DocumentKind.TEST
        is Source.Documents -> if (src.uris.size == 1) describe(context, Source.Document(src.uris.single()))
            else context.getString(R.string.shared_file_count, src.uris.size) to DocumentKind.MIXED
        is Source.Document -> {
            var name: String? = null
            runCatching {
                context.contentResolver.query(src.uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0)
                }
            }
            val storedName = name?.takeIf { it.isNotBlank() } ?: src.uri.lastPathSegment ?: context.getString(R.string.document_default_name)
            val resolved = if (src.uri.scheme == "file" && IncomingShares.store(context).owns(File(requireNotNull(src.uri.path)))) storedName.substringAfter('-') else storedName
            val type = runCatching { context.contentResolver.getType(src.uri) }.getOrNull()
            resolved to if (type == "application/pdf" || resolved.endsWith(".pdf", ignoreCase = true)) DocumentKind.PDF else DocumentKind.IMAGE
        }
    }

    private fun applyPrepared(result: Prepared) {
        try {
            preview.setPreview(result.bitmap)
        } catch (t: Throwable) {
            applyFailure(t)
            return
        }
        source = result.source
        prepared = result.job
        docName = result.name
        docKind = result.kind
        docPages = result.job.optInt("sourcePages", 1)
        docPhase = DocumentPhase.READY
        render()
    }

    private fun applyFailure(error: Throwable) {
        prepared = null
        preview.setPreview(null)
        docError = error.message?.takeIf { it.isNotBlank() }
        docPhase = DocumentPhase.FAILED
        render()
    }

    // ---- Printing ----------------------------------------------------------------------------

    private fun printInputs() = PrintInputs(
        permissionGranted = PrinterEngine.hasPermission(this),
        bluetoothReady = adapterPresent && bluetoothEnabled,
        printerSelected = selectedPrinter != null,
        document = docPhase,
        printing = PrintTracker.inFlight,
    )

    private fun startPrint() {
        val job = prepared ?: return
        val printer = selectedPrinter ?: return
        if (!PrinterEngine.hasPermission(this)) { refresh(); return }
        if (printBlock(printInputs()) != null) return
        if (Build.VERSION.SDK_INT >= 33 && !notificationsAsked &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notificationsAsked = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        job.put("printerAddress", printer.second)
        var file: File? = null
        try {
            val folder = File(filesDir, "jobs").apply { mkdirs() }
            file = File.createTempFile("job-", ".json", folder).apply { writeText(job.toString()) }
            // Clear the previous result so an identical new result still triggers the preference listener.
            PrinterEngine.prefs(this).edit().remove(LAST_RESULT).apply()
            startForegroundService(Intent(this, DirectPrintService::class.java).putExtra("job", file.path))
            PrintTracker.start(printer.first)
            bannerState = null
            cancelRequested = false
        } catch (e: Exception) {
            file?.delete()
            bannerState = Banner(BannerKind.ERROR, getString(R.string.banner_queue_failed, e.message ?: e.javaClass.simpleName), true)
        }
        render()
    }

    private fun cancelPrint() {
        if (!PrintTracker.inFlight || cancelRequested) return
        cancelRequested = true
        startService(Intent(this, DirectPrintService::class.java).setAction("cancel"))
        // The service normally reports "Canceled"; if it stays silent, explain that the job is still pending.
        handler.postDelayed(cancelStalledNotice, CANCEL_NOTICE_MS)
        render()
    }

    /** Applies a service result if a job we queued is still marked in flight. Safe to call repeatedly. */
    private fun reconcilePrintResult() {
        if (!PrintTracker.inFlight) return
        val raw = PrinterEngine.prefs(this).getString(LAST_RESULT, null) ?: run { render(); return }
        PrintTracker.clear()
        cancelRequested = false
        cancelStalled = false
        handler.removeCallbacks(cancelStalledNotice)
        bannerState = when (classifyResult(raw)) {
            ResultKind.SUCCESS -> { printedOnce = true; Banner(BannerKind.SUCCESS, getString(R.string.banner_success), true) }
            ResultKind.CANCELED -> Banner(BannerKind.NEUTRAL, getString(R.string.banner_canceled), true)
            ResultKind.FAILURE -> Banner(BannerKind.ERROR, raw.ifBlank { getString(R.string.banner_failure_fallback) }, true)
        }
        render()
    }

    // ---- Rendering ---------------------------------------------------------------------------

    private fun render() {
        if (destroyed) return
        renderBanner()
        renderPrinter()
        renderDocument()
        renderPreview()
        renderOptions()
        renderTools()
        renderBottomBar()
    }

    private fun View.show(visible: Boolean) { visibility = if (visible) View.VISIBLE else View.GONE }

    private fun styleButton(button: Button, kind: ButtonKind) {
        if (button.tag == kind) return
        button.tag = kind
        when (kind) {
            ButtonKind.PRIMARY -> { button.setBackgroundResource(R.drawable.bg_button_primary); button.setTextColor(getColorStateList(R.color.button_on_primary)) }
            ButtonKind.SECONDARY -> { button.setBackgroundResource(R.drawable.bg_button_secondary); button.setTextColor(getColorStateList(R.color.button_on_light)) }
            ButtonKind.TEXT -> { button.setBackgroundResource(R.drawable.bg_button_text); button.setTextColor(getColorStateList(R.color.button_on_light)) }
        }
    }

    private fun configure(button: Button, label: Int?, kind: ButtonKind = ButtonKind.TEXT, enabled: Boolean = true, action: () -> Unit = {}) {
        if (label == null) { button.show(false); return }
        button.show(true)
        button.setText(label)
        styleButton(button, kind)
        button.isEnabled = enabled
        button.setOnClickListener { action() }
    }

    private fun renderBanner() {
        val active = if (PrintTracker.inFlight) {
            Banner(BannerKind.INFO, getString(if (cancelStalled) R.string.banner_cancel_pending else R.string.banner_printing), false)
        } else bannerState
        bannerView.show(active != null)
        if (active == null) return
        bannerText.text = active.text
        bannerDismiss.show(active.dismissible)
        val (background, icon, tint) = when (active.kind) {
            BannerKind.INFO -> Triple(R.drawable.bg_banner_info, R.drawable.ic_info, R.color.accent)
            BannerKind.SUCCESS -> Triple(R.drawable.bg_banner_success, R.drawable.ic_check, R.color.success)
            BannerKind.ERROR -> Triple(R.drawable.bg_banner_error, R.drawable.ic_error, R.color.error)
            BannerKind.NEUTRAL -> Triple(R.drawable.bg_banner_neutral, R.drawable.ic_info, R.color.muted)
        }
        if (bannerView.tag != active.kind) { bannerView.tag = active.kind; bannerView.setBackgroundResource(background) }
        bannerIcon.setImageResource(icon)
        bannerIcon.imageTintList = getColorStateList(tint)
    }

    private fun renderPrinter() {
        val busy = PrintTracker.inFlight
        val permitted = PrinterEngine.hasPermission(this)
        val phase = printerPhase(permitted, permissionBlocked, adapterPresent, bluetoothEnabled, paired.size, selectedPrinter != null, savedPrinterMissing)
        printerAddress.show(phase == PrinterPhase.SELECTED)
        printerStatus.show(phase == PrinterPhase.SELECTED)
        printerProgress.show(phase == PrinterPhase.SELECTED && checking)
        var title = ""
        var body: String? = null
        when (phase) {
            PrinterPhase.NEEDS_PERMISSION -> {
                title = getString(R.string.printer_permission_title); body = getString(R.string.printer_permission_body)
                configure(printerPrimary, R.string.printer_allow, ButtonKind.PRIMARY) { requestBluetoothPermission() }
                configure(printerSecondary, null)
            }
            PrinterPhase.PERMISSION_BLOCKED -> {
                title = getString(R.string.printer_permission_title); body = getString(R.string.printer_blocked_body)
                configure(printerPrimary, R.string.printer_open_app_settings, ButtonKind.PRIMARY) {
                    openSettings(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                }
                configure(printerSecondary, null)
            }
            PrinterPhase.BLUETOOTH_UNAVAILABLE -> {
                title = getString(R.string.printer_unavailable_title); body = getString(R.string.printer_unavailable_body)
                configure(printerPrimary, null); configure(printerSecondary, null)
            }
            PrinterPhase.BLUETOOTH_OFF -> {
                title = getString(R.string.printer_bt_off_title); body = getString(R.string.printer_bt_off_body)
                configure(printerPrimary, R.string.bluetooth_settings, ButtonKind.PRIMARY) { openSettings(Settings.ACTION_BLUETOOTH_SETTINGS) }
                configure(printerSecondary, null)
            }
            PrinterPhase.NO_PAIRED -> {
                title = getString(R.string.printer_none_title); body = getString(R.string.printer_none_body)
                configure(printerPrimary, R.string.bluetooth_settings, ButtonKind.PRIMARY) { openSettings(Settings.ACTION_BLUETOOTH_SETTINGS) }
                configure(printerSecondary, R.string.refresh) { refresh() }
            }
            PrinterPhase.CHOOSE -> {
                title = getString(R.string.printer_choose_title)
                body = resources.getQuantityString(R.plurals.printer_choose_body, paired.size, paired.size)
                configure(printerPrimary, R.string.printer_choose_action, ButtonKind.PRIMARY) { showPrinterPicker() }
                configure(printerSecondary, null)
            }
            PrinterPhase.SAVED_MISSING -> {
                title = getString(R.string.printer_missing_title); body = getString(R.string.printer_missing_body)
                configure(printerPrimary, R.string.printer_choose_action, ButtonKind.PRIMARY) { showPrinterPicker() }
                configure(printerSecondary, R.string.bluetooth_settings) { openSettings(Settings.ACTION_BLUETOOTH_SETTINGS) }
            }
            PrinterPhase.SELECTED -> {
                val printer = selectedPrinter!!
                title = printer.first
                printerAddress.text = printer.second
                val error = statusError
                printerStatus.text = when {
                    checking -> getString(R.string.status_checking)
                    error != null -> error
                    else -> statusText ?: getString(R.string.status_not_checked)
                }
                printerStatus.setTextColor(getColor(if (error != null && !checking) R.color.error else R.color.muted))
                configure(printerPrimary, R.string.check_status, ButtonKind.SECONDARY, enabled = !checking && !busy) { checkStatus() }
                configure(printerSecondary, R.string.printer_change, ButtonKind.TEXT, enabled = !checking && !busy) { showPrinterPicker() }
            }
        }
        printerTitle.text = title
        printerBody.text = body
        printerBody.show(body != null)
        printerActions.show(printerPrimary.visibility == View.VISIBLE || printerSecondary.visibility == View.VISIBLE)
    }

    private fun renderDocument() {
        val busy = PrintTracker.inFlight
        when (docPhase) {
            DocumentPhase.NONE -> {
                documentTitle.setText(R.string.document_empty_title)
                documentBody.setText(R.string.document_empty_body)
                documentProgress.show(false)
                configure(documentPrimary, R.string.document_choose, ButtonKind.PRIMARY, !busy) { pickDocument() }
                configure(documentSecondary, R.string.document_use_test_page, ButtonKind.TEXT, !busy) { setSource(Source.TestPage) }
            }
            DocumentPhase.PREPARING -> {
                if (docName.isEmpty()) documentTitle.setText(R.string.document_preparing_title) else documentTitle.text = docName
                documentBody.setText(R.string.document_preparing_body)
                documentProgress.show(true)
                configure(documentPrimary, R.string.document_replace, ButtonKind.SECONDARY, !busy) { pickDocument() }
                configure(documentSecondary, null)
            }
            DocumentPhase.READY -> {
                documentTitle.text = docName
                documentBody.text = getString(R.string.document_meta, kindLabel(docKind), pagesLabel(docPages))
                documentProgress.show(false)
                configure(documentPrimary, R.string.document_replace, ButtonKind.SECONDARY, !busy) { pickDocument() }
                if (source == Source.TestPage) configure(documentSecondary, null)
                else configure(documentSecondary, R.string.document_use_test_page, ButtonKind.TEXT, !busy) { setSource(Source.TestPage) }
            }
            DocumentPhase.FAILED -> {
                documentTitle.setText(R.string.document_failed_title)
                documentBody.text = docError ?: getString(R.string.document_failed_fallback)
                documentProgress.show(false)
                configure(documentPrimary, R.string.document_try_again, ButtonKind.PRIMARY, !busy) { source?.let { prepare(it) } }
                configure(documentSecondary, R.string.document_choose_another, ButtonKind.TEXT, !busy) { pickDocument() }
            }
        }
        documentActions.show(documentPrimary.visibility == View.VISIBLE || documentSecondary.visibility == View.VISIBLE)
    }

    private fun kindLabel(kind: DocumentKind) = getString(when (kind) {
        DocumentKind.TEST -> R.string.kind_test
        DocumentKind.PDF -> R.string.kind_pdf
        DocumentKind.IMAGE -> R.string.kind_image
        DocumentKind.MIXED -> R.string.kind_documents
    })

    private fun pagesLabel(pages: Int) = resources.getQuantityString(R.plurals.pages, pages, pages)

    private fun renderPreview() {
        val hasContent = preview.dotsTall > 0
        val show = hasContent && (docPhase == DocumentPhase.READY || docPhase == DocumentPhase.PREPARING)
        previewCard.show(show)
        if (!show) return
        val preparing = docPhase == DocumentPhase.PREPARING
        preview.alpha = if (preparing) 0.4f else 1f
        previewSpinner.show(preparing)
        val pages = pagesLabel(docPages)
        previewCaption.text = getString(R.string.preview_caption, preview.dotsWide, preview.dotsTall, pages)
        preview.contentDescription = getString(R.string.preview_description, preview.dotsWide, preview.dotsTall, pages)
    }

    private fun renderOptions() {
        val prefs = PrinterEngine.prefs(this)
        val density = getString(when (prefs.getInt("density", 1)) { 0 -> R.string.density_light; 2 -> R.string.density_dark; else -> R.string.density_medium })
        val fit = getString(if (prefs.getBoolean("fit", true)) R.string.fit_summary_on else R.string.fit_summary_off)
        val paper = getString(if (prefs.getBoolean("label", false)) R.string.paper_summary_label else R.string.paper_summary_continuous)
        optionsSummary.text = getString(R.string.options_summary, density, fit, paper)
        optionsBody.show(optionsExpanded)
        optionsChevron.rotation = if (optionsExpanded) 180f else 0f
        optionsHeader.contentDescription = getString(R.string.options_header_description, getString(R.string.options_title),
            getString(if (optionsExpanded) R.string.options_expanded else R.string.options_collapsed)) + ". " + optionsSummary.text
        val enabled = !PrintTracker.inFlight
        for (i in 0 until densityGroup.childCount) densityGroup.getChildAt(i).isEnabled = enabled
        fitSwitch.isEnabled = enabled
        labelSwitch.isEnabled = enabled
    }

    private fun renderTools() {
        val enabled = !PrintTracker.inFlight
        toolTest.isEnabled = enabled
        toolTest.alpha = if (enabled) 1f else 0.5f
    }

    private fun renderBottomBar() {
        val printing = PrintTracker.inFlight
        val block = printBlock(printInputs())
        printProgress.show(printing)
        cancelButton.show(printing)
        cancelButton.isEnabled = !cancelRequested
        printButton.isEnabled = block == null
        printButton.text = when {
            printing -> getString(R.string.printing_to, PrintTracker.printerName.orEmpty())
            printedOnce -> getString(R.string.print_again)
            else -> getString(R.string.print)
        }
        helper.text = when (block) {
            PrintBlock.PRINTING -> getString(R.string.helper_printing)
            PrintBlock.PERMISSION -> getString(R.string.helper_permission)
            PrintBlock.BLUETOOTH -> getString(R.string.helper_bluetooth)
            PrintBlock.NO_PRINTER -> getString(R.string.helper_no_printer)
            PrintBlock.NO_DOCUMENT -> getString(R.string.helper_no_document)
            PrintBlock.PREPARING -> getString(R.string.helper_preparing)
            PrintBlock.DOCUMENT_FAILED -> getString(R.string.helper_document_failed)
            null -> getString(R.string.helper_ready, selectedPrinter?.first.orEmpty())
        }
    }

    private companion object {
        const val REQUEST_BLUETOOTH = 1
        const val REQUEST_NOTIFICATIONS = 2
        const val REQUEST_OPEN = 10
        const val LAST_RESULT = "lastResult"
        const val MAX_CONTENT_DP = 560
        const val DEBOUNCE_MS = 250L
        const val CANCEL_NOTICE_MS = 6000L
        const val STATE_SOURCE_URI = "sourceUri"
        const val STATE_SOURCE_TEST = "sourceTest"
        const val STATE_OPTIONS_EXPANDED = "optionsExpanded"
        const val STATE_PERMISSION_ASKED = "permissionAsked"
        const val STATE_PERMISSION_BLOCKED = "permissionBlocked"
        const val STATE_NOTIFICATIONS_ASKED = "notificationsAsked"
    }
}
