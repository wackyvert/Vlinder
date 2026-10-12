import AVFoundation
import Foundation

/// The wall's sounds. There are two, both short: the tick of moving one card
/// along a band, and the slightly deeper one of stepping to another band.
///
/// They are synthesised rather than shipped as files — a 30ms decaying sine
/// with a touch of noise at its front is the whole recipe for a mechanical
/// detent, and building it here means there is no asset to lose and the pitch
/// and length are one number away if they ever want changing.
@MainActor
final class LiveWallSound {
    static let shared = LiveWallSound()

    enum Kind {
        case step, band
    }

    var isEnabled = true
    var volume: Float = 0.32

    /// A few players per sound, so a fast run along a band can overlap its
    /// ticks the way a real dial does instead of cutting each one short.
    private var players: [Kind: [AVAudioPlayer]] = [:]
    private var next: [Kind: Int] = [:]

    private init() {
        players[.step] = Self.makePlayers(count: 4, data: Self.tick(frequency: 1900, seconds: 0.028, noise: 0.18))
        players[.band] = Self.makePlayers(count: 3, data: Self.tick(frequency: 1150, seconds: 0.042, noise: 0.10))
    }

    func play(_ kind: Kind) {
        guard isEnabled, let pool = players[kind], !pool.isEmpty else { return }
        let index = (next[kind] ?? 0) % pool.count
        next[kind] = index + 1
        let player = pool[index]
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private static func makePlayers(count: Int, data: Data) -> [AVAudioPlayer] {
        (0..<count).compactMap { _ in
            guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else {
                return nil
            }
            player.prepareToPlay()
            return player
        }
    }

    // MARK: - Synthesis

    /// A detent: a sine that starts with a small burst of noise and dies away
    /// exponentially, rendered as 16-bit mono WAV at 44.1kHz.
    private static func tick(frequency: Double, seconds: Double, noise: Double) -> Data {
        let sampleRate = 44_100.0
        let count = Int(sampleRate * seconds)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 0x9E37_79B9

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(max(count - 1, 1))
            // Fast attack, exponential release: the whole thing is over before
            // the ear has time to hear it as a tone.
            let envelope = min(1, progress * 40) * exp(-progress * 6.5)
            let tone = sin(2 * .pi * frequency * t)
            // Cheap white noise, only in the first fraction of the sound.
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let random = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            let crackle = random * noise * exp(-progress * 30)
            let value = (tone * (1 - noise) + crackle) * envelope
            samples[i] = Int16(max(-1, min(1, value)) * 32_000)
        }

        return wav(samples: samples, sampleRate: Int(sampleRate))
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: MemoryLayout<T>.size))
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // bytes per second
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: byteCount))
        }
        return data
    }
}
