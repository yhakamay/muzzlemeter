import AVFoundation
import Observation
import ShotLogKit
import UIKit

/// 音・振動という「画面を見ていなくても届く」出力をまとめた小さなサービス。
///
/// なぜ `ChronoService` から分けるか:
/// * `ChronoService` は**受信を絶対に待たせない**のが原則で、`AVAudioSession` の
///   設定や音の再生のような遅い処理をそこに混ぜたくない。
/// * 音を鳴らすかどうかは設定であり、テストや Preview では黙らせたい。
///
/// 音は**サイレントスイッチに従う**（`AVAudioSession` のカテゴリ `.ambient`）。
/// 射撃中に周りへ音を出したくない場面があるため、スイッチの意図を尊重する。
@MainActor
@Observable
final class FeedbackService {
    // MARK: - 設定（UserDefaults 永続）

    /// 規制上限に触れた・越えたときに音を鳴らすか。
    var isLimitSoundEnabled: Bool {
        didSet { defaults.set(isLimitSoundEnabled, forKey: Keys.limitSound) }
    }

    /// 規制上限に触れた・越えたときに振動させるか。
    var isLimitHapticsEnabled: Bool {
        didSet { defaults.set(isLimitHapticsEnabled, forKey: Keys.limitHaptics) }
    }

    private enum Keys {
        static let limitSound = "shotlog.feedback.limitSound"
        static let limitHaptics = "shotlog.feedback.limitHaptics"
    }

    private let defaults: UserDefaults
    /// テスト・Preview では何も鳴らさない。
    private let isSilent: Bool

    // MARK: - 再生

    // 以下は表示に関わらない実装の持ち物なので観測から外す
    // （`@Observable` は `lazy` を許さない、という実務上の理由も兼ねる）。
    /// 鳴らしている間だけ参照を保つ。ローカル変数にすると再生前に解放される。
    @ObservationIgnored private var players = [AVAudioPlayer]()
    @ObservationIgnored private lazy var cautionTone = ToneGenerator.wav(tones: [.init(frequency: 880, seconds: 0.10)])
    @ObservationIgnored private lazy var overTone = ToneGenerator.wav(
        tones: [
            .init(frequency: 1_320, seconds: 0.10),
            .init(frequency: 1_320, seconds: 0.10),
            .init(frequency: 1_320, seconds: 0.16),
        ]
    )

    init(defaults: UserDefaults = .standard, isSilent: Bool = false) {
        self.defaults = defaults
        self.isSilent = isSilent
        self.isLimitSoundEnabled = defaults.object(forKey: Keys.limitSound) as? Bool ?? true
        self.isLimitHapticsEnabled = defaults.object(forKey: Keys.limitHaptics) as? Bool ?? true
    }

    // MARK: - 規制上限

    /// 1 発ぶんの通知。`.safe` では何もしない（普通に撃てている間は静かなのが正しい）。
    func report(margin: EnergyMargin) {
        guard margin.needsAttention else { return }
        playHaptic(for: margin)
        playSound(for: margin)
    }

    /// **ハプティクスは設定 ON なら常に出す。** 音を切っている場面（屋内・夜）でも
    /// 「越えた」ことだけは手に伝わってほしい。
    private func playHaptic(for margin: EnergyMargin) {
        guard isLimitHapticsEnabled, !isSilent else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(margin.isOver ? .error : .warning)
    }

    private func playSound(for margin: EnergyMargin) {
        guard isLimitSoundEnabled else { return }
        play(margin.isOver ? overTone : cautionTone)
    }

    // MARK: - 再生の下請け

    /// `.ambient` で鳴らす = **サイレントスイッチで消える**、他アプリの音楽も止めない。
    func play(_ wav: Data) {
        guard !isSilent else { return }
        configureAmbientSession()
        guard let player = try? AVAudioPlayer(data: wav) else { return }
        player.prepareToPlay()
        players.append(player)
        player.play()
        // 再生ぶんの参照だけ持ち、鳴り終わったら捨てる（溜め続けない）。
        let duration = player.duration + 0.2
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.players.removeAll { $0 === player }
        }
    }

    private func configureAmbientSession() {
        let session = AVAudioSession.sharedInstance()
        // `.ambient` はサイレントスイッチに従い、他アプリの再生も止めない。
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }
}
