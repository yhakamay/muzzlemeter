// swift-tools-version: 6.0
import Foundation
import PackageDescription

// macOS の CLI から CoreBluetooth を使うには、実行ファイルの __TEXT,__info_plist セクションに
// NSBluetoothAlwaysUsageDescription を含む Info.plist が埋め込まれている必要がある。
// 無いと CBCentralManager 生成時に TCC が SIGABRT でプロセスを落とす。
let sniffInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/AceChronoSniff/Info.plist")
    .path

let package = Package(
    name: "AceChrono",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AceChronoKit", targets: ["AceChronoKit"]),
        .executable(name: "acechrono-sniff", targets: ["AceChronoSniff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AceChronoKit",
            path: "Sources/AceChronoKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "AceChronoSniff",
            dependencies: [
                "AceChronoKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AceChronoSniff",
            exclude: ["Info.plist"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", sniffInfoPlist,
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        .testTarget(
            name: "AceChronoKitTests",
            dependencies: ["AceChronoKit"],
            path: "Tests/AceChronoKitTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
