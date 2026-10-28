// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ClaudeMultipass",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "MultipassCore"),
    .executableTarget(name: "ClaudeMultipass", dependencies: ["MultipassCore"]),
    .testTarget(name: "MultipassCoreTests", dependencies: ["MultipassCore"]),
    .testTarget(name: "ClaudeMultipassTests", dependencies: ["ClaudeMultipass", "MultipassCore"]),
  ],
  swiftLanguageVersions: [.v5]
)
