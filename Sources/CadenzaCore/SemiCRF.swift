/// A decoded interval in frame coordinates (inclusive start/end frames).
public struct FrameInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

/// Port of transkun's NeuralSemiCRFInterval.viterbiBackward decode: per-symbol
/// suffix DP over interval scores with a per-frame skip (noise) score.
///
/// Score layout: `score[(end * frameCount + begin) * symbolCount + symbol]`
/// (C-order [end][begin][symbol]), skip layout: `skip[frame * symbolCount + symbol]`.
public enum SemiCRFDecoder {
    public static func decode(
        score: [Float],
        skip: [Float],
        frameCount T: Int,
        symbolCount P: Int,
        forcedStartPos: [Int]? = nil
    ) -> [[FrameInterval]] {
        score.withUnsafeBufferPointer { scoreBuffer in
            skip.withUnsafeBufferPointer { skipBuffer in
                decode(score: scoreBuffer, skip: skipBuffer, frameCount: T,
                       symbolCount: P, forcedStartPos: forcedStartPos)
            }
        }
    }

    /// The buffer form: the backbone's score tensor is 172 MB for a 16 s
    /// window, so the app decodes straight from CoreML's output memory
    /// instead of copying it first.
    public static func decode(
        score: UnsafeBufferPointer<Float>,
        skip: UnsafeBufferPointer<Float>,
        frameCount T: Int,
        symbolCount P: Int,
        forcedStartPos: [Int]? = nil
    ) -> [[FrameInterval]] {
        var result: [[FrameInterval]] = Array(repeating: [], count: P)
        for p in 0..<P {
            result[p] = decodeSymbol(score: score, skip: skip, T: T, P: P, p: p,
                                     start: forcedStartPos?[p] ?? 0)
        }
        return result
    }

    /// The per-symbol suffix DP. Symbols are independent, so callers that
    /// have spare cores may run this concurrently for each symbol; the
    /// result depends only on the inputs, never on scheduling.
    public static func decodeSymbol(
        score: [Float], skip: [Float], T: Int, P: Int, p: Int, start: Int
    ) -> [FrameInterval] {
        score.withUnsafeBufferPointer { scoreBuffer in
            skip.withUnsafeBufferPointer { skipBuffer in
                decodeSymbol(score: scoreBuffer, skip: skipBuffer, T: T, P: P, p: p, start: start)
            }
        }
    }

    public static func decodeSymbol(
        score: UnsafeBufferPointer<Float>, skip: UnsafeBufferPointer<Float>,
        T: Int, P: Int, p: Int, start: Int
    ) -> [FrameInterval] {
        var q = [Float](repeating: 0, count: T)
        var ptr = [Int](repeating: -1, count: T)

        let diagLast = score[((T - 1) * T + (T - 1)) * P + p]
        q[T - 1] = max(0, diagLast)

        for i in 1..<T {
            let t = T - 1 - i
            var best = q[t + 1] + skip[t * P + p]   // skip one frame
            var bestEnd = -1
            for b in (t + 1)..<T {
                let v = q[b] + score[(b * T + t) * P + p]
                if v > best { best = v; bestEnd = b }
            }
            let diag = score[(t * T + t) * P + p]
            q[t] = best + (diag > 0 ? diag : 0)
            ptr[t] = bestEnd
        }

        var intervals: [FrameInterval] = []
        var j = start
        while j < T - 1 {
            if score[(j * T + j) * P + p] > 0 {
                intervals.append(FrameInterval(start: j, end: j))
            }
            let b = ptr[j]
            if b < 0 {
                j += 1
            } else {
                intervals.append(FrameInterval(start: j, end: b))
                j = b
            }
        }
        if score[((T - 1) * T + (T - 1)) * P + p] > 0 {
            intervals.append(FrameInterval(start: T - 1, end: T - 1))
        }
        return intervals
    }
}
