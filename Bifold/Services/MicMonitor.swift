//
//  MicMonitor.swift
//  Bifold
//
//  Feeds the phone's real microphone into the emulated DS mic: an input tap
//  converts whatever the hardware delivers to mono s16 and hands it to the
//  core's ring buffer. Nothing is recorded or stored — samples go straight
//  into the emulated console and vanish.
//

import AVFoundation

final class MicMonitor {
    /// Mono s16 samples at the input's native rate (usually 48 kHz, close
    /// enough to the DS mic's 47.6 kHz that games can't tell).
    var onSamples: ((UnsafePointer<Int16>, Int) -> Void)?

    private var engine: AVAudioEngine?
    private var scratch = [Int16](repeating: 0, count: 8192)
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.isRunning, granted else { return }
                self.beginTap()
            }
        }
    }

    private func beginTap() {
        // The session category must allow input; defaultToSpeaker keeps game
        // audio on the loud speaker instead of the earpiece.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("Mic tap failed to start: \(error)")
            self.engine = nil
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let onSamples else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if scratch.count < frames { scratch = [Int16](repeating: 0, count: frames) }
        if let floats = buffer.floatChannelData?[0] {
            for i in 0..<frames {
                scratch[i] = Int16(max(-32768, min(32767, floats[i] * 32767)))
            }
        } else if let ints = buffer.int16ChannelData?[0] {
            for i in 0..<frames { scratch[i] = ints[i] }
        } else {
            return
        }
        scratch.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { onSamples(base, frames) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
