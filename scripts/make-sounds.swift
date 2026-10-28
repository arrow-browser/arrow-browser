// Synthesizes Arrow's two sound effects into Resources/Sounds:
// - event.caf: a soft chime (copy, pin, archive…);
// - capture.caf: a camera shutter (captures).
// They are generated from scratch; the partials, envelopes and timings
// follow measurements of Arc's sounds (no samples are reused).
// Usage: swift scripts/make-sounds.swift
import AVFoundation
import Foundation

let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Sounds", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Deterministic noise, so the files only change when this script does.
struct Noise {
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }
}

/// Band-pass biquad (RBJ cookbook, constant peak gain).
struct BandPass {
    let b0, b2, a1, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(frequency: Float, q: Float, rate: Float) {
        let w = 2 * Float.pi * frequency / rate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

func decibels(_ db: Float) -> Float { pow(10, db / 20) }

func write(_ samples: [Float], rate: Double, peak: Float, to name: String) throws {
    let scale = peak / (samples.map(abs).max() ?? 1)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample * scale }
    let url = output.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ])
    try file.write(from: buffer)
    print("wrote \(url.path)")
}

// MARK: - Chime

do {
    let rate: Float = 44100
    let count = Int(rate * 2.4)
    // (frequency, level in dB, seconds to fade by 60 dB). Close pairs beat
    // at ~4 Hz, which gives the chime its shimmer.
    let partials: [(Float, Float, Float)] = [
        (185, -9, 2.4), (371, 0, 2.8), (375, -6, 2.8), (620, -2, 2.6), (624, -8, 2.6),
        (743, -14, 1.8), (1238, -14, 1.4), (2223, -13, 1.2), (3741, -20, 0.8),
    ]
    var noise = Noise()
    var samples = [Float](repeating: 0, count: count)
    for index in 0..<count {
        let t = Float(index) / rate
        var value: Float = 0
        for (frequency, level, t60) in partials {
            value += decibels(level) * exp(-6.9 * t / t60) * sin(2 * .pi * frequency * t)
        }
        // Mallet strike: 3 ms of noise.
        if t < 0.003 { value += 0.05 * noise.next() * (1 - t / 0.003) }
        let attack = min(1, t / 0.015)
        let release = min(1, (2.4 - t) / 0.2)
        samples[index] = value * attack * release
    }
    try write(samples, rate: Double(rate), peak: 0.29, to: "event.caf")
}

// MARK: - Shutter

do {
    let rate: Float = 48000
    let count = Int(rate * 0.46)
    var noise = Noise()
    var samples = [Float](repeating: 0, count: count)

    // Clicks: resonant bodies excited by a short noise burst.
    let clicks: [(start: Float, level: Float, ring: Float, thump: Bool)] = [
        (0.024, -10, 0.004, false), (0.078, -2, 0.022, true), (0.162, -3, 0.005, false),
    ]
    for click in clicks {
        let start = Int(click.start * rate)
        for offset in 0..<Int(0.08 * rate) where start + offset < count {
            let t = Float(offset) / rate
            var value = 0.6 * noise.next() * exp(-t / 0.002)
            for (frequency, level) in [(1500 as Float, 0 as Float), (4050, -1), (6900, -1), (3200, -3)] {
                value += decibels(level) * exp(-t / click.ring) * sin(2 * .pi * frequency * t + frequency)
            }
            if click.thump { value += 0.5 * exp(-t / 0.035) * sin(2 * .pi * 150 * t) }
            samples[start + offset] += decibels(click.level) * value
        }
    }

    // Winding whir: noise around 6.2 kHz with a fainter 3.15 kHz hum,
    // swelling from 180 to 360 ms and cut at 440 ms.
    var filter = BandPass(frequency: 6200, q: 2.5, rate: rate)
    for index in Int(0.17 * rate)..<count {
        let t = Float(index) / rate
        let swell = t < 0.36 ? decibels(-40 + 11 * (t - 0.17) / 0.19)
            : decibels(-29 - 30 * pow(max(0, t - 0.38) / 0.06, 2)) * (t < 0.44 ? 1 : 0)
        let whir = filter.process(noise.next()) * 4 + 0.35 * sin(2 * .pi * 3150 * t) * (0.7 + 0.3 * sin(2 * .pi * 45 * t))
        samples[index] += 9 * swell * whir
    }
    try write(samples, rate: Double(rate), peak: 0.38, to: "capture.caf")
}
