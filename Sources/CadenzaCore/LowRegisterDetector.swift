import Accelerate
import Foundation

/// Finds the bass notes the transcription model cannot hear.
///
/// The pretrained backbone is blind in the lowest register. Measured on
/// isolated synthetic notes and confirmed against the reference PyTorch model
/// on the same audio: G1 at any velocity is never decoded, C2 and D2 only in
/// some contexts, while G2 and above are reliable. The cause is upstream of
/// this port: the model's mel filterbank has two to four semitones per band
/// below C2, and no amount of faithful porting recovers pitch it never saw.
///
/// So the bass is taken from the signal instead, on the one condition that
/// makes it safe to add notes: a low fundamental has to *persist*, struck
/// once and then held. A partial borrowed from a higher note flickers with
/// the beating of the notes above it and cannot hold a steady peak for a
/// tenth of a second, which is exactly what this tracker requires.
public final class LowRegisterDetector {
    /// The note as the detector sees it, in content seconds.
    public struct Span: Equatable, Sendable {
        public var pitch: Int
        public var onset: Double
        public var offset: Double
        public var velocity: Int
        public init(pitch: Int, onset: Double, offset: Double, velocity: Int) {
            self.pitch = pitch
            self.onset = onset
            self.offset = offset
            self.velocity = velocity
        }
    }

    public struct Options: Sendable {
        /// Where the model stops working: pitches below this are the
        /// detector's business, pitches above stay the model's.
        public var highestPitch = 40
        public var lowestPitch = 21
        /// Long window for the frequency resolution the bass needs (5.4 Hz
        /// per bin at 44.1 kHz), short hop for onset timing.
        public var windowSize = 8192
        public var hopSize = 1024
        /// How long a low fundamental must hold before it counts as a note.
        public var stabilitySeconds = 0.12
        /// A note whose peak is quieter than this share of the loudest bass
        /// moment in the window is room tone, not playing.
        public var relativeToLoudest: Float = 0.02
        /// A bass note has to be loud in its own right: a peak that borrows a
        /// subharmonic of a note far above it is tens of decibels weaker than
        /// that note, and a struck bass string is not.
        public var relativeToSpectrum: Float = 0.25
        /// How periodic the waveform has to be at the note's own period.
        /// A struck string repeats itself almost exactly; room tone does not
        /// repeat at all, whatever its spectrum looks like.
        public var minimumPeriodicity: Float = 0.45
        /// The pitch may wobble this far over a note and still be steady;
        /// noise wanders much further.
        public var maximumWobble = 0.7
        /// Energy has to appear this abruptly to be a strike rather than the
        /// swell of a note already sounding.
        public var attackRise: Float = 2.0
        /// …within this many frames of the run starting.
        public var attackFrames = 3
        /// Frames quieter than this, relative to the loudest low moment in
        /// the window, are tails, not notes.
        public var floorDecibels: Float = -34
        /// A run this short is a knock or a click, not a note.
        public var minimumDuration = 0.08
        /// A release this far below the note's own peak, held for a few
        /// frames, ends it.
        public var releaseFraction: Float = 0.35
        public var releaseFrames = 4
        /// Notes the model already has, this close in time, are not repeated.
        public var duplicateTolerance = 0.075
        public init() {}
    }

    private let rate: Double
    private let options: Options
    private let fftSetup: FFTSetup

    public init(rate: Double = 44100, options: Options = Options()) {
        self.rate = rate
        self.options = options
        let log2n = vDSP_Length(round(log2(Double(options.windowSize))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Returns the notes the signal holds in the bass that `existing` does not
    /// already cover. Times are content seconds; `windowBegin` is the content
    /// time of the first sample.
    public func detect(samples: [Float], windowBegin: Double, existing: [Span]) -> [Span] {
        let window = options.windowSize
        guard samples.count > window else { return [] }
        let frameCount = (samples.count - window) / options.hopSize + 1
        guard frameCount > 3 else { return [] }
        let frameDuration = Double(options.hopSize) / rate
        // a frame describes the window it holds, so its time is the centre of
        // that window, not the sample it starts on
        let frameCentre = Double(window) / 2 / rate
        let magnitudes = spectrogram(samples, frameCount: frameCount)
        let bins = window / 2 + 1
        let binWidth = rate / Double(window)
        var loudestPeak: Float = 0
        var frameMaximum = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let base = frame * bins
            for index in max(2, Int(38 / binWidth))...min(bins - 2, Int(210 / binWidth)) {
                loudestPeak = max(loudestPeak, magnitudes[base + index])
            }
            for index in 2..<bins {
                frameMaximum[frame] = max(frameMaximum[frame], magnitudes[base + index])
            }
        }
        guard loudestPeak > 0 else { return [] }

        // Peak picking per frame, then tracking: a pitch only becomes a note
        // when a peak of its own keeps coming back frame after frame.
        var tracks: [Track] = []
        var notes: [Span] = []
        for frame in 0..<frameCount {
            let base = frame * bins
            let peaks = framePeaks(magnitudes, base: base, bins: bins, binWidth: binWidth)
            for track in tracks.indices { tracks[track].matched = false }
            for peak in peaks {
                let midi = 69 + 12 * log2(peak.frequency / 440)
                guard midi >= Double(options.lowestPitch) - 0.6,
                      midi <= Double(options.highestPitch) + 0.6 else { continue }
                var best: Int?
                var bestDistance = 1.0
                for index in tracks.indices where !tracks[index].matched {
                    let distance = abs(tracks[index].pitch - midi)
                    guard distance <= bestDistance, frame - tracks[index].lastFrame <= 2 else { continue }
                    bestDistance = distance
                    best = index
                }
                if let index = best {
                    tracks[index].pitch = tracks[index].pitch * 0.7 + midi * 0.3
                    tracks[index].lastFrame = frame
                    tracks[index].matched = true
                    tracks[index].energies.append(peak.magnitude)
                    tracks[index].pitches.append(midi)
                    tracks[index].lowestPitch = min(tracks[index].lowestPitch, midi)
                    tracks[index].highestPitchSeen = max(tracks[index].highestPitchSeen, midi)
                } else {
                    tracks.append(Track(pitch: midi, startFrame: frame, lastFrame: frame,
                                        energies: [peak.magnitude], pitches: [midi], matched: true,
                                        lowestPitch: midi, highestPitchSeen: midi))
                }
            }
            // a track that lost its peak for three frames is over
            for index in tracks.indices where !tracks[index].matched && frame - tracks[index].lastFrame > 2 {
                if let span = span(for: tracks[index], windowBegin: windowBegin,
                                   frameDuration: frameDuration, frameCentre: frameCentre,
                                   loudest: loudestPeak, frameMaximum: frameMaximum,
                                   samples: samples, existing: existing) {
                    notes.append(span)
                }
                tracks[index].finished = true
            }
            tracks.removeAll { $0.finished }
        }
        for track in tracks {
            if let span = span(for: track, windowBegin: windowBegin,
                               frameDuration: frameDuration, frameCentre: frameCentre,
                               loudest: loudestPeak, frameMaximum: frameMaximum,
                               samples: samples, existing: existing) {
                notes.append(span)
            }
        }
        notes.sort { a, b in
            if a.onset != b.onset { return a.onset < b.onset }
            return a.pitch < b.pitch
        }
        return notes
    }

    /// One candidate pitch followed over frames.
    private struct Track {
        var pitch: Double
        var startFrame: Int
        var lastFrame: Int
        var energies: [Float]
        var pitches: [Double]
        var matched: Bool
        var lowestPitch: Double
        var highestPitchSeen: Double
        var finished = false
    }

    /// Turns a tracked peak into a note, or nil when it is too short, too
    /// unsteady, or already in the model's own output.
    private func span(for track: Track, windowBegin: Double, frameDuration: Double,
                      frameCentre: Double, loudest: Float, frameMaximum: [Float],
                      samples: [Float], existing: [Span]) -> Span? {
        let frames = track.lastFrame - track.startFrame + 1
        let length = Double(frames) * frameDuration
        guard length >= max(options.minimumDuration, options.stabilitySeconds) else { return nil }
        // Steady in pitch: the median frame wins and most frames have to
        // agree with it. A partial beaten by the notes above it wanders; a
        // struck fundamental does not.
        let ordered = track.pitches.sorted()
        let median = ordered[ordered.count / 2]
        let agreeing = track.pitches.filter { abs($0 - median) <= 0.5 }.count
        guard Double(agreeing) >= Double(track.pitches.count) * 0.8 else { return nil }
        guard abs(median - median.rounded()) < 0.45 else { return nil }
        let peak = track.energies.max() ?? 0
        guard peak >= loudest * options.relativeToLoudest else { return nil }
        let pitch = Int(median.rounded())
        guard pitch >= options.lowestPitch, pitch <= options.highestPitch else { return nil }
        // the note is there while its peak is near its own maximum: the first
        // and last frames only hold the window sliding in and out
        let half = peak * 0.5
        let release = peak * 0.15
        let first = track.energies.firstIndex { $0 >= half } ?? 0
        let last = track.energies.lastIndex { $0 >= release } ?? track.energies.count - 1
        let onset = windowBegin + Double(track.startFrame + first) * frameDuration + frameCentre
        let offset = windowBegin + Double(track.startFrame + last) * frameDuration + frameCentre
        guard offset - onset >= options.minimumDuration else { return nil }
        // Last gate, and the one noise cannot pass: the waveform has to
        // repeat at the period this pitch claims.
        let loudestFrame = track.energies.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let frameIndex = min(frameMaximum.count - 1, track.startFrame + loudestFrame)
        guard frameMaximum.indices.contains(frameIndex),
              peak >= frameMaximum[frameIndex] * options.relativeToSpectrum else { return nil }
        let frameStart = (track.startFrame + loudestFrame) * options.hopSize
        let period = Int((rate / (440.0 * pow(2.0, Double(pitch - 69) / 12.0))).rounded())
        guard periodicity(samples: samples, start: frameStart, period: period)
            >= options.minimumPeriodicity else { return nil }
        // the model may already have this note, struck in another window or
        // still sounding: then there is nothing to add
        let tolerance = options.duplicateTolerance
        guard !existing.contains(where: { other in
            other.pitch == pitch
                && other.onset < offset + tolerance
                && other.offset > onset - tolerance
        }) else { return nil }
        return Span(pitch: pitch, onset: onset, offset: offset,
                    velocity: velocity(forPeak: peak, loudest: loudest))
    }

    /// Normalised autocorrelation at the note's own period, over one frame.
    /// 1 for a pure tone, 0 for room tone.
    private func periodicity(samples: [Float], start: Int, period: Int) -> Float {
        let window = options.windowSize
        guard period > 0, start >= 0, start + window <= samples.count else { return 0 }
        var energy: Float = 0
        var delayed: Float = 0
        var product: Float = 0
        let count = window - period
        samples.withUnsafeBufferPointer { source in
            for index in 0..<count {
                let value = source[start + index]
                let later = source[start + index + period]
                product += value * later
                energy += value * value
                delayed += later * later
            }
        }
        let denominator = sqrt(energy * delayed)
        return denominator > 1e-12 ? product / denominator : 0
    }

    /// Rough dynamics for MIDI, from the peak of the tracked fundamental.
    private func velocity(forPeak peak: Float, loudest: Float) -> Int {
        guard loudest > 0 else { return 60 }
        let share = min(1, max(0, Double(peak / loudest)))
        return max(24, min(112, Int(24 + pow(share, 0.45) * 80)))
    }

    /// Spectral peaks inside the bass band for one frame, with harmonics of a
    /// lower peak removed: a G1 strike must report G1, not G1 and its octave.
    private func framePeaks(_ magnitudes: [Float], base: Int, bins: Int,
                            binWidth: Double) -> [(frequency: Double, magnitude: Float)] {
        let lowBin = max(2, Int(38 / binWidth))
        let highBin = min(bins - 2, Int(210 / binWidth))
        guard highBin > lowBin + 2 else { return [] }
        var bandMax: Float = 0
        for index in lowBin...highBin { bandMax = max(bandMax, magnitudes[base + index]) }
        guard bandMax > 1e-4 else { return [] }
        var peaks: [(bin: Int, magnitude: Float)] = []
        for index in lowBin...highBin {
            let value = magnitudes[base + index]
            guard value > magnitudes[base + index - 1],
                  value >= magnitudes[base + index + 1],
                  value > bandMax * 0.06 else { continue }
            peaks.append((index, value))
        }
        // lowest first, then drop anything that is a harmonic of a lower peak
        peaks.sort { $0.bin < $1.bin }
        var kept: [(bin: Int, magnitude: Float)] = []
        for peak in peaks {
            let frequency = Double(peak.bin) * binWidth
            let isHarmonic = kept.contains { lower in
                let ratio = frequency / (Double(lower.bin) * binWidth)
                let harmonic = ratio.rounded()
                return harmonic >= 2 && harmonic <= 6 && abs(ratio - harmonic) < 0.04
            }
            if !isHarmonic { kept.append(peak) }
        }
        return kept.map { peak in
            // parabolic interpolation on the log magnitude gives a frequency
            // far more precise than one 5.4 Hz bin
            let left = log(Double(max(1e-9, magnitudes[base + peak.bin - 1])))
            let centre = log(Double(max(1e-9, magnitudes[base + peak.bin])))
            let right = log(Double(max(1e-9, magnitudes[base + peak.bin + 1])))
            let denominator = left - 2 * centre + right
            let shift = abs(denominator) > 1e-9 ? 0.5 * (left - right) / denominator : 0
            let bin = Double(peak.bin) + max(-0.5, min(0.5, shift))
            return (bin * binWidth, peak.magnitude)
        }
    }

    /// Linear magnitude spectrogram, Hann-windowed, [frame][bin].
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
            var count = UInt32(half + 1)
            var source = powers
            vvsqrtf(&magnitudes[index * (half + 1)], &source, &count)
        }
        return magnitudes
    }
}
