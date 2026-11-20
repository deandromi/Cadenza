import Accelerate
import Foundation

/// Log-mel front end for the CoreML backbone, mirroring Transkun's training
/// pipeline exactly:
///
/// - framing: nFrames = ceil(N/hop) + 1, frames of 4096 samples at hop 1024,
///   left pad of windowSize/2 after which samples run, right pad closes to
///   (nFrames-1)*hop + windowSize
/// - scalar gain normalization over the framed view (overlapping samples
///   counted once per frame), matching torch mean/std over the framed tensor
/// - six analysis windows per frame (row 0 = hann, rows 1..5 = learned
///   Gaussian windows), each rfft'd with ortho normalization and power-ed
/// - power [2049] projected through the fixed mel filterbank [2049, 229]
/// - log compression ((m + 1e-5).ln() - ln(1e-5)) / -ln(1e-5)
///
/// Output layout is C-order (frames, nMels, channels) matching the CoreML
/// input (1, frames, 229, 6).
public final class MelFrontEnd {
    public static let windowSize = 4096
    public static let hopSize = 1024
    public static let nMels = 229
    public static let nChannels = 6
    public static let eps: Float = 1e-5
    /// vDSP's packed real forward FFT returns 2x the DFT; ortho normalization
    /// wants 1/N on the power, so powerScale = 1 / (4 * N).
    static let powerScale = 1.0 / Float(4 * windowSize)

    public let windows: [[Float]]      // [6][windowSize]
    public let freq2mels: [Float]      // flat row-major [2049][nMels]

    private let fftSetup: FFTSetup

    /// Whether to divide each window by its own mean and standard deviation.
    /// Transkun's own pipeline does not: it scales int16 PCM by 2^15 and lets
    /// the mel levels stay absolute, which is what the trained confidence is
    /// calibrated against. Kept on: measured on the 30 s Debussy capture the
    /// faithful path scores F1 0,783 versus 0,792 for window normalization,
    /// and window normalization is level-invariant, so a quiet room cannot
    /// sink the features. CADENZA_MEL_ABS=1 switches to the absolute path.
    public static nonisolated(unsafe) var normalizesWindows =
        ProcessInfo.processInfo.environment["CADENZA_MEL_ABS"] != "1"

    public init(tensorsDir: URL) throws {
        let windowsData = try Data(contentsOf: tensorsDir.appendingPathComponent("windows.f32"))
        let filterData = try Data(contentsOf: tensorsDir.appendingPathComponent("freq2mels.f32"))
        let winFloats = windowsData.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer<Float>(start: raw.bindMemory(to: Float.self).baseAddress!, count: raw.count / 4))
        }
        let filterFloats = filterData.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer<Float>(start: raw.bindMemory(to: Float.self).baseAddress!, count: raw.count / 4))
        }
        guard winFloats.count == 6 * MelFrontEnd.windowSize else {
            throw MelFrontEndError.badTensor(name: "windows", count: winFloats.count)
        }
        guard filterFloats.count == 2049 * MelFrontEnd.nMels else {
            throw MelFrontEndError.badTensor(name: "freq2mels", count: filterFloats.count)
        }
        var rows: [[Float]] = []
        for c in 0..<MelFrontEnd.nChannels {
            rows.append(Array(winFloats[c * MelFrontEnd.windowSize..<(c + 1) * MelFrontEnd.windowSize]))
        }
        windows = rows
        freq2mels = filterFloats
        guard let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else {
            throw MelFrontEndError.fftSetupFailed
        }
        fftSetup = setup
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public enum MelFrontEndError: Error {
        case badTensor(name: String, count: Int)
        case fftSetupFailed
    }

    public static func frameCount(sampleCount: Int) -> Int {
        return (sampleCount + MelFrontEnd.hopSize - 1) / MelFrontEnd.hopSize + 1
    }

    /// Computes mel features for one raw mono window of samples.
    public func compute(_ samples: [Float]) -> [Float] {
        let nFrames = Self.frameCount(sampleCount: samples.count)
        let lPad = MelFrontEnd.windowSize / 2
        let rPad = max(0, (nFrames - 1) * MelFrontEnd.hopSize + MelFrontEnd.windowSize / 2 - samples.count)
        var padded = [Float](repeating: 0, count: lPad + samples.count + rPad)
        padded.replaceSubrange(lPad..<(lPad + samples.count), with: samples)

        guard MelFrontEnd.normalizesWindows else {
            return self.spectrogram(padded, nFrames: nFrames)
        }

        // scalar gain normalization over the framed view (overlapping samples
        // counted once per frame), matching torch mean/std over the framed tensor
        var mean: Float = 0
        let total = Float(nFrames * MelFrontEnd.windowSize)
        for f in 0..<nFrames {
            let s = f * MelFrontEnd.hopSize
            for w in 0..<MelFrontEnd.windowSize { mean += padded[s + w] }
        }
        mean /= total
        var variance: Float = 0
        for f in 0..<nFrames {
            let s = f * MelFrontEnd.hopSize
            for w in 0..<MelFrontEnd.windowSize { let d = padded[s + w] - mean; variance += d * d }
        }
        variance /= total
        let invStd = 1.0 / (sqrt(variance) + 1e-8)
        for i in 0..<padded.count { padded[i] = (padded[i] - mean) * invStd }
        return self.spectrogram(padded, nFrames: nFrames)
    }

    /// The framed, windowed, mel-projected log features of a padded signal.
    private func spectrogram(_ padded: [Float], nFrames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nFrames * MelFrontEnd.nMels * MelFrontEnd.nChannels)
        var frame = [Float](repeating: 0, count: MelFrontEnd.windowSize)
        var re = [Float](repeating: 0, count: MelFrontEnd.windowSize / 2)
        var im = [Float](repeating: 0, count: MelFrontEnd.windowSize / 2)
        var powers = [Float](repeating: 0, count: MelFrontEnd.nChannels * 2049)
        var melBlock = [Float](repeating: 0, count: MelFrontEnd.nChannels * MelFrontEnd.nMels)
        let logEps = log(MelFrontEnd.eps)
        let negLogEps = -logEps
        var withEps = [Float](repeating: 0, count: melBlock.count)
        var logMel = [Float](repeating: 0, count: melBlock.count)
        let eps = MelFrontEnd.eps
        var epsVar = eps
        var elementCount = Int32(melBlock.count)
        var log2n: vDSP_Length = 12

        for f in 0..<nFrames {
            let frameStart = f * MelFrontEnd.hopSize
            for c in 0..<MelFrontEnd.nChannels {
                let win = windows[c]
                for w in 0..<MelFrontEnd.windowSize {
                    frame[w] = padded[frameStart + w] * win[w]
                }
                // pack evens/odds and run the packed real FFT
                for k in 0..<2048 {
                    re[k] = frame[2 * k]
                    im[k] = frame[2 * k + 1]
                }
                re.withUnsafeMutableBufferPointer { reBuf in
                    im.withUnsafeMutableBufferPointer { imBuf in
                        var split = DSPSplitComplex(realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        let r = reBuf.baseAddress!, i = imBuf.baseAddress!
                        let base = c * 2049
                        // realp[0] is DC, imagp[0] is Nyquist for the packed layout
                        powers[base] = r[0] * r[0] * MelFrontEnd.powerScale
                        powers[base + 2048] = i[0] * i[0] * MelFrontEnd.powerScale
                        for k in 1..<2048 {
                            powers[base + k] = (r[k] * r[k] + i[k] * i[k]) * MelFrontEnd.powerScale
                        }
                    }
                }
            }
            // mel projection: powers [6][2049] @ freq2mels [2049][229] -> [6][229]
            vDSP_mmul(powers, 1, freq2mels, 1, &melBlock, 1,
                      vDSP_Length(MelFrontEnd.nChannels), vDSP_Length(MelFrontEnd.nMels), vDSP_Length(2049))
            // log compression ((m + eps).log() - log(eps)) / -log(eps)
            vDSP_vsadd(melBlock, 1, &epsVar, &withEps, 1, vDSP_Length(withEps.count))
            vvlogf(&logMel, &withEps, &elementCount)
            for c in 0..<MelFrontEnd.nChannels {
                for m in 0..<MelFrontEnd.nMels {
                    out[(f * MelFrontEnd.nMels + m) * MelFrontEnd.nChannels + c] =
                        (logMel[c * MelFrontEnd.nMels + m] - logEps) / negLogEps
                }
            }
        }
        return out
    }
}

public enum MelFrontEndError: Error {
    case badTensor(name: String, count: Int)
    case fftSetupFailed
}
