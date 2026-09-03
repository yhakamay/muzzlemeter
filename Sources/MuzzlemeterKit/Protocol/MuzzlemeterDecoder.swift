import Foundation

/// `FIRE_REPORT`（`0x52`）の中身。
///
/// ```
/// aa 0a 52 00 00 1a 01 00 00 79
///          ^^^^^ ^^^^^ ^^^^^
///          |     |     rawRev  (u16 LE)
///          |     rawSpeed (u16 LE)
///          常に 0（意味不明。ショット index / flags と推定）
/// ```
public struct FireReport: Sendable, Hashable {
    /// payload[0..1]。実測では常に 0。
    public let flags: UInt16
    public let rawSpeed: UInt16
    public let rawRev: UInt16

    /// 速度スケール。**実機で確定**（`docs/PROTOCOL.md` §7.3）:
    /// raw 325 / 278 / 375 が本体 LCD で 3.2 / 3.7 …と表示された（LCD は切り捨て表示）。
    /// 換算定数はこの 1 箇所だけに置く。
    public static let speedScale: Double = 100.0

    public var metersPerSecond: Double { Double(rawSpeed) / Self.speedScale }

    public init(flags: UInt16 = 0, rawSpeed: UInt16, rawRev: UInt16 = 0) {
        self.flags = flags
        self.rawSpeed = rawSpeed
        self.rawRev = rawRev
    }

    /// `0x52` フレームの payload（6 バイト）から読む。長さが足りなければ `nil`。
    public init?(payload: [UInt8]) {
        guard payload.count >= 6 else { return nil }
        self.init(
            flags: UInt16(payload[0]) | (UInt16(payload[1]) << 8),
            rawSpeed: UInt16(payload[2]) | (UInt16(payload[3]) << 8),
            rawRev: UInt16(payload[4]) | (UInt16(payload[5]) << 8)
        )
    }

    /// `0x63`（ログレコード）の payload を **`FIRE_REPORT` と同じ並び**とみなして読む。
    ///
    /// **これは推定である。**`0x63` の応答は 1 度も観測できていない
    /// （`docs/PROTOCOL.md` §6.6）。本体が「1 発の記録」を返すなら、同じ
    /// ファームウェアが `0x52` で使っている並び
    /// （`00 00 <speed LE16> <rev LE16>`）を再利用している可能性が最も高い、
    /// というだけの根拠しかない。
    ///
    /// そのため判定は**厳しめ**にする:
    /// * 6 バイト以上（`0x52` の payload 長）
    /// * flags（先頭 2 バイト）が 0 — `0x52` は実測 5 発とも 0 だった
    /// * rawSpeed > 0 — 0 m/s の記録はあり得ない
    ///
    /// 少しでも外れたら `nil` を返し、呼び出し側は**そこで読み出しを止めて
    /// 生データを保存する**。似ているだけの別形式を「速度」として保存してしまうと、
    /// 履歴に嘘の数字が混ざって後から見分けられなくなる。
    public static func logRecord(payload: [UInt8]) -> FireReport? {
        guard let report = FireReport(payload: payload),
              report.flags == 0,
              report.rawSpeed > 0
        else { return nil }
        return report
    }

    public func makeShot(timestamp: Date = Date()) -> Shot {
        Shot(
            timestamp: timestamp,
            velocityMetersPerSecond: metersPerSecond,
            // rawRev の単位が未確定なので換算しない（`Shot.rateOfFireRPS` の doc 参照）。
            rateOfFireRPS: nil,
            rawRateOfFire: rawRev
        )
    }
}

/// AC6000 MKIII BT の実プロトコルデコーダ。
///
/// `FrameAssembler` でフレームを切り出し、cmd ごとに `ChronoEvent` へ変換する。
///
/// 設計上の要点:
/// * **状態を持つ**（分割/連結された通知をまたいでバッファする）。`ChronoPacketDecoder` の
///   `decode` は非 mutating なので、内部状態はロックで守る（`@unchecked Sendable`）。
/// * **鍵は後から差し込める**（`ChronoKeyAwareDecoder`）。鍵は広告 manufacturer data から
///   得るため、生成時点では未知のことがある。
/// * **知らないフレームでも捨てない**。未知 cmd もチェックサム不一致も `.raw` として流す。
///   本体は要求していないフレーム（`0x47` / `0x5A` の自発通知）を送ってくるので、
///   「予期しないフレーム = エラー」にしてはいけない。
public final class MuzzlemeterDecoder: ChronoKeyAwareDecoder, @unchecked Sendable {
    /// チェックサム検証の厳しさ。
    public enum ChecksumPolicy: Sendable, Hashable {
        /// 鍵付きの総和（または鍵なしの総和）と一致しないフレームは `.raw` に落とす。
        case strict
        /// 鍵が未確定（0/0）の間は検証しない。鍵が分かってからは `strict` と同じ。
        ///
        /// 既定値。初回ペアリング（鍵未知）では本体からの応答を検証できないため、
        /// ここで弾いてしまうと鍵を受け取る `0x4B` 応答を読めなくなる。
        case lenientUntilKeysKnown
        /// 常に検証しない（解析・デバッグ用）。
        case ignore
    }

    private let lock = NSLock()
    private var assembler = FrameAssembler()
    /// 次に届く `0x63` 応答が何番目のレコードか。
    ///
    /// **応答に index が載っているかどうかが未確定**なので、要求と応答を 1 件ずつ
    /// 対にしている側（`ChronoDevice` の読み出しループ）に教えてもらう。
    /// 教えられていなければ `nil` のまま流す（嘘の番号を付けない）。
    private var expectedLogRecordIndex: Int?
    private let policy: ChecksumPolicy
    /// 時刻の注入点（テストで決定的にするため）。
    private let now: @Sendable () -> Date

    public init(
        keys: DeviceKeys = .zero,
        policy: ChecksumPolicy = .lenientUntilKeysKnown,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.now = now
        self.assembler.keys = keys
        self.assembler.acceptsUnkeyedChecksum = true
    }

    /// 現在の鍵。
    public var keys: DeviceKeys {
        lock.lock()
        defer { lock.unlock() }
        return assembler.keys
    }

    public func updateKeys(_ keys: DeviceKeys) {
        lock.lock()
        defer { lock.unlock() }
        assembler.keys = keys
    }

    /// 接続が切れたときにバッファを捨てる。切断をまたいで半端なフレームを残さない。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        assembler.reset()
        expectedLogRecordIndex = nil
    }

    /// 次に届く `0x63` 応答に付ける index を教える（`nil` で忘れる）。
    /// 読み出しは 1 件ずつ・応答を待ってから次を送るので、対応付けは一意に決まる。
    public func expectLogRecord(index: Int?) {
        lock.lock()
        defer { lock.unlock() }
        expectedLogRecordIndex = index
    }

    public func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        lock.lock()
        let outputs = assembler.append(data)
        let keysKnown = !assembler.keys.isZero
        lock.unlock()

        var events = [ChronoEvent]()
        events.reserveCapacity(outputs.count)
        for output in outputs {
            switch output {
            case .powerOff:
                events.append(.powerOff)
            case .frame(let frame, let raw):
                events.append(contentsOf: decode(frame: frame, raw: raw, characteristic: characteristic))
            case .invalid(let raw, let error):
                // チェックサムだけが理由で、まだ鍵が確定していない場合は読み進める。
                if case .checksumMismatch = error,
                   shouldAcceptUnverified(keysKnown: keysKnown),
                   let frame = Self.frameIgnoringChecksum(raw) {
                    events.append(contentsOf: decode(frame: frame, raw: raw, characteristic: characteristic))
                } else {
                    events.append(.raw(characteristic: characteristic, data: raw))
                }
            }
        }
        return events
    }

    private func shouldAcceptUnverified(keysKnown: Bool) -> Bool {
        switch policy {
        case .strict: false
        case .ignore: true
        case .lenientUntilKeysKnown: !keysKnown
        }
    }

    /// チェックサムを見ずにヘッダ/長さだけでフレームを組む（鍵未確定時の救済用）。
    private static func frameIgnoringChecksum(_ raw: Data) -> ChronoFrame? {
        let bytes = [UInt8](raw)
        guard bytes.count >= ChronoFrame.minimumLength, bytes[0] == ChronoFrame.header,
              Int(bytes[1]) == bytes.count
        else { return nil }
        return ChronoFrame(cmd: bytes[2], payload: Array(bytes[3..<(bytes.count - 1)]))
    }

    // MARK: - cmd ごとの解釈

    private func decode(frame: ChronoFrame, raw: Data, characteristic: UUID) -> [ChronoEvent] {
        // 未知 cmd は解釈せず .raw で上へ流す（本体は未文書のフレームも送ってくる）。
        guard let command = frame.command else {
            return [.raw(characteristic: characteristic, data: raw)]
        }
        switch command {
        case .fireReport:
            guard let report = FireReport(payload: frame.payload) else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.shot(report.makeShot(timestamp: now()))]

        case .ack:
            guard let target = frame.payload.first else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.ack(command: target)]

        case .currentAmmo:
            // aa 0a 5a 01 <slot> <ammo:4> cks
            guard frame.payload.count >= 6 else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            let record = AmmoRecord(
                slot: Int(frame.payload[1]),
                rawDiameter: le16(frame.payload, 2),
                rawWeight: le16(frame.payload, 4),
                isCurrent: true,
                marker: frame.payload[0]
            )
            return [.ammo(record)]

        case .ammoPreset:
            // aa 0b 47 <status> <marker> <idx> <ammo:4> cks
            // marker は実測で 0x41（読み出し応答）と 0x40（自発通知）の 2 通りがあった。
            // どちらも正常なフレームなので値では弾かない。
            guard frame.payload.count >= 7 else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            let record = AmmoRecord(
                slot: Int(frame.payload[2]),
                rawDiameter: le16(frame.payload, 3),
                rawWeight: le16(frame.payload, 5),
                isCurrent: false,
                marker: frame.payload[1]
            )
            return [.ammo(record)]

        case .logCount:
            // aa 06 62 <status> <count> cks。他の多バイト値が全て LE なので
            // payload[1] を件数と読む（BE16 説との区別は未検証・§6.5）。
            guard frame.payload.count >= 2 else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.logCount(Int(frame.payload[1]))]

        case .batteryReport, .batteryQuery:
            // **未検証**: キャプチャに 1 度も現れなかった。他の応答に倣い
            // payload = [status, value] と仮定し、1 バイトなら値そのものとみなす。
            guard let percent = frame.payload.count >= 2 ? frame.payload[1] : frame.payload.first
            else { return [.raw(characteristic: characteristic, data: raw)] }
            return [.battery(percent: Int(min(percent, 100)))]

        case .logRecord:
            // **未検証の形式。**生 payload は必ず流し、読めたときだけ 1 発として
            // 追加で流す（`.logRecordRaw` → `.logRecord` の順）。
            // 生を先に流すのは、解釈できなかったフレームでも同じ場所で拾えるようにするため。
            lock.lock()
            let index = expectedLogRecordIndex
            lock.unlock()
            var events: [ChronoEvent] = [.logRecordRaw(index: index, payload: frame.payload)]
            if let report = FireReport.logRecord(payload: frame.payload) {
                events.append(.logRecord(index: index, shot: report.makeShot(timestamp: now())))
            }
            return events

        case .readKey, .readDeviceSettings:
            // 0x4B 応答（鍵の受け渡し）は ChronoDevice がハンドシェイク中に
            // 生バイト列から読む。ここでは解釈せずそのまま流す。
            return [.raw(characteristic: characteristic, data: raw)]
        }
    }

    private func le16(_ payload: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < payload.count else { return 0 }
        return UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    }
}
