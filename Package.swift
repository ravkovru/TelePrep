// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KZTelegramAPIUtility",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "KZTelegramAPIUtility", targets: ["KZTelegramAPIUtility"])],
    targets: [.executableTarget(name: "KZTelegramAPIUtility")]
)

