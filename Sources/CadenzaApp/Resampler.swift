import Foundation

/// Offline sample-rate conversion with a Hann-windowed sinc kernel.
///
/// AVAudioConverter returns paramError (-50) for every layout and direction
/// on this system, so the engine converts device-rate windows itself. The
/// kernel is symmetric, so no phase shift is introduced, and the front end
/// normalizes gain per window anyway, which makes the slight ripple of the
/// windowed kernel irrelevant for the model.
enum Resampler {
    /// Half-width of the kernel in input samples.
    private static let halfWidth = 16

    static func convert(_ input: [Float], from: Double, to: Double) -> [Float]? {
        guard input.count > 1, from > 0, to > 0 else { return nil }
        if abs(from - to) < 1 { return input }
        guard from / to < 32, to / from < 32 else { return nil }

        // kernel cutoff: the smaller of the two Nyquist frequencies,
        // expressed in input-sample units
        let r = min(1.0, to / from)
        let positionStep = from / to
        let outputCount = Int((Double(input.count) * to / from).rounded())
        var output = [Float](repeating: 0, count: outputCount)
        let width = Double(halfWidth)

        for i in 0..<outputCount {
            let position = Double(i) * positionStep
            let base = Int(position.rounded(.down))
            let start = base - halfWidth
            var accumulator = 0.0
            for k in start..<(start + 2 * halfWidth + 1) {
                if k < 0 { continue }
                if k >= input.count { break }
                let x = Double(k) - position
                let window = 0.5 * (1 + cos(.pi * x / width))
                let argument = r * x
                let sinc: Double
                if abs(argument) < 1e-8 {
                    sinc = 1
                } else {
                    sinc = sin(.pi * argument) / (.pi * argument)
                }
                accumulator += Double(input[k]) * window * sinc
            }
            output[i] = Float(accumulator * r)
        }
        return output
    }
}
