// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NativeSwitch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NativeSwitch", targets: ["NativeSwitch"])],
    targets: [
        .target(name: "SwitchCore"),
        .executableTarget(name: "NativeSwitch", dependencies: ["SwitchCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["SwitchCore"], path: "Tests/SwitchCoreTests")
    ]
)
