package io.github.patchkite.reactnative

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.text.Normalizer
import java.util.zip.ZipInputStream

internal object PatchkiteUtils {
  const val SIGNATURE_FILE = ".patchkiterelease"
  const val DIFF_MANIFEST_FILE = "patchkite-diff.json"
  /** Folder of bsdiff patches in a diff zip (`.patchkite-patches/<file path>`). */
  const val PATCH_DIR = ".patchkite-patches"
  private const val BSDIFF_MAGIC = "PATCHK01"
  private val IGNORED = setOf(".DS_Store", "__MACOSX", SIGNATURE_FILE)

  fun log(message: String) = android.util.Log.d("Patchkite", "[Patchkite] $message")

  fun sha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

  fun sha256File(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    FileInputStream(file).use { input ->
      val buf = ByteArray(64 * 1024)
      while (true) {
        val n = input.read(buf)
        if (n < 0) break
        digest.update(buf, 0, n)
      }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
  }

  /** Same algorithm as `packageHashFromManifest` in @patchkite/shared. */
  fun computePackageHash(dir: File): String {
    val entries = dir.walkTopDown()
      .filter { it.isFile }
      .filter { it.relativeTo(dir).invariantSeparatorsPath.split("/").none { seg -> seg in IGNORED } }
      // NFC paths, same as @patchkite/shared (iOS stores file names as NFD).
      .map { Normalizer.normalize(it.relativeTo(dir).invariantSeparatorsPath, Normalizer.Form.NFC) to it }
      .sortedBy { it.first }
      .map { (rel, file) -> "$rel:${sha256File(file)}" }
      .toList()
    return sha256Hex(JSONArray(entries).toString().replace("\\/", "/").toByteArray(Charsets.UTF_8))
  }

  /** Limit on total extracted zip contents (zip bomb protection). */
  private const val MAX_EXTRACTED_BYTES = 1L shl 30

  fun unzip(zip: File, dest: File) {
    dest.mkdirs()
    val root = dest.canonicalPath + File.separator
    var extracted = 0L
    val buffer = ByteArray(64 * 1024)
    ZipInputStream(FileInputStream(zip)).use { zis ->
      while (true) {
        val entry = zis.nextEntry ?: break
        val out = File(dest, entry.name)
        if (!out.canonicalPath.startsWith(root)) throw SecurityException("Zip entry outside the target directory: ${entry.name}")
        if (entry.isDirectory) out.mkdirs()
        else {
          out.parentFile?.mkdirs()
          FileOutputStream(out).use { os ->
            while (true) {
              val read = zis.read(buffer)
              if (read < 0) break
              extracted += read
              if (extracted > MAX_EXTRACTED_BYTES) throw SecurityException("Package contents exceed the size limit")
              os.write(buffer, 0, read)
            }
          }
        }
      }
    }
  }

  /** The file `relative` inside `dir`, or null if the path escapes `dir` (e.g. "../x" from a malicious diff). */
  fun childOf(dir: File, relative: String): File? {
    val f = File(dir, relative)
    return f.takeIf { it.canonicalPath.startsWith(dir.canonicalPath + File.separator) }
  }

  /**
   * Removes files excluded from the package hash (except the root signature),
   * so unverified files can't be loaded as part of the bundle.
   */
  fun pruneUnverified(dir: File) {
    dir.walkBottomUp().filter { it != dir && it.exists() }.forEach { f ->
      val rel = f.relativeTo(dir).invariantSeparatorsPath
      if (rel != SIGNATURE_FILE && rel.split("/").any { it in IGNORED }) f.deleteRecursively()
    }
  }

  /**
   * Applies a Patchkite-format bsdiff patch (see packages/shared/src/bsdiff.ts) in streaming fashion:
   * the old file is read block by block and the result is written directly to `out`.
   */
  fun bspatch(old: File, patch: File, out: File) {
    RandomAccessFile(old, "r").use { oldFile ->
      DataInputStream(BufferedInputStream(FileInputStream(patch), 64 * 1024)).use { p ->
        val magic = ByteArray(8)
        p.readFully(magic)
        require(String(magic, Charsets.US_ASCII) == BSDIFF_MAGIC) { "Invalid bsdiff patch" }
        val newSize = readLongLE(p)
        require(newSize >= 0) { "Corrupt bsdiff patch" }
        val oldSize = oldFile.length()
        BufferedOutputStream(FileOutputStream(out), 64 * 1024).use { o ->
          val buf = ByteArray(64 * 1024)
          val oldBuf = ByteArray(64 * 1024)
          var oldPos = 0L
          var newPos = 0L
          while (newPos < newSize) {
            val x = readLongLE(p)
            val y = readLongLE(p)
            val z = readLongLE(p)
            require(x >= 0 && y >= 0 && newPos + x + y <= newSize) { "Corrupt bsdiff patch" }
            var left = x
            while (left > 0) {
              val n = minOf(left, buf.size.toLong()).toInt()
              p.readFully(buf, 0, n)
              // Old bytes outside the file are treated as 0, same as the original bspatch.
              java.util.Arrays.fill(oldBuf, 0, n, 0)
              val from = maxOf(oldPos, 0L)
              val to = minOf(oldPos + n, oldSize)
              if (from < to) {
                oldFile.seek(from)
                oldFile.readFully(oldBuf, (from - oldPos).toInt(), (to - from).toInt())
              }
              for (i in 0 until n) buf[i] = (buf[i] + oldBuf[i]).toByte()
              o.write(buf, 0, n)
              oldPos += n
              left -= n
            }
            newPos += x
            left = y
            while (left > 0) {
              val n = minOf(left, buf.size.toLong()).toInt()
              p.readFully(buf, 0, n)
              o.write(buf, 0, n)
              left -= n
            }
            newPos += y
            oldPos += z
          }
        }
      }
    }
  }

  private fun readLongLE(input: DataInputStream): Long = java.lang.Long.reverseBytes(input.readLong())

  fun isZip(file: File): Boolean = FileInputStream(file).use { input ->
    val header = ByteArray(4)
    input.read(header) == 4 && header[0] == 0x50.toByte() && header[1] == 0x4b.toByte() && header[2] == 0x03.toByte() && header[3] == 0x04.toByte()
  }

  fun findFile(dir: File, name: String): File? =
    File(dir, name).takeIf { it.isFile } ?: dir.walkTopDown().firstOrNull { it.isFile && it.name == name }

  /** Verifies the RS256 JWT in `.patchkiterelease`; returns the `contentHash` claim. */
  fun verifySignature(jwt: String, publicKeyPem: String): String {
    val parts = jwt.trim().split(".")
    require(parts.size == 3) { "Invalid signature JWT" }
    val flags = Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
    val header = JSONObject(String(Base64.decode(parts[0], flags)))
    require(header.optString("alg") == "RS256") { "Unsupported signature algorithm" }
    val keyBody = publicKeyPem
      .replace("\\n", "\n") // PEM written on a single line with literal "\n" (e.g. in AndroidManifest)
      .replace(Regex("-----[A-Z ]+-----"), "")
      .replace(Regex("\\s"), "")
    val key = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(Base64.decode(keyBody, Base64.DEFAULT)))
    val verifier = Signature.getInstance("SHA256withRSA")
    verifier.initVerify(key)
    verifier.update("${parts[0]}.${parts[1]}".toByteArray(Charsets.UTF_8))
    require(verifier.verify(Base64.decode(parts[2], flags))) { "Invalid package signature" }
    return JSONObject(String(Base64.decode(parts[1], flags))).getString("contentHash")
  }
}
