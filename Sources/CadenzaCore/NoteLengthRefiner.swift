import Accelerate
import Foundation

/// Refines how long a note lasts from the audio itself.
///
/// The backbone's interval ends are unreliable for short and mid-length
/// notes: a key held for 0.3 to 1.1 s comes back as a 50 ms blip, while two
/// second notes decode correctly. What the model cannot say, the signal can:
/// a struck note keeps a harmonic series alive at its own pitch until the key
/// (or the pedal) lets it go. This tracker follows that series per note and
/// moves the end to where the sound actually stops.
///
/// It only ever extends a note, and only when the extension is unmistakable:
/// the energy at the note's fundamental and first harmonics has to stay
/// within 30 dB of the note's own attack peak and well above the window's
/// noise floor. Truncation is left to later calibration, because a wrong cut
/// is far more audible than a slightly long tail.
public final class NoteLengthRefiner {
    /// Sentinels for "the model could not say" live in the caller, so the
    /// refiner only deals in seconds.
    public struct Span: Equatable, Sendable {
        public var pitch: Int
        public var onset: Double
        public var offset: Double
        public var hasOffset: Bool
        public init(pitch: Int, onset: Double, offset: Double, hasOffset: Bool) {
            self.pitch = pitch
            self.onset = onset
            self.offset = offset
            self.hasOffset = hasOffset
        }
    }

    public struct Options: Sendable {
        /// Window and hop of the analysis, matching the backbone's own mel
        /// grid so frame times line up with the decoded intervals.
        public var windowSize = MelFrontEnd.windowSize
        public var hopSize = MelFrontEnd.hopSize
        /// Harmonics summed per pitch: enough to tell a held note from
        /// another note's leakage, few enough to stay cheap at the top.
        public var harmonicCount = 5
        /// How far below the attack peak still counts as sounding.
        public var floorDecibels: Float = -30
        /// Extensions shorter than this are not worth touching.
        public var minimumGain = 0.04
        /// A note is never made longer than this by the refiner alone.
        public var maximumTail = 4.0
        /// …nor by more than this beyond the length the model decoded, when
        /// the note sounds alone and its harmonics are unambiguous.
        public var maximumGain = 1.2
        /// The same cap while other notes sound at the same time: their
        /// partials feed this pitch's band, so a long extension there is far
        /// more likely to be somebody else's sound than this note ringing.
        public var denseMaximumGain = 0.35
        /// Gaps this long (in frames) end a note even if energy returns.
        public var releaseGapFrames = 4
        public var minimumDuration = 0.05
        public init() {}
    }

    private let rate: Double
    private let options: Options
    private let fftSetup: FFTSetup

    public init(rate: Double = 44100, options: Options = Options()) {
        self.rate = rate
        self.options = options
        // 4096 samples: 12 splits
        fftSetup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Extends spans whose sound demonstrably outlasts them. `samples` is one
    /// window of mono audio at `rate`; `windowBegin` is the content time of
    /// its first sample, so returned offsets stay in content seconds.
    public func refine(_ spans: [Span], samples: [Float], windowBegin: Double) -> [Span] {
        guard !spans.isEmpty, samples.count > options.windowSize else { return spans }
        let hop = options.hopSize
        let frameCount = (samples.count - options.windowSize) / hop + 1
        guard frameCount > 2 else { return spans }
        let frameDuration = Double(hop) / rate

        // Only spans the model collapsed need help, and only they are safe to
        // touch: a note it already gave a plausible length to is left alone.
        // Only spans the model collapsed need help. Widening this to a third
        // of a second changed nothing on either benchmark or on a real session,
        // so it stays where the evidence is: the notes it provably mangles.
        let collapsed = spans.map { $0.offset - $0.onset < 0.12 }
        guard collapsed.contains(true) else { return spans }

        let magnitudes = spectrogram(samples, frameCount: frameCount)
        var refined = spans
        for index in refined.indices {
            let span = refined[index]
            guard collapsed[index] else { continue }
            let localOnset = (span.onset - windowBegin) / frameDuration
            let localOffset = (span.offset - windowBegin) / frameDuration
            let onsetFrame = max(0, min(frameCount - 1, Int(localOnset.rounded())))
            let offsetFrame = max(onsetFrame, min(frameCount - 1, Int(localOffset.rounded())))
            let energy = bandEnergy(pitch: span.pitch, magnitudes: magnitudes, frameCount: frameCount)
            // how many other notes sound around this one's attack
            let neighbours = spans.filter { other in
                other.pitch != span.pitch
                    && other.onset < span.onset + 0.12
                    && other.offset > span.onset - 0.12
            }.count
            var gain = neighbours >= 2 ? options.denseMaximumGain : options.maximumGain
            // never reach across the next strike of the same key: the drop it
            // makes is that note's release, not this one's
            if let next = spans.filter({ $0.pitch == span.pitch && $0.onset > span.onset + 0.05 })
                .map({ $0.onset }).min() {
                gain = min(gain, max(0, next - 0.02 - span.offset))
            }
            guard let release = releaseFrame(energy, onsetFrame: onsetFrame,
                                            offsetFrame: offsetFrame, frameCount: frameCount,
                                            maximumGain: gain) else { continue }
            let target = windowBegin + Double(release) * frameDuration
            guard target > span.offset + options.minimumGain else { continue }
            refined[index].offset = max(span.offset, target)
            refined[index].hasOffset = true
        }
        return refined
    }

    /// Where the note stops: a release damps the string in a few frames, so
    /// the end of a note is the steepest relative drop in its own harmonic
    /// energy, not the point where the energy crosses some absolute floor.
    /// A note that merely decays has no such drop and keeps the model's end.
    private func releaseFrame(_ energy: [Float], onsetFrame: Int, offsetFrame: Int,
                              frameCount: Int, maximumGain: Double) -> Int? {
        let frameDuration = Double(options.hopSize) / rate
        let searchGain = Int((maximumGain / frameDuration).rounded())
        let low = max(onsetFrame + 2, offsetFrame - 2)
        let high = min(frameCount - 2, offsetFrame + max(2, searchGain))
        guard high > low else { return nil }
        // the pitch has to be audible before the drop for the drop to mean
        // anything: measure it against the note's own attack
        var peak: Float = 0
        for frame in max(0, onsetFrame - 1)...min(frameCount - 1, onsetFrame + 3) {
            peak = max(peak, energy[frame])
        }
        guard peak > 0 else { return nil }
        let audible = peak * powf(10, options.floorDecibels / 20)
        // candidate drops, strongest first: the first one after which the
        // pitch really stays gone is the release. A dip that recovers is a
        // beat or another note's partial, not the end of this one.
        var candidates: [(frame: Int, drop: Float)] = []
        for frame in low...high {
            let before = energy[frame - 2]
            guard before > audible else { continue }
            let drop = (before - energy[frame]) / before
            if drop >= 0.45 { candidates.append((frame, drop)) }
        }
        candidates.sort { $0.drop > $1.drop }
        for candidate in candidates {
            let before = energy[candidate.frame - 2]
            var after: Float = 0
            var counted = 0
            for frame in (candidate.frame + 1)...min(frameCount - 1, candidate.frame + 4) {
                after += energy[frame]
                counted += 1
            }
            guard counted > 0 else { continue }
            // the note is over when it stays at least 6 dB down afterwards
            if after / Float(counted) <= before * 0.5 {
                return candidate.frame - 1
            }
        }
        return nil
    }

    /// Linear magnitude spectrogram, [frame][bin], Hann-windowed.
    private func spectrogram(_ samples: [Float], frameCount: Int) -> [Float] {
        let window = options.windowSize
        let half = window / 2
        var magnitudes = [Float](repeating: 0, count: frameCount * (half + 1))
        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var powers = [Float](repeating: 0, count: half + 1)
        let log2n = vDSP_Length(round(log2(Double(window))))
        for index in 0..<frameCount {
            let start = index * options.hopSize
            samples.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + start, 1, hann, 1, &frame, 1, vDSP_Length(window))
            }
            for k in 0..<half {
                real[k] = frame[2 * k]
                imag[k] = frame[2 * k + 1]
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    powers[0] = realBuffer[0] * realBuffer[0]
                    powers[half] = imagBuffer[0] * imagBuffer[0]
                    for k in 1..<half {
                        powers[k] = realBuffer[k] * realBuffer[k] + imagBuffer[k] * imagBuffer[k]
                    }
                }
            }
            // sqrt of the power gives the magnitude the thresholds are in
            var count = UInt32(half + 1)
            var source = powers
            vvsqrtf(&magnitudes[index * (half + 1)], &source, &count)
        }
        return magnitudes
    }

    /// Summed magnitude at the pitch's first harmonics, one spectrum per
    /// frame. A missing fundamental still leaves enough of its series to
    /// track, which is what keeps this working at the top of the keyboard.
    private func bandEnergy(pitch: Int, magnitudes: [Float], frameCount: Int) -> [Float] {
        let half = options.windowSize / 2
        let binCount = half + 1
        let binWidth = rate / Double(options.windowSize)
        let f0 = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
        var bins: [Int] = []
        for harmonic in 1...options.harmonicCount {
            let frequency = f0 * Double(harmonic)
            if frequency > rate / 2 * 0.95 { break }
            bins.append(Int((frequency / binWidth).rounded()))
        }
        guard !bins.isEmpty else { return [Float](repeating: 0, count: frameCount) }
        var energy = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            let base = frame * binCount
            for bin in bins {
                let low = max(0, bin - 1)
                let high = min(binCount - 1, bin + 1)
                var peak: Float = 0
                for index in low...high { peak = max(peak, magnitudes[base + index]) }
                sum += peak
            }
            energy[frame] = sum / Float(bins.count)
        }
        return energy
    }
}
