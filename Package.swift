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
        // アプリの SwiftData モデルと、その上で動く小さなサービスだけを取り出した
        // ターゲット。**製品としてはビルドしない**（`products` に出さない）。
        //
        // なぜ要るか: 「デモのセッションに印が付くか」「デモデータの削除で実データが
        // 残るか」「デモを切ったら開いているセッションが締まるか」は保存層の話で、
        // 画面もハードウェアも要らない。だが `Session` は Xcode のアプリターゲット側に
        // あり、`swift test` からは見えなかった。ここで**同じソースファイルを**
        // パッケージ側のモジュールとしてももう一度コンパイルすることで、
        // インメモリの `ModelContainer` に対して `swift test` から直接検証できる。
        // アプリターゲットはこのライブラリをリンクしない（自分で同じファイルを
        // コンパイルする）ので、型が二重に定義されることはない。
        .target(
            name: "MuzzlemeterAppModels",
            dependencies: ["MuzzlemeterKit"],
            path: "App/Muzzlemeter/Models",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "MuzzlemeterAppModelsTests",
            dependencies: ["MuzzlemeterAppModels", "MuzzlemeterKit"],
            path: "Tests/MuzzlemeterAppModelsTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
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
