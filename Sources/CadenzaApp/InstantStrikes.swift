import CadenzaCore
import Foundation

/// The instantaneous half of the pipeline: it keeps reading the newest audio
/// while the neural decode is busy with its sixteen-second window, and hands
/// back the strikes it hears within a hop of them happening.
///
/// It owns its own queue, so nothing it does can delay capture or the UI: the
/// audio thread only appends to the ring, and this reads forward from a
/// cursor of its own. A strike found here is a guess at the key and the
/// force, not a note — the decode still decides what was played.
final class InstantStrikeReader: @unchecked Sendable {
    /// How often the newest audio is read. Five milliseconds is a fifth of a
    /// hop, so the poll costs almost nothing and the strike never waits a
    /// whole audio buffer for its turn. The detector's work is per hop, not
    /// per poll, so polling twice as often does not double the cost.
    static let interval: Double = 0.005

    private let tapState: AudioTapState
    private let detector: InstantOnsetDetector
    private let queue = DispatchQueue(label: "cadenza.instant", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var cursor = 0
    /// called on the reader's own queue, once per poll that found something
    private let onStrikes: @Sendable ([InstantOnsetDetector.Strike]) -> Void

    init(tapState: AudioTapState,
         rate: Double,
         onStrikes: @escaping @Sendable ([InstantOnsetDetector.Strike]) -> Void) {
        self.tapState = tapState
        self.detector = InstantOnsetDetector(rate: rate)
        self.onStrikes = onStrikes
    }

    /// Reads whatever arrived since the last poll and reports the attacks.
    /// Called on the reader's queue; public so the probes can drive it by hand
    /// without a timer.
    func poll() {
        let (samples, end) = tapState.samples(after: cursor)
        cursor = end
        guard !samples.isEmpty else { return }
        let strikes = detector.push(samples)
        if !strikes.isEmpty { onStrikes(strikes) }
    }

    /// For the probes: feed one chunk and get the strikes it held.
    func push(_ samples: [Float]) -> [InstantOnsetDetector.Strike] {
        detector.push(samples)
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval,
                       repeating: Self.interval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
