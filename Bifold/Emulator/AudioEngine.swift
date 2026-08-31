//
//  AudioEngine.swift
//  Bifold
//
//  AVAudioEngine graph:  source node (48 kHz stereo float32) → mixer → output
//
//  The emulation thread pushes the core's int16 samples into a ring buffer.
//  The audio thread pulls them through a tiny linear-interpolation stage whose
//  ratio stays within ±1 % of 1.0 (dynamic rate control): the DS produces
//  audio at 59.83 fps while the display link runs at 60, so production and
//  consumption drift by ~0.3 %. Instead of dropping samples in chunks
//  (audible clicks) the read ratio drifts — inaudible.
//
//  Playback starts only after `targetFrames` of audio are buffered so normal
//  scheduling jitter never drains it; the fill level is low-pass filtered so
//  the ratio changes smoothly rather than per callback.
//

import AVFoundation

/// Interleaved stereo int16 ring buffer (counts are in frames). Single
/// producer (emulation thread), single consumer (audio thread).
final class AudioRingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Int16>
    private var head: Int = 0   // frames written
    private var tail: Int = 0   // frames consumed
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var availableFrames: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return head - tail
    }

    func clear() {
        os_unfair_lock_lock(lock)
        head = 0
        tail = 0
        os_unfair_lock_unlock(lock)
    }

    /// Producer. `fill` receives a contiguous destination and its capacity in
    /// frames and returns how many frames it wrote; called again if the free
    /// region wraps. Frames that do not fit are dropped.
    func write(maxFrames: Int, _ fill: (UnsafeMutablePointer<Int16>, Int) -> Int) {
        os_unfair_lock_lock(lock)
        var free = capacityFrames - (head - tail)
        os_unfair_lock_unlock(lock)
        var remaining = min(maxFrames, free)
        while remaining > 0 {
            let writeIndex = head % capacityFrames
            let contiguous = min(remaining, capacityFrames - writeIndex)
            let written = fill(storage + writeIndex * 2, contiguous)
            if written <= 0 { break }
            os_unfair_lock_lock(lock)
            head += written
            free = capacityFrames - (head - tail)
            os_unfair_lock_unlock(lock)
            remaining = min(remaining - written, free)
        }
    }

    /// Consumer. Copies up to `frames` frames starting at the read position
    /// WITHOUT consuming them. Returns the number copied; the rest of `out` is zeroed.
    func peek(into out: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        os_unfair_lock_lock(lock)
        let available = head - tail
        let start = tail
        os_unfair_lock_unlock(lock)
        let toCopy = min(frames, available)
        var copied = 0
        while copied < toCopy {
            let readIndex = (start + copied) % capacityFrames
            let contiguous = min(toCopy - copied, capacityFrames - readIndex)
            (out + copied * 2).update(from: storage + readIndex * 2, count: contiguous * 2)
            copied += contiguous
        }
        if copied < frames {
            (out + copied * 2).update(repeating: 0, count: (frames - copied) * 2)
        }
        return copied
    }

    /// Consumer. Marks `frames` frames as consumed.
    func advance(frames: Int) {
        os_unfair_lock_lock(lock)
        tail = min(head, tail + frames)
        os_unfair_lock_unlock(lock)
    }
}

final class AudioEngine: @unchecked Sendable {
    /// The core's fixed output rate (48 kHz).
    let sourceRate: Double
    let ring: AudioRingBuffer
    /// Buffered audio the rate controller steers towards, in seconds.
    private let targetSeconds = 0.08
    private var targetFrames: Int { Int(sourceRate * targetSeconds) }
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var mixWithOthers = false
    private var isRunning = false

    // Resampler state (audio thread only).
    private let scratch: UnsafeMutablePointer<Int16>
    private let scratchFrames = 8192
    private var phase: Double = 0          // fractional position into the next source frame
    private var histL: Float = 0           // last consumed sample (for interpolation)
    private var histR: Float = 0
    private var primed = false
    private var fillEMA: Double = 0
    private var ratio: Double = 1
    /// Set from other threads; the audio thread applies it at the next callback.
    private var resetRequested = false

    init(sampleRate: Double) {
        sourceRate = sampleRate
        // ~1.3 s of buffered audio headroom at 48 kHz.
        ring = AudioRingBuffer(capacityFrames: 65_536)
        scratch = .allocate(capacity: (scratchFrames + 2) * 2)
        scratch.initialize(repeating: 0, count: (scratchFrames + 2) * 2)

        attachSourceNode(rate: sampleRate)
        engine.mainMixerNode.outputVolume = 1
        configureSession(mixWithOthers: false)

        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended, self.isRunning {
                self.reset()
                try? self.engine.start()
            }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.reset()
            try? self.engine.start()
        }
    }

    /// Creates the source node at `rate` and wires it to the mixer.
    private func attachSourceNode(rate: Double) {
        if let old = sourceNode {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2, let left = abl[0].mData, let right = abl[1].mData else { return noErr }
            self.render(frames: Int(frameCount),
                        left: left.assumingMemoryBound(to: Float.self),
                        right: right.assumingMemoryBound(to: Float.self))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Output volume 0…1 (main thread).
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    /// Drops buffered audio and re-primes. Call whenever playback position jumps
    /// (load state, speed change, resume).
    func reset() {
        ring.clear()
        resetRequested = true
    }

    // MARK: Audio thread

    private func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if resetRequested {
            resetRequested = false
            primed = false
            phase = 0
            histL = 0
            histR = 0
            ratio = 1
        }
        let available = ring.availableFrames

        // Prime: stay silent until enough audio is queued.
        if !primed {
            if available >= targetFrames {
                primed = true
                fillEMA = Double(available)
                ratio = 1
            } else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return
            }
        }

        // Rate control: low-pass the fill level, steer the read ratio by ≤ ±1 %.
        let target = Double(targetFrames)
        fillEMA += (Double(available) - fillEMA) * 0.08
        let error = max(-1.0, min(1.0, (fillEMA - target) / target))
        ratio = 1.0 + error * 0.01

        var done = 0
        while done < frames {
            // Bound n so the source frames needed always fit in `scratch`.
            let n = min(frames - done, Int(Double(scratchFrames - 4) / max(ratio, 1)))
            // Source frames needed for n output frames at the current ratio.
            let total = phase + Double(n) * ratio
            let consumed = Int(total)                 // whole frames to consume
            let need = consumed + 1                   // +1 for the interpolation neighbour
            let got = ring.peek(into: scratch + 2, frames: need)   // scratch[0] holds the history sample
            if got < need {
                // Underrun: go silent and re-prime rather than crackle.
                (left + done).update(repeating: 0, count: frames - done)
                (right + done).update(repeating: 0, count: frames - done)
                primed = false
                phase = 0
                return
            }
            scratch[0] = Int16(max(-32768, min(32767, histL * 32768)))
            scratch[1] = Int16(max(-32768, min(32767, histR * 32768)))

            let scale: Float = 1.0 / 32768.0
            var p = phase
            for i in 0..<n {
                let j = Int(p)                        // 0 == history sample, 1 == first new frame
                let f = Float(p - Double(j))
                let l0 = Float(scratch[j * 2]) * scale
                let l1 = Float(scratch[(j + 1) * 2]) * scale
                let r0 = Float(scratch[j * 2 + 1]) * scale
                let r1 = Float(scratch[(j + 1) * 2 + 1]) * scale
                left[done + i] = l0 + (l1 - l0) * f
                right[done + i] = r0 + (r1 - r0) * f
                p += ratio
            }
            // Keep the last consumed source frame as the new history sample.
            histL = Float(scratch[consumed * 2]) * scale
            histR = Float(scratch[consumed * 2 + 1]) * scale
            ring.advance(frames: consumed)
            phase = total - Double(consumed)
            done += n
        }
    }

    // MARK: Session

    private func configureSession(mixWithOthers: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if mixWithOthers {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setPreferredIOBufferDuration(0.01)
        } catch {
            NSLog("AVAudioSession configuration failed: \(error)")
        }
        self.mixWithOthers = mixWithOthers
    }

    func setMixWithOthers(_ mix: Bool) {
        guard mix != mixWithOthers else { return }
        configureSession(mixWithOthers: mix)
        if isRunning {
            engine.stop()
            reset()
            try? engine.start()
        }
    }

    func start(mixWithOthers: Bool) {
        if mixWithOthers != self.mixWithOthers {
            configureSession(mixWithOthers: mixWithOthers)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                reset()
                try engine.start()
            }
            isRunning = true
        } catch {
            NSLog("AVAudioEngine failed to start: \(error)")
        }
    }

    func pause() {
        isRunning = false
        engine.pause()
        reset()
    }

    func stop() {
        isRunning = false
        engine.stop()
        reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
