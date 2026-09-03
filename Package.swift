// swift-tools-version: 6.0
import Foundation
import PackageDescription

// macOS の CLI から CoreBluetooth を使うには、実行ファイルの __TEXT,__info_plist セクションに
// NSBluetoothAlwaysUsageDescription を含む Info.plist が埋め込まれている必要がある。
// 無いと CBCentralManager 生成時に TCC が SIGABRT でプロセスを落とす。
let sniffInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/MuzzlemeterSniff/Info.plist")
    .path

let package = Package(
    name: "Muzzlemeter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        // Round E: MuzzlemeterWatch（watchOS companion）が MuzzlemeterKit を直接使う
        // （弾速計算・ジュール整形・Watch 側の状態組み立てを共有するため）。
        // `muzzlemeter-sniff` は macOS 専用のままで、watchOS ではビルドしない。
        .watchOS(.v10),
    ],
    products: [
        .library(name: "MuzzlemeterKit", targets: ["MuzzlemeterKit"]),
        .executable(name: "muzzlemeter-sniff", targets: ["MuzzlemeterSniff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MuzzlemeterKit",
            path: "Sources/MuzzlemeterKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "MuzzlemeterSniff",
            dependencies: [
                "MuzzlemeterKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MuzzlemeterSniff",
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
            name: "MuzzlemeterKitTests",
            dependencies: ["MuzzlemeterKit"],
            path: "Tests/MuzzlemeterKitTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
