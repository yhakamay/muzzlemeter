// swift-tools-version: 6.0
import Foundation
import PackageDescription

// macOS の CLI から CoreBluetooth を使うには、実行ファイルの __TEXT,__info_plist セクションに
// NSBluetoothAlwaysUsageDescription を含む Info.plist が埋め込まれている必要がある。
// 無いと CBCentralManager 生成時に TCC が SIGABRT でプロセスを落とす。
let sniffInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/ShotLogSniff/Info.plist")
    .path

let package = Package(
    name: "ShotLog",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShotLogKit", targets: ["ShotLogKit"]),
        .executable(name: "shotlog-sniff", targets: ["ShotLogSniff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ShotLogKit",
            path: "Sources/ShotLogKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "ShotLogSniff",
            dependencies: [
                "ShotLogKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ShotLogSniff",
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
            name: "ShotLogKitTests",
            dependencies: ["ShotLogKit"],
            path: "Tests/ShotLogKitTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
