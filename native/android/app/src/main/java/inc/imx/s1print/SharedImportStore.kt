package inc.imx.s1print

import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Copies a whole share transaction before publishing it; temporary provider grants are not retained. */
class SharedImportStore(private val root: File) {
    data class IncomingFile(val name: String, val open: () -> InputStream)

    fun import(files: List<IncomingFile>, cancelled: () -> Boolean): List<File> {
        require(files.isNotEmpty() && files.size <= 20) { "Share 1 to 20 files at a time" }
        root.mkdirs()
        val id = UUID.randomUUID().toString()
        val stage = File(root, ".$id").apply { mkdirs() }
        val destination = File(root, id)
        var total = 0L
        try {
            val names = files.mapIndexed { index, item ->
                val name = "$index-" + item.name.replace(Regex("[^a-zA-Z0-9._ -]"), "_").take(120).ifBlank { "document" }
                item.open().use { input ->
                    File(stage, name).outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            check(!cancelled()) { "Canceled" }
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= 64L * 1024 * 1024) { "Shared files exceed 64 MiB" }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                name
            }
            File(stage, "manifest").writeText(names.joinToString("\n"))
            check(!cancelled()) { "Canceled" }
            Files.move(stage.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            val pointer = File(root, ".$id.current").apply { writeText(id) }
            Files.move(pointer.toPath(), File(root, "current").toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            // Bound disk usage; imports and document preparation share the engine's serial executor.
            root.listFiles()?.filter { it.isDirectory && !it.name.startsWith('.') && it != destination }
                ?.sortedByDescending { it.lastModified() }?.drop(7)?.forEach { it.deleteRecursively() }
            return names.map { File(destination, it) }
        } catch (error: Throwable) {
            stage.deleteRecursively()
            File(root, ".$id.current").delete()
            if (File(root, "current").takeIf { it.exists() }?.readText() != id) destination.deleteRecursively()
            throw error
        }
    }

    fun latest(): List<File> = runCatching {
        val id = File(root, "current").readText()
        require(UUID.fromString(id).toString() == id)
        val directory = File(root, id)
        File(directory, "manifest").readLines().also { require(it.size in 1..20) }.map { name ->
            require(name.isNotBlank() && File(name).name == name)
            File(directory, name).also { require(it.isFile) }
        }
    }.getOrDefault(emptyList())

    fun owns(file: File): Boolean = file.canonicalFile.toPath().startsWith(root.canonicalFile.toPath())
}
