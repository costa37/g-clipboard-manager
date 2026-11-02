// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GClip", platforms: [.macOS(.v13)], products: [.executable(name: "GClip", targets: ["GClip"])], targets: [.executableTarget(name: "GClip")])
