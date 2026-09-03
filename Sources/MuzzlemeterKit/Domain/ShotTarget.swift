import Foundation

/// 「N 発撃ったら締める」の N。
///
/// アプリ側の `Int?` をそのまま持ち回すと、`0` や負数（＝目標として意味を成さない値）が
/// 判定に紛れ込む。生成の時点で弾いて、**存在するなら必ず有効**にしておく。
///
/// 判定そのものは 1 行だが、キットに置いてテストで固定してある。「ちょうど N 発目で
/// 締まるか」「超えたときも締まるか」は取りこぼすと機能が丸ごと成立しない境界で、
/// UI 側のコードに埋めると確かめられない。
public struct ShotTarget: Sendable, Hashable, Codable {
    /// 目標発数。必ず 1 以上。
    public let count: Int

    /// 1 以上のときだけ目標として成立する。`nil` / 0 / 負数は「手動で締める」。
    public init?(_ count: Int?) {
        guard let count, count > 0 else { return nil }
        self.count = count
    }

    /// 締めるべきか。**ちょうどでも、超えていても締める。**
    ///
    /// 超えた場合も含めるのは、フルオートで 1 発ずつ止められないため。
    /// 10 発設定でトリガを引きっぱなしにすれば 12 発届くことがあり、
    /// 「ちょうど」だけを見ていると永遠に締まらない。
    public func isReached(shotCount: Int) -> Bool {
        shotCount >= count
    }

    /// あと何発か。届いていれば 0。
    public func remaining(shotCount: Int) -> Int {
        max(0, count - shotCount)
    }

    /// 進捗（0…1）。超過しても 1 で頭打ち。
    public func progress(shotCount: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(1.0, Double(max(0, shotCount)) / Double(count))
    }
}
