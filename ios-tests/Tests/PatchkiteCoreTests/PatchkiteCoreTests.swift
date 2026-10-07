import Foundation
import XCTest
@testable import PatchkiteCore

/// Expected values come from sdks/test-fixtures (computed by @patchkite/shared).
final class PatchkiteCoreTests: XCTestCase {
  static let fixturesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../test/fixtures")
    .standardizedFileURL
  lazy var fixtures: [String: Any] = {
    let data = try! Data(contentsOf: Self.fixturesDir.appendingPathComponent("fixtures.json"))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  }()
  func s(_ key: String) -> String { fixtures[key] as! String }

  var tmp: URL!
  let fm = FileManager.default

  override func setUpWithError() throws {
    tmp = fm.temporaryDirectory.appendingPathComponent("patchkite-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: tmp)
  }

  private func write(_ files: [String: String], into dir: URL) throws {
    for (path, content) in files {
      let url = dir.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
  }

  private func packageDir(withIgnored: Bool = false) throws -> URL {
    let dir = tmp.appendingPathComponent("pkg")
    try write(fixtures["files"] as! [String: String], into: dir)
    if withIgnored { try write(fixtures["ignoredFiles"] as! [String: String], into: dir) }
    return dir
  }

  private func zip(_ name: String) -> URL { Self.fixturesDir.appendingPathComponent("zips/\(name)") }

  func testPackageHashMatchesServer() throws {
    XCTAssertEqual(try PatchkiteCore.computePackageHash(packageDir()), s("packageHash"))
  }

  func testPackageHashIgnoresJunkAndSignature() throws {
    let dir = try packageDir(withIgnored: true)
    try Data(s("validJwt").utf8).write(to: dir.appendingPathComponent(".patchkiterelease"))
    XCTAssertEqual(try PatchkiteCore.computePackageHash(dir), s("packageHash"))
  }

  func testVerifiesValidSignature() throws {
    XCTAssertEqual(try PatchkiteCore.verifySignature(s("validJwt"), publicKeyPEM: s("publicKeyPem")), s("packageHash"))
  }

  func testAcceptsPemWithLiteralNewlines() throws {
    let oneLine = s("publicKeyPem").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\\n")
    XCTAssertEqual(try PatchkiteCore.verifySignature(s("validJwt"), publicKeyPEM: oneLine), s("packageHash"))
  }

  func testRejectsSignatureFromOtherKey() {
    XCTAssertThrowsError(try PatchkiteCore.verifySignature(s("wrongKeyJwt"), publicKeyPEM: s("publicKeyPem")))
    XCTAssertThrowsError(try PatchkiteCore.verifySignature(s("validJwt"), publicKeyPEM: s("otherPublicKeyPem")))
  }

  func testRejectsAlgNone() {
    XCTAssertThrowsError(try PatchkiteCore.verifySignature(s("noneAlgJwt"), publicKeyPEM: s("publicKeyPem")))
  }

  func testExtractsAndHashesLikeServer() throws {
    let out = tmp.appendingPathComponent("out")
    try MiniZip.extract(zip("normal.zip"), to: out)
    XCTAssertEqual(try PatchkiteCore.computePackageHash(out), s("packageHash"))
  }

  func testBlocksZipSlip() {
    let out = tmp.appendingPathComponent("slip")
    XCTAssertThrowsError(try MiniZip.extract(zip("slip.zip"), to: out))
    XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent("evil.txt").path))
  }

  func testRejectsCorruptOffsetsWithoutCrashing() {
    XCTAssertThrowsError(try MiniZip.extract(zip("bad-offset.zip"), to: tmp.appendingPathComponent("bad")))
  }

  func testRejectsNonZip() {
    XCTAssertThrowsError(try MiniZip.extract(Self.fixturesDir.appendingPathComponent("fixtures.json"), to: tmp.appendingPathComponent("x")))
  }

  func testPrunesUnverifiedFilesButKeepsRootSignature() throws {
    let dir = try packageDir(withIgnored: true)
    try Data("root".utf8).write(to: dir.appendingPathComponent(".patchkiterelease"))
    try Data("nested".utf8).write(to: dir.appendingPathComponent("nested/.patchkiterelease"))
    try PatchkiteCore.pruneUnverified(dir)
    for gone in ["__MACOSX", ".DS_Store", "assets/.DS_Store", "nested/.patchkiterelease"] {
      XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(gone).path), gone)
    }
    XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".patchkiterelease").path))
    XCTAssertEqual(try PatchkiteCore.computePackageHash(dir), s("packageHash"))
  }

  func testAppliesBsdiffPatchLikeServer() throws {
    let dir = Self.fixturesDir.appendingPathComponent("bsdiff")
    let out = tmp.appendingPathComponent("new.bin")
    try PatchkiteCore.bspatch(old: dir.appendingPathComponent("old.bin"), patch: dir.appendingPathComponent("patch.bin"), out: out)
    XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: dir.appendingPathComponent("new.bin")))
  }

  func testRejectsCorruptBsdiffPatch() throws {
    let dir = Self.fixturesDir.appendingPathComponent("bsdiff")
    let truncated = tmp.appendingPathComponent("bad.patch")
    try Data(contentsOf: dir.appendingPathComponent("patch.bin")).prefix(40).write(to: truncated)
    XCTAssertThrowsError(try PatchkiteCore.bspatch(old: dir.appendingPathComponent("old.bin"), patch: truncated, out: tmp.appendingPathComponent("x")))
    let notPatch = tmp.appendingPathComponent("np.patch")
    try Data("not a patch".utf8).write(to: notPatch)
    XCTAssertThrowsError(try PatchkiteCore.bspatch(old: dir.appendingPathComponent("old.bin"), patch: notPatch, out: tmp.appendingPathComponent("y")))
  }
}
