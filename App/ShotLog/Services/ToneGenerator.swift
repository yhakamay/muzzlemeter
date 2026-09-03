import Foundation

/// 短い通知音をその場で合成する。
///
/// 音源ファイルを持たないのは、
/// * `AudioServicesPlaySystemSound` のシステム音 ID は**非公開の数値**で、OS 更新で
///   音が変わったり消えたりする。「超過を知らせる音」が黙って別の音になるのは困る。
/// * 一方でバンドルした音声ファイルは、この用途（0.1 秒の正弦波）には過剰。
///
/// 生成するのは 16-bit / モノラルの WAV。`AVAudioPlayer(data:)` にそのまま渡せる。
enum ToneGenerator {
    struct Tone {
        var frequency: Double
        var seconds: Double
    }

    /// 複数の音を隙間を空けて並べた WAV データを作る。
    ///
    /// - Parameters:
    ///   - tones: 鳴らす音の並び
    ///   - gapSeconds: 音と音の間の無音
    ///   - amplitude: 0–1。既定は歪まず、うるさすぎない値。
    static func wav(
        tones: [Tone],
        gapSeconds: Double = 0.05,
        amplitude: Double = 0.6,
        sampleRate: Double = 44_100
    ) -> Data {
        var samples = [Int16]()
        for (index, tone) in tones.enumerated() {
            if index > 0 {
                samples.append(contentsOf: [Int16](repeating: 0, count: Int(gapSeconds * sampleRate)))
            }
            samples.append(
                contentsOf: sine(tone: tone, amplitude: amplitude, sampleRate: sampleRate)
            )
        }
        return wavContainer(samples: samples, sampleRate: sampleRate)
    }

    /// 1 音ぶんの正弦波。**前後に短いフェード**を入れる（無いと「プツッ」と鳴る）。
    private static func sine(tone: Tone, amplitude: Double, sampleRate: Double) -> [Int16] {
        let count = max(1, Int(tone.seconds * sampleRate))
        let fade = min(Double(count) / 2, 0.006 * sampleRate)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            var envelope = 1.0
            if fade > 0 {
                let position = Double(index)
                envelope = min(position / fade, Double(count - index) / fade, 1.0)
            }
            let value = sin(2 * .pi * tone.frequency * t) * amplitude * envelope
            return Int16(clamping: Int(value * Double(Int16.max)))
        }
    }

    /// 44 バイトの RIFF ヘッダ + PCM 本体。
    private static func wavContainer(samples: [Int16], sampleRate: Double) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36) + dataBytes)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))          // PCM のサブチャンク長
        append(UInt16(1))           // フォーマット = PCM
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        append("data")
        append(dataBytes)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
