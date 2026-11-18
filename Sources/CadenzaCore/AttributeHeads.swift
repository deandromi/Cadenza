import Accelerate
import Foundation

/// The two attribute heads that run on decoded intervals: a 128-way velocity
/// classifier and a 4-output onset/offset refiner. Both are plain two-layer
/// MLPs (Linear -> GELU -> Linear) whose weights were exported to
/// Models/tensors as raw float32 matrices, row-major [out][in].
public struct AttributeHeads {
    public let velocity: LinearGELULinear
    public let refinedOF: LinearGELULinear

    public init(tensorsDir: URL) throws {
        func load(_ name: String, rows: Int, cols: Int) throws -> [Float] {
            let data = try Data(contentsOf: tensorsDir.appendingPathComponent("\(name).f32"))
            let expected = rows * cols * MemoryLayout<Float>.size
            guard data.count == expected else {
                throw AttributeHeadsError.badTensor(name: name, expected: expected, actual: data.count)
            }
            return data.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer<Float>(start: raw.bindMemory(to: Float.self).baseAddress!, count: raw.count / 4))
            }
        }
        velocity = try LinearGELULinear(
            w0: load("velocity_w0", rows: 512, cols: 768), b0: load("velocity_b0", rows: 512, cols: 1),
            w1: load("velocity_w1", rows: 128, cols: 512), b1: load("velocity_b1", rows: 128, cols: 1))
        refinedOF = try LinearGELULinear(
            w0: load("refinedOF_w0", rows: 512, cols: 768), b0: load("refinedOF_b0", rows: 512, cols: 1),
            w1: load("refinedOF_w1", rows: 4, cols: 512), b1: load("refinedOF_b1", rows: 4, cols: 1))
    }

    public enum AttributeHeadsError: Error {
        case badTensor(name: String, expected: Int, actual: Int)
    }

    /// input: 768 = [ctxA(256); ctxB(256); ctxA*ctxB(256)]
    public func velocityLogits(_ input: [Float]) -> [Float] {
        velocity.forward(input)
    }

    public func refinedOF(_ input: [Float]) -> [Float] {
        refinedOF.forward(input)
    }

    /// mean of torch's ContinuousBernoulli(logits:) distribution.
    /// Outside the unstable region: p/(2p-1) + 1/(log1p(-p) - log(p));
    /// inside (p in (0.499, 0.501]): Taylor 0.5 + (1/3 + 16/45 x^2) x, x = p-0.5.
    public static func continuousBernoulliMean(logit: Float) -> Float {
        let p = 1.0 / (1.0 + exp(-logit))
        if p <= 0.499 || p > 0.501 {
            return p / (2 * p - 1) + 1.0 / (log1p(-p) - log(p))
        }
        let x = p - 0.5
        return 0.5 + (1.0 / 3.0 + 16.0 / 45.0 * x * x) * x
    }
}

public struct LinearGELULinear {
    public let w0: [Float]   // [hidden][in]
    public let b0: [Float]   // [hidden]
    public let w1: [Float]   // [out][hidden]
    public let b1: [Float]   // [out]
    public let hidden: Int
    public let input: Int
    public let output: Int

    public init(w0: [Float], b0: [Float], w1: [Float], b1: [Float]) {
        self.hidden = b0.count
        self.input = b0.isEmpty ? 0 : w0.count / max(b0.count, 1)
        self.output = b1.count
        self.w0 = w0; self.b0 = b0; self.w1 = w1; self.b1 = b1
    }

    public func forward(_ x: [Float]) -> [Float] {
        var h = [Float](repeating: 0, count: hidden)
        // h = w0 @ x + b0   (w0 is row-major [hidden][input])
        w0.withUnsafeBufferPointer { wPtr in
            x.withUnsafeBufferPointer { xPtr in
                h.withUnsafeMutableBufferPointer { hPtr in
                    vDSP_mmul(wPtr.baseAddress!, 1, xPtr.baseAddress!, 1, hPtr.baseAddress!, 1,
                              vDSP_Length(hidden), 1, vDSP_Length(input))
                }
            }
        }
        vDSP_vadd(h, 1, b0, 1, &h, 1, vDSP_Length(hidden))
        // GELU (erf form): 0.5 * x * (1 + erf(x / sqrt(2)))
        let invSqrt2 = Float(1.0 / sqrt(2.0))
        var gelu = [Float](repeating: 0, count: hidden)
        for i in 0..<hidden {
            gelu[i] = 0.5 * h[i] * (1 + erff(h[i] * invSqrt2))
        }
        // out = w1 @ gelu + b1
        var y = [Float](repeating: 0, count: output)
        w1.withUnsafeBufferPointer { wPtr in
            gelu.withUnsafeBufferPointer { gPtr in
                y.withUnsafeMutableBufferPointer { yPtr in
                    vDSP_mmul(wPtr.baseAddress!, 1, gPtr.baseAddress!, 1, yPtr.baseAddress!, 1,
                              vDSP_Length(output), 1, vDSP_Length(hidden))
                }
            }
        }
        vDSP_vadd(y, 1, b1, 1, &y, 1, vDSP_Length(output))
        return y
    }
}
