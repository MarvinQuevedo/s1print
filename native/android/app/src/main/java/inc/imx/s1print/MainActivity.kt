package inc.imx.s1print

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.*
import org.json.JSONObject
import java.io.File

class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var preview: ImageView
    private lateinit var printButton: Button
    private lateinit var devices: Spinner
    private var paired = emptyList<Pair<String, String>>()
    private var prepared: JSONObject? = null
    private var preparing = false
    private val signal = CancelSignal()
    private val preferenceListener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { preferences, key ->
        if (key == "lastResult") runOnUiThread { status.text = preferences.getString("lastResult", "Ready") }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 40, 24, 24) }
        val scroll = ScrollView(this).apply { addView(content) }; setContentView(scroll)
        val spacing = (16 * resources.displayMetrics.density).toInt()
        @Suppress("DEPRECATION")
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            content.setPadding(spacing, insets.systemWindowInsetTop + spacing, spacing, insets.systemWindowInsetBottom + spacing)
            insets
        }
        fun text(value: String) = TextView(this).apply { text = value; textSize = 18f; content.addView(this) }
        fun button(label: String, action: () -> Unit): Button = Button(this).apply { text = label; content.addView(this); setOnClickListener { action() } }
        text("S1Print").textSize = 30f
        text("Pair the S1 in Android Bluetooth settings, then select it below.")
        button("Bluetooth settings") { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
        button("Refresh paired printers") { refresh() }
        devices = Spinner(this); content.addView(devices)
        devices.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent: AdapterView<*>?) {}
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (position > 0 && position - 1 in paired.indices) PrinterEngine.prefs(this@MainActivity).edit().putString("address", paired[position - 1].second).apply()
                else PrinterEngine.prefs(this@MainActivity).edit().remove("address").apply()
            }
        }
        val density = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Light", "Medium", "Dark")) }
        density.setSelection(PrinterEngine.prefs(this).getInt("density", 1)); content.addView(density)
        density.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent: AdapterView<*>?) {}
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                PrinterEngine.prefs(this@MainActivity).edit().putInt("density", position).apply(); invalidatePreview()
            }
        }
        for ((key, label, default) in listOf(Triple("fit", "Fit content to printhead width", true), Triple("label", "Label paper (use gap feed)", false))) {
            val checkbox = CheckBox(this).apply { text = label; isChecked = PrinterEngine.prefs(this@MainActivity).getBoolean(key, default) }
            content.addView(checkbox)
            checkbox.setOnCheckedChangeListener { _, checked -> PrinterEngine.prefs(this).edit().putBoolean(key, checked).apply(); invalidatePreview() }
        }
        button("Check printer status") { background { PrinterEngine.status(this, signal) } }
        button("Enable system printing") { startActivity(Intent(Settings.ACTION_PRINT_SETTINGS)) }
        button("Open PDF or image") { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/pdf", "image/*")), 10) }
        button("Prepare test page") { prepare { Documents.testPage() } }
        printButton = button("Print preview") { printPrepared() }.apply { isEnabled = false }
        status = text(PrinterEngine.prefs(this).getString("lastResult", "Ready") ?: "Ready")
        preview = ImageView(this).apply { adjustViewBounds = true; setBackgroundColor(android.graphics.Color.WHITE); content.addView(this) }
        PrinterEngine.prefs(this).registerOnSharedPreferenceChangeListener(preferenceListener)
        refresh(); receive(intent)
    }
    private fun invalidatePreview() {
        prepared = null
        if (::printButton.isInitialized) printButton.isEnabled = false
    }
    private fun refresh() {
        if (!PrinterEngine.hasPermission(this)) { requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 1); return }
        runCatching {
            paired = PrinterEngine.paired(this)
            devices.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("Select a paired printer…") + paired.map { "${it.first} (${it.second})" })
            val selected = PrinterEngine.prefs(this).getString("address", null)
            val index = paired.indexOfFirst { it.second == selected }.takeIf { it >= 0 }
                ?: paired.indexOfFirst { it.first.startsWith("PPS1") || it.first.startsWith("S1_") }
            devices.setSelection(index + 1)
            if (paired.isEmpty()) status.text = "No paired devices. Pair the S1 in Bluetooth settings."
        }.onFailure { status.text = it.message }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1 && PrinterEngine.hasPermission(this)) refresh()
    }
    private fun background(work: () -> String) {
        status.text = "Working…"
        PrinterEngine.executor.execute { val result = runCatching(work).getOrElse { it.message ?: "Failed" }; runOnUiThread { status.text = result } }
    }
    private fun prepare(pages: () -> org.json.JSONArray) {
        if (preparing) return
        preparing = true; invalidatePreview(); status.text = "Preparing preview…"
        val options = PrinterEngine.options(this)
        PrinterEngine.executor.execute {
            val result = runCatching { val job = NativeCore.build(pages(), options); job to NativeCore.preview(job) }
            runOnUiThread {
                preparing = false
                result.onSuccess { (job, bitmap) -> prepared = job; preview.setImageBitmap(bitmap); printButton.isEnabled = true; status.text = "Preview ready" }
                    .onFailure { status.text = it.message ?: "Cannot prepare document" }
            }
        }
    }
    private fun printPrepared() {
        val job = prepared ?: return
        job.put("printerAddress", PrinterEngine.prefs(this).getString("address", ""))
        if (!PrinterEngine.hasPermission(this)) { refresh(); return }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        val folder = File(filesDir, "jobs").apply { mkdirs() }
        val file = File.createTempFile("job-", ".json", folder).apply { writeText(job.toString()) }
        startForegroundService(Intent(this, DirectPrintService::class.java).putExtra("job", file.path))
        printButton.isEnabled = false; status.text = "Job queued"
    }
    private fun receive(value: Intent?) {
        val uri = if (value?.action == Intent.ACTION_SEND) if (Build.VERSION.SDK_INT >= 33) value.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java) else @Suppress("DEPRECATION") value.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM) else value?.data
        if (uri != null) prepare { Documents.read(this, uri) { signal.cancelled.get() } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); receive(intent) }
    @Deprecated("Activity result API is sufficient for this dependency-free native utility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 10 && resultCode == RESULT_OK) data?.data?.let { uri -> prepare { Documents.read(this, uri) { signal.cancelled.get() } } }
    }
    override fun onDestroy() { signal.cancel(); PrinterEngine.prefs(this).unregisterOnSharedPreferenceChangeListener(preferenceListener); super.onDestroy() }
}
