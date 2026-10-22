// swift-tools-version: 6.2
import PackageDescription
import Foundation

let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/niho-mic/Info.plist").path

let package = Package(
    name: "niho-mic",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "niho-mic", targets: ["niho-mic"])],
    targets: [
        .target(name: "NihoMicCore"),
        .executableTarget(name: "niho-mic", dependencies: ["NihoMicCore"], exclude: ["Info.plist"], linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .testTarget(name: "NihoMicCoreTests", dependencies: ["NihoMicCore"])
    ],
    swiftLanguageModes: [.v5]
)
