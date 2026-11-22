import AVFoundation
import CadenzaCore
import Foundation

/// Thread-safe sample ring for the audio tap. Holds recent performance
/// samples at the device rate; hands out one window per transcription step
/// and trims what the next window can no longer need.
final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    /// absolute sample index (since stream start) of ring[0]
    private var ringStart = 0
    private var rate: Double = 44100
    /// the tier's geometry: window spans and the ring's history budget
    private var plan: WindowPlan = .standard
    /// rms of the most recent tap buffer, read by the level timer on main
    private var latestLevel: Float = 0
    /// the streaming recording of the raw microphone; untouched by gain
    /// and tuning, so the .wav is the piano as it was heard
    private var recording: WavWriter.Sink?
    /// Samples the sink has not written yet. The tap only copies them here:
    /// a disk write must never happen on the thread that is capturing audio.
    private var staging: [Float] = []
    private var stagedCount = 0
    /// stretch applied at append: a4/440, slowing content so a piano tuned
    /// sharp of A=440 still lands on a 440-referenced model
    private var pitchRatio: Double = 1.0
    /// the user's input gain, folded into the model path at append
    private var gainValue: Float = 1.0
    /// fractional raw-sample read head for the streaming pitch correction
    private var readPos: Double = 0
    /// the raw sample just before the current chunk, for interpolation
    private var carry: Float = 0
    /// total raw samples the correction has seen, so the read head can
    /// address the global raw stream rather than one chunk
    private var rawConsumed = 0

    func reset(rate: Double, plan: WindowPlan = .standard, tuningA4: Double = 440, gain: Float = 1.0) {
        lock.lock()
        defer { lock.unlock() }
        ring = []
        ring.reserveCapacity(Int(plan.ringHistorySeconds * rate) + Self.trimSlack(rate: rate))
        ringStart = 0
        // correcting a4 to 440 stretches the stream; content therefore
        // ticks at deviceRate / stretch
        pitchRatio = tuningA4 > 0 ? tuningA4 / 440.0 : 1.0
        gainValue = gain
        self.rate = rate / pitchRatio
        self.plan = plan
        readPos = 0
        carry = 0
        rawConsumed = 0
    }

    /// Streams the raw microphone capture straight to a temp wav file, so a
    /// long session costs no RAM. Call sites: startRecording when capture
    /// begins, finishRecording when the session ends and saveSession moves
    /// the file into the session folder.
    func startRecording(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        recording?.close()
        recording = WavWriter.Sink(url: url, rate: rate)
        // two seconds of slack: the drain runs twice a second, so this only
        // fills when the disk itself stalls
        staging = [Float](repeating: 0, count: Int(rate * 2))
        stagedCount = 0
    }

    /// Hands the staged capture to the wav sink on the caller's thread. The
    /// tap never writes: it copies into the staging buffer under the lock,
    /// which is a memcpy rather than a file write.
    func drainRecording() {
        lock.lock()
        let sink = recording
        let count = stagedCount
        guard count > 0, sink != nil else {
            lock.unlock()
            return
        }
        let chunk = Array(staging[0..<count])
        stagedCount = 0
        lock.unlock()
        sink?.append(chunk)
    }

    /// Finalizes the streaming wav and hands back its url, or nil when
    /// nothing had been recorded.
    func finishRecording() -> URL? {
        drainRecording()
        lock.lock()
        defer { lock.unlock() }
        guard let recording, recording.frameCount > 0 else {
            recording?.close()
            self.recording = nil
            return nil
        }
        recording.close()
        let url = recording.url
        self.recording = nil
        return url
    }

    /// Discards the recording in progress and deletes its file.
    func discardRecording() {
        lock.lock()
        defer { lock.unlock() }
        recording?.closeAndDelete()
        recording = nil
    }

    /// Convenience for the probes, which hold an array already.
    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// The capture path. Takes a pointer so the tap does not have to allocate
    /// an array per buffer on the audio thread.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        // model path: the user's gain, and the tuning stretch that walks a
        // stream tuned to a4 back onto 440; raw stays untouched for the wav
        var modelPath: [Float]? = nil
        if pitchRatio != 1.0 || gainValue != 1.0 {
            let chunkStart = rawConsumed
            let count = samples.count
            let outCount = Int((Double(count) * pitchRatio).rounded(.down))
            var out = [Float]()
            out.reserveCapacity(outCount + 1)
            for n in 0..<max(outCount, 1) {
                // out[n] reads raw global position readPos + n / ratio,
                // which inside this chunk is readPos - chunkStart ahead
                let g = readPos + Double(n) / pitchRatio
                let i = Int(g.rounded(.down))
                let frac = g - Double(i)
                let a = read(chunk: samples, chunkStart: chunkStart, index: i)
                let b = read(chunk: samples, chunkStart: chunkStart, index: i + 1)
                out.append((a + (b - a) * Float(frac)) * gainValue)
            }
            readPos += Double(max(outCount, 1)) / pitchRatio
            carry = samples.last ?? 0
            modelPath = out
        }
        rawConsumed += samples.count
        if let modelPath {
            ring.append(contentsOf: modelPath)
        } else {
            ring.append(contentsOf: samples)
        }
        if recording != nil {
            // copy, never write: the drain moves it to the file
            let needed = stagedCount + samples.count
            if needed > staging.count {
                // rare: the disk stalled for longer than the slack
                staging.append(contentsOf: repeatElement(0, count: needed - staging.count))
            }
            if let destination = staging.withUnsafeMutableBufferPointer({ $0.baseAddress }) {
                var offset = stagedCount
                for sample in samples {
                    destination[offset] = sample
                    offset += 1
                }
                stagedCount = needed
            }
        }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        latestLevel = Float(sqrt(sum / Double(max(samples.count, 1))))
        // Keep what a window could still reach back to; older audio can no
        // longer be needed. Trimming runs in batches: every removeFirst moves
        // the live history, so doing it per 85 ms buffer meant memmoving
        // megabytes a dozen times a second for no reason.
        let cap = Int(plan.ringHistorySeconds * rate)
        if ring.count > cap + Self.trimSlack(rate: rate) {
            let drop = ring.count - cap
            ring.removeFirst(drop)
            ringStart += drop
        }
    }

    /// How much history may pile up above the cap before a trim pays for
    /// itself: a few seconds of audio, well under a window's worth.
    private static func trimSlack(rate: Double) -> Int {
        Int((rate * 4).rounded())
    }

    /// Raw sample at global stream index `index` when the current chunk
    /// starts at `chunkStart`: before the chunk the carry speaks, inside it
    /// the buffer (clamped at its end).
    private func read(chunk: UnsafeBufferPointer<Float>, chunkStart: Int, index: Int) -> Float {
        let local = index - chunkStart
        if local < 0 { return carry }
        return chunk[min(local, chunk.count - 1)]
    }

    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    /// Peak amplitude in the newest `seconds` of audio. The transcription
    /// engine asks this before it spends a decode: a window of silence has
    /// nothing to transcribe, and skipping it is the difference between a
    /// warm laptop and a cool one during a practice session.
    func recentPeak(seconds: Double) -> Float {
        lock.lock()
        let rate = self.rate
        let span = Int((seconds * rate).rounded())
        let end = ringStart + ring.count
        let from = max(ringStart, end - span)
        var peak: Float = 0
        if end > from {
            let base = from - ringStart
            ring.withUnsafeBufferPointer { buffer in
                guard let start = buffer.baseAddress else { return }
                for index in base..<buffer.count {
                    let value = abs(start[index])
                    if value > peak { peak = value }
                }
            }
        }
        lock.unlock()
        return peak
    }

    func receivedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(ringStart + ring.count) / rate
    }

    func deviceRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return rate
    }

    /// Returns the window `index`'s full content, or nil while not enough of
    /// it has arrived. Window `index` covers performance seconds
    /// `index * stepSeconds - padSeconds` through `+ segmentSeconds`.
    func takeWindow(index: Int) -> [Float]? {
        lock.lock()
        let plan = self.plan
        let rate = self.rate
        lock.unlock()
        let stepSeconds = plan.stepWallSeconds
        let startSeconds = Double(index) * stepSeconds - plan.padSeconds
        let endSeconds = startSeconds + plan.segmentSeconds
        let startSample = Int((startSeconds * rate).rounded())
        let endSample = Int((endSeconds * rate).rounded())

        lock.lock()
        defer { lock.unlock() }
        guard ringStart + ring.count >= endSample else { return nil }
        var out = [Float](repeating: 0, count: max(endSample - startSample, 0))
        let from = max(startSample, ringStart)
        let to = min(endSample, ringStart + ring.count)
        if to > from {
            out.replaceSubrange((from - startSample)..<(to - startSample),
                                with: ring[(from - ringStart)..<(to - ringStart)])
        }
        // the next window starts one step later; everything before is spent
        let nextStartSample = Int(((Double(index + 1) * stepSeconds - plan.padSeconds) * rate).rounded())
        if nextStartSample > ringStart {
            let drop = min(nextStartSample - ringStart, ring.count)
            ring.removeFirst(drop)
            ringStart += drop
        }
        return out
    }

    /// Returns the streaming window ending at `edgeSeconds` content time,
    /// spanning `segmentSeconds` behind it, or nil while the edge has not
    /// arrived. Missing leading audio (the performance is younger than the
    /// window) arrives as zeros, which is what the model's leading pad
    /// semantics expect.
    func takeStreamWindow(edgeSeconds: Double) -> [Float]? {
        lock.lock()
        let plan = self.plan
        lock.unlock()
        let startSeconds = edgeSeconds - plan.segmentSeconds
        let startSample = Int((startSeconds * rate).rounded())
        let endSample = Int((edgeSeconds * rate).rounded())

        lock.lock()
        defer { lock.unlock() }
        guard ringStart + ring.count >= endSample else { return nil }
        var out = [Float](repeating: 0, count: max(endSample - startSample, 0))
        let from = max(startSample, ringStart)
        let to = min(endSample, ringStart + ring.count)
        if to > from {
            out.replaceSubrange((from - startSample)..<(to - startSample),
                                with: ring[(from - ringStart)..<(to - ringStart)])
        }
        // No trim here: the ring keeps ringHistorySeconds, which is longer
        // than a window spans, so append owns the one place history shrinks.
        return out
    }
}
