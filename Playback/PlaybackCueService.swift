import Foundation

// AI CONTEXT — Playback/PlaybackCueService.swift
//
// PURPOSE:
// Stateless generator for short playback-transition audio cues. During AppState
// decomposition Stage 2 it owns only Play Instant's existing two-note PCM/WAV
// generation. AppState still owns AVAudioPlayer lifetime, volume, cancellation,
// and the Play Instant state machine; those responsibilities move only in the
// later PlaybackCoordinator stage.
//
// CONCURRENCY / PERSISTENCE:
// Pure synchronous value generation. It reads no mutable state, touches no files,
// starts no audio session, publishes no event, and is safe to call from any
// isolation domain.
//
// INVARIANTS:
// - Preserve the existing 22,050 Hz, mono, signed 16-bit little-endian waveform.
// - Preserve note timing, frequencies, envelope, amplitude, and WAV layout.
// - Do not retain AVAudioPlayer or introduce bundled/network sound dependencies.
enum PlaybackCueService {
    static func makePlayInstantWarningWAV() -> Data? {
        let sampleRate = 22_050
        let duration = 0.55
        let sampleCount = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let frequency = time < 0.25 ? 523.25 : (time < 0.30 ? 0 : 659.25)
            let localTime = time < 0.30 ? time : time - 0.30
            let noteDuration = time < 0.30 ? 0.25 : 0.25
            let envelope = frequency == 0 ? 0 : min(1, localTime / 0.025) * min(1, (noteDuration - localTime) / 0.05)
            let value = Int16((sin(2 * .pi * frequency * time) * max(0, envelope) * 8_000).rounded())
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func appendASCII(_ value: String) { wav.append(value.data(using: .ascii)!) }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        appendASCII("RIFF"); appendUInt32(UInt32(36 + pcm.count)); appendASCII("WAVE")
        appendASCII("fmt "); appendUInt32(16); appendUInt16(1); appendUInt16(1)
        appendUInt32(UInt32(sampleRate)); appendUInt32(UInt32(sampleRate * 2)); appendUInt16(2); appendUInt16(16)
        appendASCII("data"); appendUInt32(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
}
