// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Computah",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Computah", targets: ["Computah"])],
    targets: [
        .target(name: "ComputahCore", resources: [.process("Prompts")]),
        .executableTarget(name: "Computah", dependencies: ["ComputahCore"],
                          resources: [.copy("Resources/Sounds")]),
    ],
    swiftLanguageModes: [.v5]
)
