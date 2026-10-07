import Compression
import CryptoKit
import Foundation
import Security

/// Public entry point.
///
/// ```swift
/// import PatchkiteReactNative
///
/// override func bundleURL() -> URL? {
/// #if DEBUG
///   RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
/// #else
///   Patchkite.bundleURL()
/// #endif
/// }
/// ```
@objc(Patchkite)
public final class Patchkite: NSObject {
  /// URL of the latest update bundle, or the `main.jsbundle` shipped in the binary.
  @objc public static func bundleURL() -> URL? {
    bundleURL(forResource: "main", withExtension: "jsbundle")
  }

  @objc public static func bundleURL(forResource resource: String, withExtension ext: String) -> URL? {
    let core = PatchkiteCore.shared
    core.bundleFileName = "\(resource).\(ext)"
    if let path = core.resolveBundlePath() {
      PatchkiteLog("Running update: \(path)")
      return URL(fileURLWithPath: path)
    }
    PatchkiteLog("Running the bundle shipped in the binary.")
    return Bundle.main.url(forResource: resource, withExtension: ext)
  }

  /// Override the deployment key / server URL programmatically.
  @objc public static func configure(deploymentKey: String?, serverURL: String?) {
    if let deploymentKey { PatchkiteCore.shared.deploymentKeyOverride = deploymentKey }
    if let serverURL { PatchkiteCore.shared.serverURLOverride = serverURL }
  }
}

func PatchkiteLog(_ message: String) {
  NSLog("[Patchkite] %@", message)
}

private struct PatchkiteError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Update state is stored in `Application Support/Patchkite` (same layout as Android).
@objc(PatchkiteCore)
public final class PatchkiteCore: NSObject {
  @objc public static let shared = PatchkiteCore()

  static let signatureFile = ".patchkiterelease"
  static let diffManifestFile = "patchkite-diff.json"
  private static let ignored: Set<String> = [".DS_Store", "__MACOSX", signatureFile]

  var bundleFileName = "main.jsbundle"
  var deploymentKeyOverride: String?
  var serverURLOverride: String?

  private let lock = NSRecursiveLock()
  private let fm = FileManager.default
  private let root: URL
  private var status: [String: Any]
  private(set) var runningHash: String?
  private var firstRunHash: String?

  private override init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    root = support.appendingPathComponent("Patchkite", isDirectory: true)
    status = [:]
    super.init()
    status = loadStatus()
  }

  // MARK: configuration

  private func info(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  var appVersion: String { info("CFBundleShortVersionString") ?? "1.0.0" }

  private var binaryId: String {
    let build = info("CFBundleVersion") ?? ""
    let bundleDate = Bundle.main.url(forResource: "main", withExtension: "jsbundle")
      .flatMap { try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
      .map { String(Int($0.timeIntervalSince1970)) } ?? ""
    return "\(appVersion)-\(build)-\(bundleDate)"
  }

  var deploymentKey: String? { deploymentKeyOverride ?? info("PatchkiteDeploymentKey") }
  var serverURL: String? { serverURLOverride ?? info("PatchkiteServerURL") ?? info("PatchkiteServerUrl") }
  var publicKey: String? { info("PatchkitePublicKey") }

  var clientUniqueId: String {
    lock.lock(); defer { lock.unlock() }
    if let id = status["clientId"] as? String { return id }
    let id = UUID().uuidString
    status["clientId"] = id
    saveStatus()
    return id
  }

  @objc public func configuration() -> [String: Any] {
    var cfg: [String: Any] = ["appVersion": appVersion, "clientUniqueId": clientUniqueId]
    cfg["deploymentKey"] = deploymentKey
    cfg["serverUrl"] = serverURL
    cfg["publicKey"] = publicKey
    cfg["binaryHash"] = binaryBundleHash
    return cfg
  }

  /// URL of the JS bundle shipped with the app (inside the .app).
  private var binaryBundleURL: URL? {
    let name = bundleFileName as NSString
    return Bundle.main.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension)
  }

  /// SHA-256 of the bundle shipped in the binary, the base for binary patches on the first update. Cached in status per binary.
  var binaryBundleHash: String? {
    lock.lock()
    defer { lock.unlock() }
    if let cached = status["binaryHash"] as? String { return cached }
    guard let url = binaryBundleURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    let hash = SHA256.hash(data: data).hex
    status["binaryHash"] = hash
    saveStatus()
    return hash
  }

  // MARK: status

  private var statusURL: URL { root.appendingPathComponent("status.json") }
  private func packageDir(_ hash: String) -> URL { root.appendingPathComponent(hash, isDirectory: true) }
  private func contentDir(_ hash: String) -> URL { packageDir(hash).appendingPathComponent("content", isDirectory: true) }

  private func loadStatus() -> [String: Any] {
    guard let data = try? Data(contentsOf: statusURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
  }

  private func saveStatus() {
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: status) {
      try? data.write(to: statusURL, options: .atomic)
    }
  }

  private func meta(_ hash: String?) -> [String: Any]? {
    guard let hash,
          let data = try? Data(contentsOf: packageDir(hash).appendingPathComponent("meta.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
  }

  private var currentHash: String? { status["current"] as? String }
  private var previousHash: String? { status["previous"] as? String }
  private var pending: [String: Any]? { status["pending"] as? [String: Any] }

  /// Called on start / reload. Handles auto-rollback if an update crashes before notifyAppReady.
  func resolveBundlePath() -> String? {
    lock.lock(); defer { lock.unlock() }
    let id = binaryId
    if status["binaryId"] as? String != id {
      if status["binaryId"] != nil { PatchkiteLog("New binary detected, removing old updates.") }
      let clientId = status["clientId"]
      try? fm.removeItem(at: root)
      status = ["binaryId": id]
      if let clientId { status["clientId"] = clientId }
      saveStatus()
    }

    if var p = pending, let hash = p["hash"] as? String {
      if p["isLoading"] as? Bool == true {
        PatchkiteLog("Update \(hash) failed to start (notifyAppReady was not called). Rolling back.")
        rollback(hash)
      } else {
        p["isLoading"] = true
        status["pending"] = p
        firstRunHash = hash
        saveStatus()
      }
    }

    if let current = currentHash {
      if let rel = meta(current)?["bundlePath"] as? String {
        let bundle = contentDir(current).appendingPathComponent(rel)
        if fm.fileExists(atPath: bundle.path) {
          runningHash = current
          cleanup()
          return bundle.path
        }
      }
      PatchkiteLog("Update bundle \(current) not found, falling back to the binary.")
      status["current"] = nil
      saveStatus()
    }
    runningHash = nil
    cleanup()
    return nil
  }

  private func rollback(_ failedHash: String) {
    var failed = status["failed"] as? [String] ?? []
    failed.append(failedHash)
    status["failed"] = Array(failed.suffix(20))
    if let m = meta(failedHash) { status["rollbackReport"] = m }
    if let previous = previousHash, previous != failedHash { status["current"] = previous } else { status["current"] = nil }
    status["previous"] = nil
    status["pending"] = nil
    saveStatus()
  }

  private func cleanup() {
    let keep = Set([currentHash, previousHash, runningHash, pending?["hash"] as? String].compactMap { $0 })
    let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      let name = item.lastPathComponent
      if !keep.contains(name) && !name.hasPrefix("download") { try? fm.removeItem(at: item) }
    }
  }

  @objc public func notifyApplicationReady() {
    lock.lock(); defer { lock.unlock() }
    if pending?["isLoading"] as? Bool == true {
      status["pending"] = nil
      saveStatus()
    }
  }

  @objc public func isFailedUpdate(_ hash: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return (status["failed"] as? [String] ?? []).contains(hash)
  }

  @objc public func isFirstRun(_ hash: String) -> Bool {
    firstRunHash == hash && runningHash == hash
  }

  @objc public func popRollbackReport() -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    guard let report = status["rollbackReport"] as? [String: Any] else { return nil }
    status["rollbackReport"] = nil
    saveStatus()
    return report
  }

  @objc(patchkiteValueForKey:) public func patchkiteValue(forKey key: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    return (status["kv"] as? [String: String])?[key]
  }

  @objc(setPatchkiteValue:forKey:) public func setPatchkiteValue(_ value: String, forKey key: String) {
    lock.lock(); defer { lock.unlock() }
    var kv = status["kv"] as? [String: String] ?? [:]
    kv[key] = value
    status["kv"] = kv
    saveStatus()
  }

  /// 0 = RUNNING, 1 = PENDING, 2 = LATEST
  @objc(updateMetadataWithState:) public func updateMetadata(state: Int) -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    var pendingHash: String?
    if let p = pending, p["isLoading"] as? Bool != true { pendingHash = p["hash"] as? String }
    let hash: String?
    switch state {
    case 0: hash = runningHash
    case 1: hash = pendingHash
    default: hash = pendingHash ?? runningHash
    }
    guard var m = meta(hash) else { return nil }
    m["isPending"] = hash == pendingHash
    return m
  }

  @objc(installUpdate:error:) public func installUpdate(_ hash: String) throws {
    lock.lock(); defer { lock.unlock() }
    guard meta(hash) != nil else { throw PatchkiteError("Package \(hash) has not been downloaded") }
    if currentHash != hash {
      status["previous"] = runningHash ?? currentHash
      status["current"] = hash
    }
    status["pending"] = ["hash": hash, "isLoading": false]
    saveStatus()
  }

  @objc public func clearUpdates() {
    lock.lock(); defer { lock.unlock() }
    status["current"] = nil
    status["previous"] = nil
    status["pending"] = nil
    saveStatus()
  }

  // MARK: download

  @objc(downloadUpdate:progress:error:)
  public func downloadUpdate(_ pkg: [String: Any], progress: @escaping (Double, Double) -> Void) throws -> [String: Any] {
    guard let hash = pkg["packageHash"] as? String, let urlString = pkg["downloadUrl"] as? String, let url = URL(string: urlString) else {
      throw PatchkiteError("Invalid package")
    }
    let downloadDir = root.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: downloadDir) }

    let zipURL = downloadDir.appendingPathComponent("package.zip")
    try Downloader(progress: progress).download(url, to: zipURL)

    let unzipped = downloadDir.appendingPathComponent("unzipped", isDirectory: true)
    try MiniZip.extract(zipURL, to: unzipped)

    let target = contentDir(hash)
    try? fm.removeItem(at: packageDir(hash))
    try fm.createDirectory(at: packageDir(hash), withIntermediateDirectories: true)

    do {
      let diffManifest = unzipped.appendingPathComponent(Self.diffManifestFile)
      if fm.fileExists(atPath: diffManifest.path) {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: diffManifest)) as? [String: Any]
        let targetPath = target.standardizedFileURL.path + "/"
        if let binaryBase = json?["binaryBase"] as? String, !binaryBase.isEmpty {
          // Diff against the store binary: the base is only the app's built-in bundle; other files are in the diff.
          let dest = target.appendingPathComponent(binaryBase).standardizedFileURL
          guard dest.path.hasPrefix(targetPath), let source = binaryBundleURL else {
            throw PatchkiteError("Invalid binaryBase: \(binaryBase)")
          }
          try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fm.copyItem(at: source, to: dest)
        } else {
          guard let base = runningHash ?? currentHash else { throw PatchkiteError("Diff update without a base package") }
          try fm.copyItem(at: contentDir(base), to: target)
        }
        for file in json?["deletedFiles"] as? [String] ?? [] {
          // Ignore paths that escape the package folder (e.g. "../x" from a malicious diff).
          let url = target.appendingPathComponent(file).standardizedFileURL
          if url.path.hasPrefix(targetPath) { try? fm.removeItem(at: url) }
        }
        try? fm.removeItem(at: target.appendingPathComponent(Self.signatureFile))
        try fm.removeItem(at: diffManifest)
        // Binary patch: new file = bspatch(same file in the base package, patch from the server).
        let patchDir = unzipped.appendingPathComponent(Self.patchDir)
        for file in json?["patchedFiles"] as? [String] ?? [] {
          let old = target.appendingPathComponent(file).standardizedFileURL
          let patch = patchDir.appendingPathComponent(file).standardizedFileURL
          let out = unzipped.appendingPathComponent(file).standardizedFileURL
          guard old.path.hasPrefix(targetPath), patch.path.hasPrefix(patchDir.standardizedFileURL.path + "/"),
                out.path.hasPrefix(unzipped.standardizedFileURL.path + "/")
          else { throw PatchkiteError("Invalid patch path: \(file)") }
          try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
          try Self.bspatch(old: old, patch: patch, out: out)
        }
        try? fm.removeItem(at: patchDir)
        try Self.merge(from: unzipped, into: target)
      } else {
        try fm.moveItem(at: unzipped, to: target)
      }

      try Self.pruneUnverified(target)
      let computed = try Self.computePackageHash(target)
      guard computed == hash else { throw PatchkiteError("Package hash mismatch (expected \(hash), got \(computed))") }

      let signature = target.appendingPathComponent(Self.signatureFile)
      if let key = publicKey {
        guard let jwt = try? String(contentsOf: signature, encoding: .utf8) else {
          throw PatchkiteError("Code signing is enabled but the package is not signed")
        }
        let claimed = try Self.verifySignature(jwt, publicKeyPEM: key)
        guard claimed == computed else { throw PatchkiteError("Signature contentHash does not match") }
        PatchkiteLog("Package signature is valid.")
      } else if fm.fileExists(atPath: signature.path) {
        PatchkiteLog("Package is signed but PatchkitePublicKey is not set; skipping verification.")
      }

      guard let bundle = findFile(named: bundleFileName, in: target) else {
        throw PatchkiteError("Bundle \(bundleFileName) not found in package")
      }
      let meta: [String: Any] = [
        "label": pkg["label"] as? String ?? "",
        "appVersion": pkg["appVersion"] as? String ?? appVersion,
        "description": pkg["description"] as? String ?? "",
        "isMandatory": pkg["isMandatory"] as? Bool ?? false,
        "packageHash": hash,
        "packageSize": pkg["packageSize"] as? Double ?? 0,
        "deploymentKey": pkg["deploymentKey"] as? String ?? "",
        "bundlePath": String(bundle.path.dropFirst(target.path.count + 1)),
        "downloadTime": Date().timeIntervalSince1970 * 1000,
      ]
      try JSONSerialization.data(withJSONObject: meta).write(to: packageDir(hash).appendingPathComponent("meta.json"))
      return meta
    } catch {
      try? fm.removeItem(at: packageDir(hash))
      throw error
    }
  }

  private func findFile(named name: String, in dir: URL) -> URL? {
    let direct = dir.appendingPathComponent(name)
    if fm.fileExists(atPath: direct.path) { return direct }
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
      if url.lastPathComponent == name { return url }
    }
    return nil
  }

  private static func merge(from src: URL, into dest: URL) throws {
    let fm = FileManager.default
    let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = e?.nextObject() as? URL {
      guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
      let rel = String(url.standardizedFileURL.path.dropFirst(src.standardizedFileURL.path.count + 1))
      let out = dest.appendingPathComponent(rel)
      try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: out)
      try fm.copyItem(at: url, to: out)
    }
  }

  // MARK: binary patch

  static let patchDir = ".patchkite-patches"

  /// Applies a Patchkite-format bsdiff patch (see packages/shared/src/bsdiff.ts).
  static func bspatch(old: URL, patch: URL, out: URL) throws {
    let oldData = try Data(contentsOf: old, options: .mappedIfSafe)
    let patchData = try Data(contentsOf: patch, options: .mappedIfSafe)
    guard patchData.count >= 16, String(decoding: patchData.prefix(8), as: UTF8.self) == "PATCHK01" else {
      throw PatchkiteError("Invalid bsdiff patch")
    }
    let newSize = patchData.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int64.self)) }
    guard newSize >= 0, newSize <= Int64(Int32.max) else { throw PatchkiteError("Corrupt bsdiff patch") }
    var output = Data(count: Int(newSize))
    try patchData.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      try oldData.withUnsafeBytes { (o: UnsafeRawBufferPointer) in
        try output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
          let n = Int(newSize)
          var off = 16, newPos = 0, oldPos = 0
          func i64(_ at: Int) -> Int64 { Int64(littleEndian: p.loadUnaligned(fromByteOffset: at, as: Int64.self)) }
          while newPos < n {
            guard off + 24 <= p.count else { throw PatchkiteError("Truncated bsdiff patch") }
            let x = i64(off), y = i64(off + 8), z = i64(off + 16)
            off += 24
            guard x >= 0, y >= 0, x <= Int64(n - newPos), y <= Int64(n - newPos) - x,
                  x + y <= Int64(p.count - off), abs(z) <= Int64(Int32.max)
            else { throw PatchkiteError("Corrupt bsdiff patch") }
            let xi = Int(x), yi = Int(y)
            for i in 0..<xi {
              let src = oldPos &+ i
              // Old bytes outside the file are treated as 0, same as the original bspatch.
              dst[newPos + i] = p[off + i] &+ (src >= 0 && src < o.count ? o[src] : 0)
            }
            off += xi
            newPos += xi
            oldPos &+= xi
            if yi > 0 { (dst.baseAddress! + newPos).copyMemory(from: p.baseAddress! + off, byteCount: yi) }
            off += yi
            newPos += yi
            oldPos &+= Int(z)
          }
        }
      }
    }
    try output.write(to: out)
  }

  // MARK: hash & signature

  /// Removes files excluded from the package hash (except the root signature),
  /// so unverified files can't be loaded as part of the bundle.
  static func pruneUnverified(_ dir: URL) throws {
    let fm = FileManager.default
    let base = dir.standardizedFileURL.path
    var doomed: [URL] = []
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
      let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
      guard rel != signatureFile, ignored.contains(url.lastPathComponent) else { continue }
      doomed.append(url)
      e?.skipDescendants()
    }
    for url in doomed { try fm.removeItem(at: url) }
  }

  /// Same algorithm as `packageHashFromManifest` in @patchkite/shared.
  static func computePackageHash(_ dir: URL) throws -> String {
    let fm = FileManager.default
    let base = dir.standardizedFileURL.path
    var files: [(rel: String, url: URL)] = []
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = e?.nextObject() as? URL {
      guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
      let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
      if rel.split(separator: "/").contains(where: { ignored.contains(String($0)) }) { continue }
      // Foundation stores file names as NFD; the hash uses NFC like @patchkite/shared.
      files.append((rel.precomposedStringWithCanonicalMapping, url))
    }
    // UTF-16 ordering, like Array.prototype.sort in JS.
    files.sort { $0.rel.utf16.lexicographicallyPrecedes($1.rel.utf16) }
    let entries = try files.map { file -> String in
      let digest = SHA256.hash(data: try Data(contentsOf: file.url, options: .mappedIfSafe))
      return "\"\(file.rel):\(digest.hex)\""
    }
    let json = "[" + entries.joined(separator: ",") + "]"
    return SHA256.hash(data: Data(json.utf8)).hex
  }

  static func verifySignature(_ jwt: String, publicKeyPEM: String) throws -> String {
    let parts = jwt.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map(String.init)
    guard parts.count == 3,
          let headerData = Data(base64URL: parts[0]),
          let payloadData = Data(base64URL: parts[1]),
          let signature = Data(base64URL: parts[2]),
          let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          header["alg"] as? String == "RS256"
    else { throw PatchkiteError("Invalid signature JWT") }

    let body = publicKeyPEM
      .replacingOccurrences(of: "\\n", with: "\n")  // single-line PEM with literal "\n"
      .replacingOccurrences(of: "-----[A-Z ]+-----", with: "", options: .regularExpression)
      .components(separatedBy: .whitespacesAndNewlines).joined()
    guard let der = Data(base64Encoded: body) else { throw PatchkiteError("Invalid PatchkitePublicKey") }
    let pkcs1 = DER.stripSubjectPublicKeyInfo(der) ?? der
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    var cfError: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &cfError) else {
      throw PatchkiteError("Failed to read public key")
    }
    let signed = Data("\(parts[0]).\(parts[1])".utf8)
    guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, &cfError) else {
      throw PatchkiteError("Invalid package signature")
    }
    guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let contentHash = payload["contentHash"] as? String
    else { throw PatchkiteError("Signature does not contain contentHash") }
    return contentHash
  }
}

// MARK: - Helpers

private extension Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
  init?(base64URL: String) {
    var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    self.init(base64Encoded: s)
  }
}

/// Minimal DER parser to extract the RSAPublicKey (PKCS#1) from a SubjectPublicKeyInfo.
private enum DER {
  static func stripSubjectPublicKeyInfo(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    var i = 0
    func readLength() -> Int? {
      guard i < bytes.count else { return nil }
      let first = Int(bytes[i]); i += 1
      if first < 0x80 { return first }
      let n = first & 0x7f
      var len = 0
      for _ in 0..<n { guard i < bytes.count else { return nil }; len = (len << 8) | Int(bytes[i]); i += 1 }
      return len
    }
    guard bytes.first == 0x30 else { return nil }
    i = 1
    guard readLength() != nil, i < bytes.count, bytes[i] == 0x30 else { return nil }
    i += 1
    guard let algLen = readLength() else { return nil }
    i += algLen
    guard i < bytes.count, bytes[i] == 0x03 else { return nil }
    i += 1
    guard let bitLen = readLength(), i < bytes.count else { return nil }
    i += 1 // unused bits byte
    return Data(bytes[i..<min(bytes.count, i + bitLen - 1)])
  }
}

/// Synchronous download with progress (called from a background queue).
private final class Downloader: NSObject, URLSessionDataDelegate {
  private let progress: (Double, Double) -> Void
  private var handle: FileHandle?
  private var received: Double = 0
  private var total: Double = 0
  private var lastEmit = Date.distantPast
  private var error: Error?
  private var statusCode = 0
  private let done = DispatchSemaphore(value: 0)

  init(progress: @escaping (Double, Double) -> Void) { self.progress = progress }

  func download(_ url: URL, to dest: URL) throws {
    FileManager.default.createFile(atPath: dest.path, contents: nil)
    handle = try FileHandle(forWritingTo: dest)
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    session.dataTask(with: url).resume()
    done.wait()
    session.finishTasksAndInvalidate()
    try handle?.close()
    if let error { throw error }
    guard (200..<300).contains(statusCode) else { throw PatchkiteError("Download failed: HTTP \(statusCode)") }
    progress(received, total > 0 ? total : received)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    total = Double(response.expectedContentLength)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    handle?.write(data)
    received += Double(data.count)
    if Date().timeIntervalSince(lastEmit) > 0.1 {
      lastEmit = Date()
      progress(received, total)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    self.error = error
    done.signal()
  }
}

/// Minimal zip reader (store + deflate) so the SDK needs no third-party dependency.
enum MiniZip {
  /// Limit on total extracted zip contents (zip bomb protection).
  static let maxExtractedBytes = 1 << 30

  static func extract(_ zip: URL, to dest: URL) throws {
    let data = try Data(contentsOf: zip, options: .mappedIfSafe)
    let bytes = [UInt8](data)
    let n = bytes.count
    // All offsets come from the zip contents, so they must be checked so a corrupt zip can't crash the app.
    func need(_ o: Int, _ len: Int) throws {
      guard o >= 0, len >= 0, o <= n - len else { throw PatchkiteError("Invalid zip (offset out of bounds)") }
    }
    func u16(_ o: Int) throws -> Int {
      try need(o, 2)
      return Int(bytes[o]) | Int(bytes[o + 1]) << 8
    }
    func u32(_ o: Int) throws -> Int { try u16(o) | (try u16(o + 2)) << 16 }

    guard n >= 22 else { throw PatchkiteError("Invalid zip") }
    var eocd = n - 22
    while eocd >= 0, try u32(eocd) != 0x06054b50 { eocd -= 1 }
    guard eocd >= 0 else { throw PatchkiteError("Invalid zip (EOCD)") }
    let count = try u16(eocd + 10)
    var p = try u32(eocd + 16)
    let fm = FileManager.default
    let destPath = dest.standardizedFileURL.path
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)

    var extracted = 0
    for _ in 0..<count {
      guard try u32(p) == 0x02014b50 else { throw PatchkiteError("Invalid zip (central directory)") }
      let method = try u16(p + 10)
      let compSize = try u32(p + 20)
      let size = try u32(p + 24)
      let nameLen = try u16(p + 28), extraLen = try u16(p + 30), commentLen = try u16(p + 32)
      let localOffset = try u32(p + 42)
      try need(p + 46, nameLen)
      let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
      p += 46 + nameLen + extraLen + commentLen

      let out = dest.appendingPathComponent(name).standardizedFileURL
      guard out.path.hasPrefix(destPath + "/") else { throw PatchkiteError("Zip entry outside the target directory: \(name)") }
      if name.hasSuffix("/") {
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        continue
      }
      extracted += size
      guard extracted <= maxExtractedBytes else { throw PatchkiteError("Package contents exceed the size limit") }
      let dataStart = localOffset + 30 + (try u16(localOffset + 26)) + (try u16(localOffset + 28))
      try need(dataStart, compSize)
      let compressed = data.subdata(in: dataStart..<(dataStart + compSize))
      let content: Data
      switch method {
      case 0: content = compressed
      case 8: content = try inflate(compressed, size: size)
      default: throw PatchkiteError("Unsupported zip compression method \(method)")
      }
      try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try content.write(to: out)
    }
  }

  private static func inflate(_ data: Data, size: Int) throws -> Data {
    if size == 0 { return Data() }
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { dst in
      data.withUnsafeBytes { src in
        compression_decode_buffer(
          dst.bindMemory(to: UInt8.self).baseAddress!, size,
          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw PatchkiteError("Failed to decompress zip") }
    return output
  }
}
