// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ClaudeMultipass",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
  ],
  targets: [
    .target(name: "MultipassCore"),
    .executableTarget(
      name: "ClaudeMultipass",
      dependencies: ["MultipassCore", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "MultipassCoreTests", dependencies: ["MultipassCore"]),
    .testTarget(name: "ClaudeMultipassTests", dependencies: ["ClaudeMultipass", "MultipassCore"]),
  ],
  swiftLanguageVersions: [.v5]
)
