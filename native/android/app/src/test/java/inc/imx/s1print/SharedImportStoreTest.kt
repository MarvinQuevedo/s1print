package inc.imx.s1print

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files

class SharedImportStoreTest {
    private lateinit var root: File
    private lateinit var store: SharedImportStore
    @Before fun setup() { root = Files.createTempDirectory("s1print-inbox-test-").toFile(); store = SharedImportStore(root) }
    @After fun cleanup() { root.deleteRecursively() }
    private fun item(name: String, text: String) = SharedImportStore.IncomingFile(name) { ByteArrayInputStream(text.toByteArray()) }
    @Test fun preservesOrderAndSurvivesStoreRecreation() {
        val files = store.import(listOf(item("receipt.pdf", "%PDF-test"), item("photo.png", "image"))) { false }
        assertEquals(listOf("%PDF-test", "image"), files.map { it.readText() })
        assertEquals(files, SharedImportStore(root).latest())
        assertTrue(files.all { store.owns(it) })
    }
    @Test fun failedImportKeepsPreviousBatch() {
        val previous = store.import(listOf(item("first.pdf", "first"))) { false }
        val broken = SharedImportStore.IncomingFile("broken.pdf") { error("Provider revoked access") }
        assertThrows(IllegalStateException::class.java) { store.import(listOf(item("second.pdf", "second"), broken)) { false } }
        assertEquals(previous, store.latest())
        assertEquals(1, root.listFiles()!!.count { it.isDirectory })
    }
    @Test fun enforcesFileCountAndCancellation() {
        assertThrows(IllegalArgumentException::class.java) { store.import(emptyList()) { false } }
        assertThrows(IllegalArgumentException::class.java) { store.import(List(21) { item("x", "x") }) { false } }
        assertThrows(IllegalStateException::class.java) { store.import(listOf(item("x", "x"))) { true } }
        assertTrue(store.latest().isEmpty())
    }
    @Test fun enforcesAggregateByteLimitWithoutPublishing() {
        val huge = SharedImportStore.IncomingFile("huge.pdf") { object : InputStream() {
            override fun read(): Int = 0
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int { buffer.fill(0, offset, offset + length); return length }
        } }
        assertThrows(IllegalArgumentException::class.java) { store.import(listOf(huge)) { false } }
        assertTrue(store.latest().isEmpty())
        assertEquals(0, root.listFiles()!!.count { it.isDirectory })
    }
    @Test fun sanitizesPathsAndRejectsCorruptPointer() {
        val files = store.import(listOf(item("../../receipt.pdf", "safe"))) { false }
        assertTrue(files.single().canonicalPath.startsWith(root.canonicalPath + File.separator))
        File(root, "current").writeText("../../outside")
        assertTrue(store.latest().isEmpty())
    }
}
