// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Filesnake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Filesnake", targets: ["Filesnake"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6"),
    ],
    targets: [
        .executableTarget(
            name: "Filesnake",
            dependencies: [
                "ZIPFoundation",
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "Sources/Filesnake",
            exclude: ["Resources/Info.plist", "Resources/Filesnake.icns"]
        )
    ]
)
