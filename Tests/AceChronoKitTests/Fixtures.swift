import Foundation
import Testing
@testable import AceChronoKit

/// 実機キャプチャのフィクスチャ読み込み。
///
/// `Tests/AceChronoKitTests/Fixtures/` は `Package.swift` で `.copy` されているので
/// `Bundle.module` からディレクトリごと参照できる。
enum Fixtures {
    /// キャプチャ相手（`AC6000BT-009809`）の鍵。広告 `00 05 08 c4 94 52 04` 由来。
    static let keys = DeviceKeys(key1: 0xC4, key2: 0x94)
    static let manufacturerData = Data([0x00, 0x05, 0x08, 0xC4, 0x94, 0x52, 0x04])

    static func url(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
            "フィクスチャが見つかりません: \(name).txt"
        )
    }

    static func script(_ name: String) throws -> ReplayScript {
        try ReplayScript.load(contentsOf: try url(name))
    }

    /// 本体が送ってきた全通知（16 本。末尾は 1 バイトの電源 OFF 通知）。
    static func rx() throws -> [Data] {
        try script("acesoft-iphone-rx").entries.map(\.data)
    }

    /// AceSoft が書き込んだ全フレーム（8 本）。
    static func tx() throws -> [Data] {
        try script("acesoft-iphone-tx").entries.map(\.data)
    }
}
