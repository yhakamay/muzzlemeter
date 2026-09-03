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

    /// 1 発ごとに弾速を読み上げるか。
    ///
    /// 既定は OFF。撃つたびに喋るのは好みが大きく分かれるので、
    /// 「知らないうちに喋り出した」を起こさない。
    var isSpeechEnabled: Bool {
        didSet { defaults.set(isSpeechEnabled, forKey: Keys.speech) }
    }

    /// 弾速に続けてジュールも読み上げるか。
    var speaksJoules: Bool {
        didSet { defaults.set(speaksJoules, forKey: Keys.speechJoules) }
    }

    /// 読み上げの速さ（`AVSpeechUtteranceMinimumSpeechRate`〜`Maximum`）。
    var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Keys.speechRate) }
    }

    static let minimumSpeechRate = Double(AVSpeechUtteranceMinimumSpeechRate)
    static let maximumSpeechRate = Double(AVSpeechUtteranceMaximumSpeechRate)
    static let defaultSpeechRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    private enum Keys {
        static let limitSound = "shotlog.feedback.limitSound"
        static let limitHaptics = "shotlog.feedback.limitHaptics"
        static let speech = "shotlog.feedback.speech"
        static let speechJoules = "shotlog.feedback.speechJoules"
        static let speechRate = "shotlog.feedback.speechRate"
    }

    private let defaults: UserDefaults
    /// テスト・Preview では何も鳴らさない。
    private let isSilent: Bool

    // MARK: - 再生

    // 以下は表示に関わらない実装の持ち物なので観測から外す
    // （`@Observable` は `lazy` を許さない、という実務上の理由も兼ねる）。
    /// 鳴らしている間だけ参照を保つ。ローカル変数にすると再生前に解放される。
    @ObservationIgnored private var players = [AVAudioPlayer]()
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// 音の再生とカテゴリの切り替えが噛み合わないよう、読み上げを遅らせるタスク。
    @ObservationIgnored private var speechTask: Task<Void, Never>?
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
        self.isSpeechEnabled = defaults.object(forKey: Keys.speech) as? Bool ?? false
        self.speaksJoules = defaults.object(forKey: Keys.speechJoules) as? Bool ?? false
        self.speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? Self.defaultSpeechRate
    }

    // MARK: - 規制上限

    /// 1 発ぶんの通知。上限に触れていなければ音も振動も出さない
    /// （普通に撃てている間は静かなのが正しい）。読み上げは設定 ON なら毎発。
    ///
    /// - Parameters:
    ///   - margin: 規制上限に対する段階
    ///   - speedText: 読み上げる弾速（表示単位の数値だけ。`"92.5"`）
    ///   - joulesText: 読み上げるジュール（数値だけ。`"1.03"`）
    func report(margin: EnergyMargin, speedText: String? = nil, joulesText: String? = nil) {
        var playedSound = false
        if margin.needsAttention {
            playHaptic(for: margin)
            playedSound = playSound(for: margin)
        }
        if let speedText {
            speak(speedText: speedText, joulesText: joulesText, margin: margin, afterTone: playedSound)
        }
    }

    /// **ハプティクスは設定 ON なら常に出す。** 音を切っている場面（屋内・夜）でも
    /// 「越えた」ことだけは手に伝わってほしい。
    private func playHaptic(for margin: EnergyMargin) {
        guard isLimitHapticsEnabled, !isSilent else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(margin.isOver ? .error : .warning)
    }

    /// 鳴らしたら `true`。読み上げの開始を遅らせるかの判断に使う。
    @discardableResult
    private func playSound(for margin: EnergyMargin) -> Bool {
        guard isLimitSoundEnabled else { return false }
        return play(margin.isOver ? overTone : cautionTone)
    }

    // MARK: - 読み上げ

    /// 弾速（＋任意でジュール、超過）を読み上げる。
    ///
    /// **前の発言は打ち切る。** フルオートでは 1 秒に 10 発以上届くので、順に読ませると
    /// 実際の射撃から何十秒も遅れた値を喋り続けることになる。読み上げの価値は
    /// 「いま撃った 1 発」を知ることなので、常に最新だけを言う。
    private func speak(
        speedText: String,
        joulesText: String?,
        margin: EnergyMargin,
        afterTone: Bool
    ) {
        guard isSpeechEnabled, !isSilent else { return }
        var text = speedText
        if speaksJoules, let joulesText {
            text = String(localized: "\(text)、\(joulesText) ジュール")
        }
        if margin.isOver {
            text += String(localized: "、超過")
        }

        speechTask?.cancel()
        // 通知音を鳴らした直後は、その音が鳴り終わってから喋り始める。
        // 読み上げは `.playback`（サイレントスイッチを無視する）でカテゴリを変えるので、
        // 鳴っている最中に切り替えると通知音の扱いまで変わってしまう。
        let delay: TimeInterval = afterTone ? 0.5 : 0
        speechTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.startSpeaking(text)
        }
    }

    private func startSpeaking(_ text: String) {
        configurePlaybackSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(
            min(max(speechRate, Self.minimumSpeechRate), Self.maximumSpeechRate)
        )
        // 端末の言語に合わせた声。日本語なら `"92.5"` を「きゅうじゅうにてんご」と読む。
        utterance.voice = AVSpeechSynthesisVoice(
            language: AVSpeechSynthesisVoice.currentLanguageCode()
        )
        synthesizer.speak(utterance)
    }

    // MARK: - 再生の下請け

    /// `.ambient` で鳴らす = **サイレントスイッチで消える**、他アプリの音楽も止めない。
    @discardableResult
    func play(_ wav: Data) -> Bool {
        guard !isSilent else { return false }
        configureAmbientSession()
        guard let player = try? AVAudioPlayer(data: wav) else { return false }
        player.prepareToPlay()
        players.append(player)
        player.play()
        // 再生ぶんの参照だけ持ち、鳴り終わったら捨てる（溜め続けない）。
        let duration = player.duration + 0.2
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.players.removeAll { $0 === player }
        }
        return true
    }

    private func configureAmbientSession() {
        let session = AVAudioSession.sharedInstance()
        // `.ambient` はサイレントスイッチに従い、他アプリの再生も止めない。
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    /// 読み上げ用。`.playback` は**サイレントスイッチを無視する**。
    ///
    /// 通知音とは意図的に扱いを変えている。読み上げを ON にするのは
    /// 「手も目も離せないので耳で知りたい」場面で、スイッチの位置で黙られると機能しない。
    /// この違いは設定画面の説明文にも書いてある。
    /// `.duckOthers` で音楽は下げるだけにし、`.mixWithOthers` で止めない。
    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers]
        )
        try? session.setActive(true, options: [])
    }
}
