package inc.imx.s1print

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

/** Version, author, links, credits and the offline MIT license; mirrors the macOS About window. */
class AboutActivity : Activity() {
    private val root by view<FrameLayout>(R.id.aboutRoot)
    private val content by view<LinearLayout>(R.id.aboutContent)
    private val scrim by view<View>(R.id.aboutScrim)
    private val notice by view<TextView>(R.id.aboutNotice)
    private val licenseText by view<TextView>(R.id.aboutLicenseText)
    private val licenseRow by view<View>(R.id.aboutLicenseRow)
    private var insetLeft = 0
    private var insetTop = 0
    private var insetRight = 0
    private var insetBottom = 0
    private var licenseExpanded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_about)
        enableEdgeToEdge(root) { l, t, r, b -> insetLeft = l; insetTop = t; insetRight = r; insetBottom = b; applyInsets() }
        root.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) applyInsets()
        }
        if (Build.VERSION.SDK_INT >= 28) {
            findViewById<View>(R.id.aboutHeading).isAccessibilityHeading = true
        }
        findViewById<View>(R.id.aboutBack).setOnClickListener { finish() }

        findViewById<TextView>(R.id.aboutVersion).text = getString(R.string.about_version, installedVersionName(), installedVersionCode())
        bindLink(R.id.aboutDeveloper, R.drawable.ic_person, R.string.about_developer_name, R.string.about_developer_body, DEVELOPER_URL)
        bindLink(R.id.aboutSource, R.drawable.ic_code, R.string.about_source_title, R.string.about_source_body, REPOSITORY_URL)
        bindLink(R.id.aboutIssue, R.drawable.ic_error, R.string.about_issue_title, R.string.about_issue_body, ISSUES_URL)
        bindLink(R.id.aboutCredit, R.drawable.ic_link, R.string.about_credit_title, R.string.about_credit_body, CREDIT_URL)

        licenseRow.findViewById<ImageView>(R.id.toolIcon).setImageResource(R.drawable.ic_file)
        licenseRow.findViewById<TextView>(R.id.toolTitle).setText(R.string.about_license_title)
        licenseRow.findViewById<TextView>(R.id.toolBody).setText(R.string.about_license_body)
        licenseRow.setOnClickListener { setLicenseExpanded(!licenseExpanded) }
        setLicenseExpanded(savedInstanceState?.getBoolean(STATE_LICENSE_EXPANDED) ?: false)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_LICENSE_EXPANDED, licenseExpanded)
    }

    private fun installedVersionName(): String =
        runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull().orEmpty()

    @Suppress("DEPRECATION")
    private fun installedVersionCode(): Long = runCatching {
        val info = packageManager.getPackageInfo(packageName, 0)
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    }.getOrDefault(0L)

    private fun setLicenseExpanded(expanded: Boolean) {
        licenseExpanded = expanded
        if (expanded && licenseText.text.isEmpty()) {
            // The license ships inside the APK, so it is readable without a network.
            licenseText.text = runCatching { resources.openRawResource(R.raw.license_mit).bufferedReader().use { it.readText() } }
                .getOrElse { getString(R.string.about_license_unavailable) }
        }
        licenseText.visibility = if (expanded) View.VISIBLE else View.GONE
    }

    private fun bindLink(rowId: Int, icon: Int, title: Int, body: Int, url: String) {
        val row = findViewById<View>(rowId)
        row.findViewById<ImageView>(R.id.toolIcon).setImageResource(icon)
        row.findViewById<TextView>(R.id.toolTitle).setText(title)
        row.findViewById<TextView>(R.id.toolBody).setText(body)
        row.setOnClickListener { openLink(url) }
    }

    private fun openLink(url: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: ActivityNotFoundException) {
            notice.text = getString(R.string.about_link_failed, url)
            notice.visibility = View.VISIBLE
        }
    }

    private fun applyInsets() {
        val density = resources.displayMetrics.density
        val usable = root.width - insetLeft - insetRight
        val extra = if (root.width > 0) maxOf(0, (usable - (MAX_CONTENT_DP * density).roundToInt()) / 2) else 0
        val side = (16 * density).roundToInt()
        val params = scrim.layoutParams
        if (params.height != insetTop) { params.height = insetTop; scrim.layoutParams = params }
        content.setPadding(insetLeft + extra + side, insetTop + (8 * density).roundToInt(),
            insetRight + extra + side, insetBottom + (24 * density).roundToInt())
    }

    companion object {
        const val DEVELOPER_URL = "https://github.com/MarvinQuevedo"
        const val REPOSITORY_URL = "https://github.com/MarvinQuevedo/s1print"
        const val ISSUES_URL = "https://github.com/MarvinQuevedo/s1print/issues/new"
        const val CREDIT_URL = "https://github.com/0xMH/fichero-printer"
        private const val MAX_CONTENT_DP = 560
        private const val STATE_LICENSE_EXPANDED = "licenseExpanded"
    }
}
