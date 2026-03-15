// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "video",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "ThermoKit", targets: ["ThermoKit"]),
    .executable(name: "ThermalHeatmap", targets: ["ThermalHeatmapMain"]),
    .executable(name: "ThermalVideo", targets: ["ThermalVideoMain"])
  ],
  targets: [
    .target(
      name: "ThermoKit",
      path: "src/ThermoKit",
      swiftSettings: [.unsafeFlags(["-O"])],
      linkerSettings: [
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
        .linkedFramework("UniformTypeIdentifiers"),
        .linkedFramework("AppKit")
      ]
    ),
    .executableTarget(
      name: "ThermalHeatmapMain",
      dependencies: ["ThermoKit"],
      path: "src/ThermalHeatmapMain"
    ),
    .executableTarget(
      name: "ThermalVideoMain",
      dependencies: ["ThermoKit"],
      path: "src/ThermalVideoMain"
    )
  ]
)
