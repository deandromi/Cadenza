import Foundation
import CadenzaCore

/// Window constants shared by every tier, mirroring transkun's transcribe()
/// and readable from any isolation domain (the tap, the inference queue, main).
enum WindowGeometry {
    static let sampleRate: Double = 44100.0
    static let hopSize = 1024
    static let symbols: [Int] = [-64, -67] + Array(21...108)

    /// Notes shorter than this are dropped at merge time: on room-tone
    /// recordings the reference model fires phantoms of 47 to 52 ms in the
    /// low register, and they poison chords and MIDI output. Real staccato
    /// notes ring longer.
    static let minimumNoteDuration = 0.055

    /// The ceiling for the adaptive streaming step. A 16 s window costs about
    /// 1.2 s of decode on the GPU, so a fixed 0.45 s step asks for four times
    /// the throughput the machine has and the pipeline falls minutes behind
    /// the player. The engine stretches the step until two decoders keep up,
    /// and never beyond this.
    static let stepCeiling = 4.0
}

/// The window geometry of one transcription tier. The CoreML backbone is
/// exported per tier at a fixed input length (the position embeddings are
/// baked into the graph), so each tier carries its own geometry:
///
/// - standard: the reference 16 s window, half-stepped, highest context.
/// - fast: a 4 s window on the short-exported backbone; a decode costs
///   about a quarter of the standard one (measured 0.15 s versus 0.63 s
///   for the model call), which is what buys sub-second latency.
struct WindowPlan: Sendable, Equatable {
    let segmentSeconds: Double
    let padSeconds: Double
    let streamingStep: Double
    let streamingWarmup: Double
    let ringHistorySeconds: Double

    /// samples in one full segment at the model's 44100 Hz
    var segmentSamples: Int { Int((segmentSeconds * WindowGeometry.sampleRate).rounded()) }
    /// one grid step covers half a segment (transkun's stride)
    var stepSamples: Int { segmentSamples / 2 }
    var stepFrames: Int { stepSamples / WindowGeometry.hopSize }
    /// leading pad frames for the grid pipeline
    var padFrames: Int { Int((padSeconds * WindowGeometry.sampleRate) / Double(WindowGeometry.hopSize)) }
    /// mel frames one window decodes to: ceil(N / hop) + 1
    var frames: Int { (segmentSamples + WindowGeometry.hopSize - 1) / WindowGeometry.hopSize + 1 }
    /// a decoded interval reaching this frame is cut off by the window edge
    var lastFrameIdx: Int { frames - 2 }
    var frameDuration: Double { Double(WindowGeometry.hopSize) / WindowGeometry.sampleRate }
    var stepWallSeconds: Double { Double(stepSamples) / WindowGeometry.sampleRate }

    func streamingAdvance(decodeWall: Double) -> Double {
        min(max(streamingStep, decodeWall + 0.10), segmentSeconds)
    }

    /// The reference tier: matches the published transcribe() numbers.
    static let standard = WindowPlan(
        segmentSeconds: 16.0,
        padSeconds: 8.0,
        streamingStep: 0.45,
        streamingWarmup: 0.6,
        ringHistorySeconds: 25.0
    )

}

/// One chord sheet row: an onset group with its identified chord.
struct SheetEntry: Sendable {
    let onset: Double
    let chord: Chord
}

/// A decoded window: refined events in performance seconds plus the
/// per-symbol bookkeeping the next window continues from.
struct WindowResult: Sendable {
    struct Event: Sendable {
        let pitch: Int
        let velocity: Int
        let startFrame: Int
        let endFrame: Int
        let onsetSeconds: Double
        let offsetSeconds: Double
        /// True unless the interval merely continues from the window start
        /// (a note sounding before this window began, no onset observed).
        let hasOnset: Bool
        /// True unless the interval reaches the window's last frame without
        /// the offset head confirming it (the note likely continues past the
        /// trailing edge).
        let hasOffset: Bool
    }

    let windowIndex: Int
    /// content seconds of the window's first frame, edge - segmentSeconds
    let beginSeconds: Double
    let events: [Event]
    /// per symbol: end frame of the last interval whose offset was observed
    /// in this window, 0 when the symbol never ended here
    let lastP: [Int]
}
