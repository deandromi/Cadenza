import Accelerate
import Foundation

/// The first note of a strike, read from the signal instead of the model.
///
/// The neural decode is the authority on what was played, and it cannot be
/// faster than one window: about 0.8 s of backbone over sixteen seconds of
/// audio. That is the floor of the pipeline, and it is far above what a
/// player feels as immediate. So the strike is taken twice: this detector
/// reads the attack from the newest few milliseconds of audio and reports a
/// first guess within a couple of hops, and the decode follows later with the
/// note the sheet and the MIDI file are actually made of.
///
/// What it reports is a *strike*, not a note: pitch, force and when the key
/// moved. Length is not its business — it only sees the attack — so callers
/// must treat the guess as provisional and let the decode settle it.
///
/// Two frames run side by side, and the split is the whole trick. A short
/// frame (46 ms) fills quickly, so the attack is heard sooner; a long one
/// (93 ms) resolves the partials well enough to name a chord. Reading the
/// attack on the short frame and the voices on the long one costs nothing in
/// time — both are in memory at the same instant — and keeps both the speed
/// of the one and the accuracy of the other.
public final class InstantOnsetDetector {
    /// One attacked pitch.
    public struct Strike: Equatable, Sendable {
        public var pitch: Int
        public var velocity: Int
        /// Content seconds of the attack, the centre of the frame it fell in.
        public var atSeconds: Double
        /// How far the pitch's harmonic sum stood above the runner-up, 0…1.
        /// A clean single note is well above a chord's third voice.
        public var confidence: Double
        public init(pitch: Int, velocity: Int, atSeconds: Double, confidence: Double) {
            self.pitch = pitch
            self.velocity = velocity
            self.atSeconds = atSeconds
            self.confidence = confidence
        }
    }

    public struct Options: Sendable {
        /// 93 ms at 44.1 kHz, and the transform is twice that. The frame has
        /// to be long enough to resolve a chord's partials; a shorter one
        /// names the attack sooner but reads the notes from a window the
        /// attack has not reached the middle of yet, and loses more to wrong
        /// pitches than it gains in milliseconds.
        public var windowSize = 4096
        /// Where the analysis window peaks, as a fraction of its length. A
        /// symmetric window peaks in the middle, so an attack that has just
        /// arrived — at the trailing edge — weighs almost nothing and is
        /// heard only once it has moved toward the middle. Leaning the peak
        /// toward the newest audio hears it sooner from the same frame.
        public var windowPeak: Double = 0.65
        /// 11.6 ms: one hop is the detector's whole latency budget.
        public var hopSize = 512
        /// The lowest and highest pitch a strike is taken for.
        public var lowestPitch = 24
        public var highestPitch = 103
        /// Harmonics summed per candidate.
        public var harmonics = 12
        /// A pitch needs this share of the strongest candidate to be reported
        /// as another voice of the same attack.
        public var voiceShare: Float = 0.30
        /// An attack this soon after the previous one is the same attack still
        /// ringing, not a new one.
        public var refractorySeconds = 0.055
        /// A strike quieter than this is room tone.
        public var floorDecibels: Float = -48
        /// How much of the attack's new magnitude the winning note has to
        /// explain before a guess is worth making. Spread-out energy is a
        /// chord too dense to name from one frame, and guessing at it costs
        /// more than waiting for the decode.
        public var minimumDominance: Float = 0.03
        /// Harmonics a voice needs in the rise before it is believed.
        public var minimumHarmonics = 3
        /// Frames that have to agree with an attack before its notes leave
        /// the app. Two hops is 23 ms, and it removes most coincidences.
        public var confirmationFrames = 2
        /// The flux has to beat the median of the last half second by this
        /// factor to count as an attack rather than a swell.
        public var thresholdFactor: Float = 1.3
        /// The least new magnitude, as a share of the frame a breath back,
        /// that can still be called an attack: below it the spectrum is just
        /// settling.
        public var minimumFlux: Float = 0.16
        /// How much louder the frame has to be than the one 46 ms back. A
        /// struck string raises the energy; a ringing one only ever loses it.
        /// The margin is small on purpose: a new note over a note still
        /// sounding raises the total by less than it would in silence.
        public var powerRise: Float = 1.03
        public init() {}
    }

    /// Whether every candidate attack is logged: CADENZA_INSTANT_DEBUG=1.
    static let verbose = ProcessInfo.processInfo.environment["CADENZA_INSTANT_DEBUG"] != nil

    /// One transform of one size, with its window and its packed FFT.
    private final class FrameSpectrum {
        let size: Int
        let bins: Int
        let binWidth: Double
        private let setup: FFTSetup
        private let log2n: vDSP_Length
        private let hann: [Float]

        init(size: Int, rate: Double, peak: Double) {
            self.size = size
            // the transform is twice the window: zero padding buys half the
            // bin width, which is what separates neighbouring semitones
            let transform = size * 2
            bins = transform / 2 + 1
            binWidth = rate / Double(transform)
            let log2 = vDSP_Length(round(log2(Double(transform))))
            log2n = log2
            setup = vDSP_create_fftsetup(log2, FFTRadix(kFFTRadix2))!
            // a raised cosine peaking where `peak` asks: 0.5 of the window is
            // the plain Hann, higher leans it toward the newest audio
            var window = [Float](repeating: 0, count: size)
            let peakIndex = min(max(Int(Double(size) * peak), 1), size - 2)
            for index in 0..<size {
                let phase: Double
                if index <= peakIndex {
                    phase = Double(index) / Double(peakIndex)
                } else {
                    phase = Double(size - 1 - index) / Double(size - 1 - peakIndex)
                }
                window[index] = Float(0.5 - 0.5 * cos(Double.pi * phase))
            }
            self.hann = window
        }

        deinit {
            vDSP_destroy_fftsetup(setup)
        }

        func magnitudes(_ frame: [Float]) -> [Float] {
            guard frame.count == size else { return [] }
            let transform = size * 2
            var windowed = [Float](repeating: 0, count: transform)
            vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(size))
            var real = [Float](repeating: 0, count: transform / 2)
            var imaginary = [Float](repeating: 0, count: transform / 2)
            var out = [Float](repeating: 0, count: bins)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                                imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: transform / 2) { pointer in
                            vDSP_ctoz(pointer, 2, &split, 1, vDSP_Length(transform / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(transform / 2))
                }
            }
            // vDSP packs Nyquist into the real part of bin 0 and leaves the
            // last bin short by one; both are outside any pitch this looks for
            out[bins - 1] = abs(out[0])
            return out
        }
    }

    /// One analysed frame, kept so a later frame can be read against it.
    private struct Analysed {
        let magnitudes: [Float]
        let power: Float
    }

    private let rate: Double
    private let options: Options
    /// the frame both questions are asked of: does something start here, and
    /// what is it
    private let analyser: FrameSpectrum

    /// the samples after the last processed hop, still to be framed
    private var pending: [Float] = []
    /// how many samples have been handed to the detector in total
    private var fedSamples = 0
    /// the last few short frames. An attack is read against the frame four
    /// hops back (46 ms), not the one before it: a tone's partials drift in
    /// and out of the window's scalloping from hop to hop, and that ripple
    /// would otherwise fire on a note that is merely still ringing.
    private var frames: [Analysed] = []

    /// how far back the flux is read
    private let baselineHops: Int
    /// the recent flux history, for the adaptive median
    private var fluxHistory: [Float] = []
    private var fluxHistoryCap: Int
    /// content seconds of the last attack, for the refractory
    private var lastStrike: Double = -.infinity
    /// an attack whose voices are still being checked against the frames that
    /// follow it
    private var pendingAttack: Pending?

    /// An attack is named twice: once from the frame it landed in, then again
    /// from the frames after it, read against the same baseline. A pitch that
    /// only surfaced because two spectra happened to differ does not survive
    /// the second reading; a struck string does. The check costs a couple of
    /// hops, and buys a guess that can be trusted to leave the app.
    private struct Pending {
        let baseline: [Float]
        let centre: Double
        let velocity: Int
        var pitches: Set<Int>
        var checksLeft: Int
    }

    public init(rate: Double = 44100, options: Options = Options()) {
        self.rate = rate
        self.options = options
        analyser = FrameSpectrum(size: options.windowSize, rate: rate, peak: options.windowPeak)
        let window = options.windowSize
        pending.reserveCapacity(window + options.hopSize)
        fluxHistoryCap = max(8, Int(0.5 * rate / Double(options.hopSize)))
        // 46 ms of baseline: longer than scalloping, shorter than a note
        baselineHops = max(1, Int(0.046 * rate / Double(options.hopSize)))
        // the detector starts against silence, so a strike in its very first
        // frame is an attack and not a frame with nothing to compare to
        frames = [Analysed(magnitudes: [Float](repeating: 0, count: analyser.bins), power: 0)]
    }

    /// Feeds mono samples and returns every attack found in them, oldest
    /// first. Frames are cut on the detector's own grid, so a caller may push
    /// buffers of any size, including one sample at a time.
    public func push(_ samples: [Float]) -> [Strike] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)
        fedSamples += samples.count
        let window = options.windowSize
        let hop = options.hopSize
        var strikes: [Strike] = []
        while pending.count >= window {
            // one frame: the window's own start, which is where its centre is
            let frameStart = fedSamples - pending.count
            let frame = Array(pending[0..<window])
            let centre = Double(frameStart) / rate + Double(window) * options.windowPeak / rate
            strikes.append(contentsOf: analyse(frame: frame, centre: centre))
            pending.removeFirst(hop)
        }
        // a caller that stops feeding for a while must not keep history alive
        if pending.count > window * 2 {
            pending.removeFirst(pending.count - window * 2)
        }
        return strikes
    }

    public func push(_ samples: UnsafeBufferPointer<Float>) -> [Strike] {
        push(Array(samples))
    }

    // MARK: one frame

    private func analyse(frame: [Float], centre: Double) -> [Strike] {
        let magnitudes = analyser.magnitudes(frame)
        guard !magnitudes.isEmpty else { return [] }
        var power: Float = 0
        for bin in 2..<analyser.bins { power += magnitudes[bin] * magnitudes[bin] }

        // Read against the frame a breath back, then remember this one.
        let baseline = frames.first ?? Analysed(magnitudes: magnitudes, power: power)
        let voiceBaseline = baseline.magnitudes
        defer {
            frames.append(Analysed(magnitudes: magnitudes, power: power))
            if frames.count > baselineHops + 1 { frames.removeFirst() }
        }

        // Novelty: how much magnitude appeared that was not there a breath
        // ago, read against the baseline's own size. Linear magnitudes, not
        // logs, because a log spectrum is never quiet — the floor is where it
        // stops — and that floor alone can outweigh a real attack. Dividing by
        // the baseline makes it a ratio, so a loud passage and a quiet one are
        // read on the same scale.
        var flux: Float = 0
        var baselineEnergy: Float = 0
        let lowestBin = max(1, Int(55 / analyser.binWidth))
        let highestBin = min(analyser.bins - 2, Int(6000 / analyser.binWidth))
        for bin in lowestBin...highestBin {
            baselineEnergy += baseline.magnitudes[bin]
            let delta = magnitudes[bin] - baseline.magnitudes[bin]
            if delta > 0 { flux += delta }
        }
        // a first strike out of silence divides by nothing: the ratio is
        // capped, because an uncapped one would sit in the median for half a
        // second and deafen the detector to everything after it
        flux = min(flux / max(baselineEnergy, 1e-6), 50)
        guard flux > 0 else { return [] }
        let threshold = max(options.minimumFlux, fluxThreshold())
        fluxHistory.append(flux)
        if fluxHistory.count > fluxHistoryCap { fluxHistory.removeFirst() }

        // A swell spreads its energy, an attack multiplies it: the frame has
        // to be markedly louder than the one a breath back. A tone still
        // ringing under the pedal only ever gets quieter.
        let powerRatio = power / max(baseline.power, 1e-12)
        let powerRise = baseline.power < 1e-9 ? Float.infinity : powerRatio

        if Self.verbose, flux > 0.05 {
            print(String(format: "instant %.3f s: flux %.3f threshold %.3f power rise %.2f",
                         centre, flux, threshold, powerRise))
        }

        // an attack being checked: this frame either agrees with it or not
        if var attack = pendingAttack {
            let check = rise(against: attack.baseline, current: magnitudes)
            let seen = Set(pitches(in: check).map(\.pitch))
            attack.pitches.formIntersection(seen)
            attack.checksLeft -= 1
            if attack.checksLeft > 0 {
                pendingAttack = attack
                return []
            }
            pendingAttack = nil
            guard !attack.pitches.isEmpty else { return [] }
            if Self.verbose {
                print(String(format: "instant %.3f s: strike confirmed, voices %@", attack.centre,
                             attack.pitches.sorted().map(String.init).joined(separator: " ")))
            }
            let confirmed = attack.pitches.sorted()
            return confirmed.map { pitch in
                Strike(pitch: pitch, velocity: attack.velocity, atSeconds: attack.centre, confidence: 1)
            }
        }

        // an attack, not a swell; quiet frames never strike
        guard flux > threshold, powerRise > options.powerRise else { return [] }
        guard centre - lastStrike >= options.refractorySeconds else { return [] }
        var peak: Float = 0
        for bin in 2..<analyser.bins { peak = max(peak, magnitudes[bin]) }
        let decibels = 20 * log10f(max(peak, 1e-7))
        guard decibels > options.floorDecibels else { return [] }

        // the voices are read from what *appeared*, not from everything that
        // is sounding: a note already ringing adds nothing to the rise, so it
        // cannot be reported as newly struck
        let riseSpectrum = rise(against: voiceBaseline, current: magnitudes)
        let found = pitches(in: riseSpectrum)
        guard !found.isEmpty else { return [] }
        lastStrike = centre
        pendingAttack = Pending(baseline: voiceBaseline,
                                centre: centre,
                                velocity: velocity(of: peak),
                                pitches: Set(found.map(\.pitch)),
                                checksLeft: max(1, options.confirmationFrames))
        // nothing leaves the detector unconfirmed
        return []
    }

    /// The magnitudes that appeared since `baseline`, in this frame.
    private func rise(against baseline: [Float], current: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: analyser.bins)
        let lowestBin = max(1, Int(55 / analyser.binWidth))
        let highestBin = min(analyser.bins - 2, Int(6000 / analyser.binWidth))
        guard lowestBin < highestBin else { return out }
        for bin in lowestBin...highestBin {
            let delta = current[bin] - baseline[bin]
            if delta > 0 { out[bin] = delta }
        }
        return out
    }

    /// The threshold a flux has to beat: the median of the recent past, so a
    /// loud passage does not deafen the detector and a quiet one does not
    /// flood it with swell.
    private func fluxThreshold() -> Float {
        guard !fluxHistory.isEmpty else { return 0.6 }
        let sorted = fluxHistory.sorted()
        let median = sorted[sorted.count / 2]
        return median * options.thresholdFactor
    }

    private func velocity(of peak: Float) -> Int {
        // -48 dBFS is a whisper, -6 dBFS a fortissimo: the curve a player
        // would draw from their own quietest to their loudest
        let decibels = 20 * log10f(max(peak, 1e-7))
        let share = min(1, max(0, (decibels - options.floorDecibels) / (61 - options.floorDecibels)))
        return min(120, max(24, Int(24 + share * 96)))
    }

    /// The voices of one attack, read one at a time: the strongest pitch is
    /// taken, its partials are damped in a working copy of the spectrum, and
    /// the next voice is read from what is left. Reading them together is
    /// what lets one note's partials vote for another note's fundamental, and
    /// that vote always lands an octave or a twelfth away.
    ///
    /// A pitch scores on its own fundamental above all: a harmonic counts for
    /// 1/h² of it, and a candidate whose root is missing is cut down to a
    /// fraction, so a borrowed series cannot pass for a struck string.
    private func pitches(in magnitudes: [Float]) -> [(pitch: Int, confidence: Double)] {
        let opening = scores(in: magnitudes)
        var riseTotal: Float = 0
        for value in magnitudes { riseTotal += value }
        if Self.verbose {
            let top = opening.prefix(6).map { "\($0.pitch):\(String(format: "%.0f", $0.score))" }
            print("instant candidates: \(top.joined(separator: " ")) rise \(String(format: "%.0f", riseTotal))")
        }
        guard let best = opening.first, best.score > 0 else { return [] }
        // one frame cannot name a wash of energy; a struck string puts most of
        // its attack into a handful of partials of one note
        guard best.score >= options.minimumDominance * riseTotal else { return [] }
        guard harmonics(in: magnitudes, pitch: best.pitch) >= options.minimumHarmonics else { return [] }
        var chosen: [(pitch: Int, confidence: Double)] = [(best.pitch, 1)]
        var work = magnitudes
        damp(&work, pitch: best.pitch)
        while chosen.count < 4 {
            let round = scores(in: work)
            var peaks: [Int: Float] = [:]
            for candidate in round { peaks[candidate.pitch] = candidate.score }
            guard let next = round.first(where: { candidate in
                let share = candidate.score / best.score
                guard share >= options.voiceShare else { return false }
                guard harmonics(in: work, pitch: candidate.pitch) >= options.minimumHarmonics else { return false }
                let left = peaks[candidate.pitch - 1] ?? 0
                let right = peaks[candidate.pitch + 1] ?? 0
                guard candidate.score >= left, candidate.score >= right else { return false }
                return !chosen.contains { existing in
                    let semitones = abs(existing.pitch - candidate.pitch)
                    return semitones <= 1 || semitones == 12 || semitones == 19 || semitones == 24
                }
            }) else { break }
            chosen.append((next.pitch, Double(min(1, next.score / best.score))))
            damp(&work, pitch: next.pitch)
        }
        return chosen
    }

    /// Every pitch's harmonic sum over one spectrum, strongest first.
    private func scores(in spectrum: [Float]) -> [(pitch: Int, score: Float)] {
        let lowestBin = max(2, Int(55 / analyser.binWidth))
        let highestBin = min(analyser.bins - 2, Int(2200 / analyser.binWidth))
        var out: [(pitch: Int, score: Float)] = []
        out.reserveCapacity(options.highestPitch - options.lowestPitch + 1)
        for pitchNumber in options.lowestPitch...options.highestPitch {
            let f0 = 440 * pow(2, (Double(pitchNumber) - 69) / 12)
            let rootBin = Int((f0 / analyser.binWidth).rounded())
            guard rootBin >= 2, rootBin < highestBin else { continue }
            let root = max(spectrum[rootBin - 1], spectrum[rootBin], spectrum[rootBin + 1])
            guard root > 0 else { continue }
            var score = root
            var strongest = root
            for harmonic in 2...options.harmonics {
                let f = f0 * Double(harmonic)
                guard f < 6000 else { break }
                let bin = Int((f / analyser.binWidth).rounded())
                guard bin >= lowestBin, bin < analyser.bins - 1 else { break }
                let partial = max(spectrum[bin - 1], spectrum[bin], spectrum[bin + 1])
                score += partial / Float(harmonic * harmonic)
                strongest = max(strongest, partial)
            }
            // a candidate without its own root is a harmonic of some other
            // note, not a note being struck
            if root < strongest * 0.25 {
                score *= root / max(strongest * 0.25, 1e-9)
            }
            out.append((pitchNumber, score))
        }
        return out.sorted { $0.score > $1.score }
    }

    /// How many of a pitch's partials are actually in the spectrum: a real
    /// string has a ladder of them, a coincidence has one or two.
    private func harmonics(in spectrum: [Float], pitch pitchNumber: Int) -> Int {
        let f0 = 440 * pow(2, (Double(pitchNumber) - 69) / 12)
        let rootBin = Int((f0 / analyser.binWidth).rounded())
        guard rootBin >= 2, rootBin < analyser.bins - 1 else { return 0 }
        let root = max(spectrum[rootBin - 1], spectrum[rootBin], spectrum[rootBin + 1])
        guard root > 0 else { return 0 }
        var count = 1
        for harmonic in 2...options.harmonics {
            let f = f0 * Double(harmonic)
            guard f < 6000 else { break }
            let bin = Int((f / analyser.binWidth).rounded())
            guard bin >= 1, bin < analyser.bins - 1 else { break }
            if max(spectrum[bin - 1], spectrum[bin], spectrum[bin + 1]) >= root * 0.15 { count += 1 }
        }
        return count
    }

    /// Takes a voice's partials out of a working spectrum, so the next voice
    /// cannot be read from energy that voice already explained.
    private func damp(_ spectrum: inout [Float], pitch pitchNumber: Int) {
        let f0 = 440 * pow(2, (Double(pitchNumber) - 69) / 12)
        for harmonic in 1...options.harmonics {
            let f = f0 * Double(harmonic)
            guard f < 6000 else { break }
            let centre = Int((f / analyser.binWidth).rounded())
            for bin in max(0, centre - 2)...min(analyser.bins - 1, centre + 2) {
                spectrum[bin] *= 0.12
            }
        }
    }
}
