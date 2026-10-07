// swift-tools-version:5.9
// Unit tests for the iOS SDK core logic (hash, signature, zip), run on macOS with `swift test`.
// Sources/PatchkiteCore/PatchkiteCore.swift is a symlink to ../ios/PatchkiteCore.swift.
import PackageDescription

let package = Package(
  name: "PatchkiteCoreTests",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "PatchkiteCore", linkerSettings: [.linkedLibrary("compression")]),
    .testTarget(name: "PatchkiteCoreTests", dependencies: ["PatchkiteCore"]),
  ]
)
