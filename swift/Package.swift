// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProcessX",
    // macOS 26: Liquid Glass (.glassEffect / GlassEffectContainer / .buttonStyle(.glass))
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ProcessX",
            path: "Sources/ProcessX",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
