package com.osuedit.osu_edit

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * Shows the app's beatmap library (`<documents>/Songs`, private app storage)
 * in the system Files app, so map folders can be opened there ("Open map
 * folder") and files copied in or out — the phone counterpart of osu!'s
 * "Open song folder".
 *
 * Document IDs are "root" for the library and "root/<path inside it>"
 * below it (an empty ID would make an unusable `.../document/` URI).
 * Hidden entries (names starting with '.', like the library's own
 * `.star_ratings.json`) and sets still being imported (`*.importing`) are
 * not listed.
 */
class LibraryDocumentsProvider : DocumentsProvider() {
    companion object {
        const val ROOT_ID = "library"
        private const val ROOT_DOC = "root"

        fun authority(context: Context) = "${context.packageName}.documents"

        /** The library folder: path_provider's documents directory + `Songs`. */
        fun libraryDir(context: Context) = File(context.getDir("flutter", Context.MODE_PRIVATE), "Songs")

        /** The document ID of [file] inside the library, or null if outside. */
        fun documentIdOf(context: Context, file: File): String? {
            val root = libraryDir(context).canonicalFile
            val f = file.canonicalFile
            if (f == root) return ROOT_DOC
            val rel = f.path.removePrefix(root.path + File.separator)
            return if (rel == f.path) null else "$ROOT_DOC/" + rel.replace(File.separatorChar, '/')
        }

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID, Root.COLUMN_FLAGS, Root.COLUMN_TITLE, Root.COLUMN_SUMMARY,
            Root.COLUMN_DOCUMENT_ID, Root.COLUMN_ICON, Root.COLUMN_AVAILABLE_BYTES,
        )
        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS, Document.COLUMN_SIZE,
        )
    }

    private val root: File get() = libraryDir(context!!).also { it.mkdirs() }

    override fun onCreate(): Boolean = true

    private fun fileOf(documentId: String): File {
        val base = root.canonicalFile
        if (documentId != ROOT_DOC && !documentId.startsWith("$ROOT_DOC/")) throw FileNotFoundException(documentId)
        val rel = documentId.removePrefix(ROOT_DOC).removePrefix("/")
        val f = if (rel.isEmpty()) base else File(base, rel).canonicalFile
        // No escaping the library with "..".
        if (f != base && !f.path.startsWith(base.path + File.separator)) throw FileNotFoundException(documentId)
        return f
    }

    private fun idOf(file: File): String = documentIdOf(context!!, file) ?: throw FileNotFoundException(file.path)

    private fun hidden(file: File) = file.name.startsWith(".") || file.name.endsWith(".importing")

    private fun mimeOf(file: File): String {
        if (file.isDirectory) return Document.MIME_TYPE_DIR
        val ext = file.extension.lowercase()
        return when (ext) {
            "osu", "osb" -> "text/plain"
            "osz" -> "application/x-osu-beatmap-archive"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }

    private fun addRow(cursor: MatrixCursor, file: File) {
        var flags = 0
        if (file.isDirectory) {
            flags = flags or Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            flags = flags or Document.FLAG_SUPPORTS_WRITE
            if (mimeOf(file).startsWith("image/")) flags = flags or Document.FLAG_SUPPORTS_THUMBNAIL
        }
        val isRoot = file.canonicalFile == root.canonicalFile
        if (!isRoot) {
            flags = flags or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
        }
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, idOf(file))
            add(Document.COLUMN_DISPLAY_NAME, if (isRoot) "osuEdit library" else file.name)
            add(Document.COLUMN_MIME_TYPE, mimeOf(file))
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(Document.COLUMN_FLAGS, flags)
            add(Document.COLUMN_SIZE, if (file.isDirectory) null else file.length())
        }
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, ROOT_ID)
            add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD or Root.FLAG_LOCAL_ONLY)
            add(Root.COLUMN_TITLE, "osuEdit")
            add(Root.COLUMN_SUMMARY, "Beatmap library")
            add(Root.COLUMN_DOCUMENT_ID, ROOT_DOC)
            add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            add(Root.COLUMN_AVAILABLE_BYTES, root.freeSpace)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val f = fileOf(documentId)
        if (!f.exists()) throw FileNotFoundException(documentId)
        addRow(cursor, f)
        return cursor
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val dir = fileOf(parentDocumentId)
        for (f in dir.listFiles().orEmpty().sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))) {
            if (!hidden(f)) addRow(cursor, f)
        }
        // DocumentsUI re-queries when the folder changes (files added by the app).
        cursor.setNotificationUri(
            context!!.contentResolver,
            DocumentsContract.buildChildDocumentsUri(authority(context!!), parentDocumentId),
        )
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parent = fileOf(parentDocumentId)
        val child = fileOf(documentId)
        return child.path.startsWith(parent.path + File.separator)
    }

    /**
     * The IDs from the library root (or [parentDocumentId]) down to
     * [childDocumentId]. The Files app needs this to open a given folder
     * (`ACTION_VIEW` of a directory) — without it it falls back to Downloads.
     */
    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String): DocumentsContract.Path {
        val parent = parentDocumentId ?: ROOT_DOC
        if (childDocumentId != parent && !isChildDocument(parent, childDocumentId)) {
            throw FileNotFoundException("$childDocumentId is not inside $parent")
        }
        val ids = ArrayList<String>()
        var id = childDocumentId
        while (true) {
            ids.add(id)
            if (id == parent) break
            id = id.substringBeforeLast('/')
        }
        ids.reverse()
        return DocumentsContract.Path(if (parentDocumentId == null) ROOT_ID else null, ids)
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val f = fileOf(documentId)
        val pfdMode = ParcelFileDescriptor.parseMode(mode)
        if (f.isDirectory) throw FileNotFoundException(documentId)
        val writing = mode.contains('w')
        if (!writing) return ParcelFileDescriptor.open(f, pfdMode)
        // Tell DocumentsUI the folder changed once the writer is done.
        val handler = android.os.Handler(context!!.mainLooper)
        return ParcelFileDescriptor.open(f, pfdMode, handler) { notifyChanged(f.parentFile) }
    }

    override fun openDocumentThumbnail(documentId: String, sizeHint: Point?, signal: CancellationSignal?): AssetFileDescriptor {
        val f = fileOf(documentId)
        val pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(pfd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        val dir = fileOf(parentDocumentId)
        val safe = displayName.replace('/', '_').replace('\\', '_').ifBlank { "untitled" }
        var target = File(dir, safe)
        var n = 2
        while (target.exists()) {
            val dot = safe.lastIndexOf('.')
            target = if (dot > 0 && mimeType != Document.MIME_TYPE_DIR) {
                File(dir, "${safe.substring(0, dot)} ($n)${safe.substring(dot)}")
            } else {
                File(dir, "$safe ($n)")
            }
            n++
        }
        val ok = if (mimeType == Document.MIME_TYPE_DIR) target.mkdir() else target.createNewFile()
        if (!ok) throw FileNotFoundException("Could not create ${target.name}")
        notifyChanged(dir)
        return idOf(target)
    }

    override fun deleteDocument(documentId: String) {
        val f = fileOf(documentId)
        if (documentId == ROOT_DOC) throw UnsupportedOperationException("The library itself can't be deleted")
        if (!f.deleteRecursively()) throw FileNotFoundException("Could not delete $documentId")
        notifyChanged(f.parentFile)
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val f = fileOf(documentId)
        if (documentId == ROOT_DOC) throw UnsupportedOperationException("The library itself can't be renamed")
        val target = File(f.parentFile, displayName.replace('/', '_').replace('\\', '_'))
        if (target.exists() || !f.renameTo(target)) throw FileNotFoundException("Could not rename to $displayName")
        notifyChanged(f.parentFile)
        return idOf(target)
    }

    private fun notifyChanged(dir: File?) {
        val ctx = context ?: return
        val id = dir?.let { documentIdOf(ctx, it) } ?: return
        ctx.contentResolver.notifyChange(DocumentsContract.buildChildDocumentsUri(authority(ctx), id), null)
    }
}
