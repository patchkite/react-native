package io.github.patchkite.reactnative

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Expected values come from sdks/test-fixtures (computed by @patchkite/shared). */
@RunWith(RobolectricTestRunner::class)
class PatchkiteUtilsTest {
  @get:Rule val tmp = TemporaryFolder()

  private val fixturesDir = File(System.getProperty("patchkite.fixtures")!!)
  private val fixtures = JSONObject(File(fixturesDir, "fixtures.json").readText())

  private fun writeFiles(dir: File, files: JSONObject) {
    for (path in files.keys()) File(dir, path).apply { parentFile!!.mkdirs() }.writeText(files.getString(path))
  }

  private fun packageDir(withIgnored: Boolean = false): File {
    val dir = tmp.newFolder("pkg")
    writeFiles(dir, fixtures.getJSONObject("files"))
    if (withIgnored) writeFiles(dir, fixtures.getJSONObject("ignoredFiles"))
    return dir
  }

  @Test fun packageHashMatchesServer() {
    assertEquals(fixtures.getString("packageHash"), PatchkiteUtils.computePackageHash(packageDir()))
  }

  @Test fun packageHashIgnoresJunkAndSignature() {
    val dir = packageDir(withIgnored = true)
    File(dir, PatchkiteUtils.SIGNATURE_FILE).writeText(fixtures.getString("validJwt"))
    assertEquals(fixtures.getString("packageHash"), PatchkiteUtils.computePackageHash(dir))
  }

  @Test fun verifiesValidSignature() {
    val hash = PatchkiteUtils.verifySignature(fixtures.getString("validJwt"), fixtures.getString("publicKeyPem"))
    assertEquals(fixtures.getString("packageHash"), hash)
  }

  @Test fun acceptsPemWithLiteralNewlines() {
    val oneLine = fixtures.getString("publicKeyPem").trim().replace("\n", "\\n")
    assertEquals(fixtures.getString("packageHash"), PatchkiteUtils.verifySignature(fixtures.getString("validJwt"), oneLine))
  }

  @Test fun rejectsSignatureFromOtherKey() {
    assertThrows(IllegalArgumentException::class.java) {
      PatchkiteUtils.verifySignature(fixtures.getString("wrongKeyJwt"), fixtures.getString("publicKeyPem"))
    }
    assertThrows(IllegalArgumentException::class.java) {
      PatchkiteUtils.verifySignature(fixtures.getString("validJwt"), fixtures.getString("otherPublicKeyPem"))
    }
  }

  @Test fun rejectsAlgNone() {
    assertThrows(IllegalArgumentException::class.java) {
      PatchkiteUtils.verifySignature(fixtures.getString("noneAlgJwt"), fixtures.getString("publicKeyPem"))
    }
  }

  @Test fun unzipsAndHashesLikeServer() {
    val zip = File(fixturesDir, "zips/normal.zip")
    assertTrue(PatchkiteUtils.isZip(zip))
    val out = tmp.newFolder("out")
    PatchkiteUtils.unzip(zip, out)
    assertEquals(fixtures.getString("packageHash"), PatchkiteUtils.computePackageHash(out))
  }

  @Test fun blocksZipSlip() {
    val out = tmp.newFolder("slip")
    assertThrows(SecurityException::class.java) { PatchkiteUtils.unzip(File(fixturesDir, "zips/slip.zip"), out) }
    assertFalse(File(out.parentFile, "evil.txt").exists())
  }

  @Test fun rejectsNonZip() {
    assertFalse(PatchkiteUtils.isZip(File(fixturesDir, "fixtures.json")))
  }

  @Test fun childOfStaysInsideDirectory() {
    val dir = tmp.newFolder("base")
    assertNotNull(PatchkiteUtils.childOf(dir, "assets/logo.png"))
    assertNull(PatchkiteUtils.childOf(dir, "../outside.txt"))
    assertNull(PatchkiteUtils.childOf(dir, "assets/../../outside.txt"))
  }

  @Test fun prunesUnverifiedFilesButKeepsRootSignature() {
    val dir = packageDir(withIgnored = true)
    File(dir, PatchkiteUtils.SIGNATURE_FILE).writeText("root")
    File(dir, "nested/${PatchkiteUtils.SIGNATURE_FILE}").writeText("nested")
    PatchkiteUtils.pruneUnverified(dir)
    assertFalse(File(dir, "__MACOSX").exists())
    assertFalse(File(dir, ".DS_Store").exists())
    assertFalse(File(dir, "assets/.DS_Store").exists())
    assertFalse(File(dir, "nested/${PatchkiteUtils.SIGNATURE_FILE}").exists())
    assertTrue(File(dir, PatchkiteUtils.SIGNATURE_FILE).exists())
    assertEquals(fixtures.getString("packageHash"), PatchkiteUtils.computePackageHash(dir))
    // After pruning, the only bundle left is the verified one.
    assertEquals(File(dir, "index.android.bundle"), PatchkiteUtils.findFile(dir, "index.android.bundle"))
  }

  @Test fun appliesBsdiffPatchLikeServer() {
    val out = tmp.newFile("new.bin")
    PatchkiteUtils.bspatch(File(fixturesDir, "bsdiff/old.bin"), File(fixturesDir, "bsdiff/patch.bin"), out)
    assertTrue(File(fixturesDir, "bsdiff/new.bin").readBytes().contentEquals(out.readBytes()))
  }

  @Test fun rejectsCorruptBsdiffPatch() {
    val bad = tmp.newFile("bad.patch").apply { writeBytes(File(fixturesDir, "bsdiff/patch.bin").readBytes().copyOf(40)) }
    assertThrows(Exception::class.java) { PatchkiteUtils.bspatch(File(fixturesDir, "bsdiff/old.bin"), bad, tmp.newFile("x.bin")) }
    val notPatch = tmp.newFile("np.patch").apply { writeText("not a patch") }
    assertThrows(Exception::class.java) { PatchkiteUtils.bspatch(File(fixturesDir, "bsdiff/old.bin"), notPatch, tmp.newFile("y.bin")) }
  }
}
