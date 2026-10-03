// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Headway",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "HeadwayCore", targets: ["HeadwayCore"]),
    .executable(name: "feedanalysis", targets: ["feedanalysis"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
  ],
  targets: [
    .target(
      name: "HeadwayCore",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "feedanalysis",
      dependencies: ["HeadwayCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "HeadwayCoreTests",
      dependencies: ["HeadwayCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
