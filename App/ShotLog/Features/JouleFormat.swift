import Foundation

/// ジュール表示の整形。
///
/// 固定 2 桁 (`%.2f`) にしていたが、実キャプチャのように弾速が数 m/s しか出ていない
/// 場面では **全ての行が `0.00 J` になって情報が消える**（0.25 g・3.0 m/s = 0.0011 J）。
/// 一方でエアソフトの実用域（0.5〜3 J）では 2 桁がちょうどよい。
/// そこで桁数だけを値の大きさで切り替え、どの領域でも有効数字が 2 桁以上残るようにする。
enum JouleFormat {
    /// 単位記号なしの数値部分。
    static func value(_ joules: Double) -> String {
        String(format: "%.\(fractionDigits(for: joules))f", joules)
    }

    /// `1.03 J` のように単位付きで返す。
    static func labeled(_ joules: Double) -> String {
        value(joules) + " J"
    }

    /// 有効数字が 2 桁以上残る小数桁数。実用域（0.1〜10 J）は従来どおり 2 桁のまま。
    static func fractionDigits(for joules: Double) -> Int {
        let magnitude = abs(joules)
        if magnitude == 0 { return 2 }
        if magnitude >= 100 { return 0 }
        if magnitude >= 10 { return 1 }
        if magnitude >= 0.1 { return 2 }
        if magnitude >= 0.01 { return 3 }
        return 4
    }
}
