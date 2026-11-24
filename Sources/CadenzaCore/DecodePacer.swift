import Foundation

/// Chooses how much audio each streaming window advances.
///
/// The window has to be long enough to hold the context the model needs and
/// short enough that results land close to the keys. It cannot be shorter
/// than what the machine can decode: each window costs the same whatever the
/// step, and two decoders run at once, so the floor is `wall / decoders` with
/// a margin on top. Rather than assume that margin, the pacer measures what
/// the pipeline is actually carrying — the backlog between the newest absorbed
/// window and the live edge — and moves the step in the direction that keeps
/// the backlog small: growing it when the queue backs up, shrinking it toward
/// the floor when the pipeline is idle and resolution can be bought.
public struct DecodePacer: Sendable {
    /// The step the plan wants when nothing is in the way.
    public let floorStep: Double
    /// The widest step that still leaves a live sheet worth watching.
    public let ceilingStep: Double
    /// Backlog, in seconds of audio, the pacer aims between.
    private let relaxedBacklog: Double = 0.4
    private let strainedBacklog: Double = 1.4
    /// Headroom over the theoretical floor, so the queue drains instead of
    /// sitting exactly at the boundary.
    private let floorMargin = 1.15

    /// The step to cut the next window at.
    public private(set) var step: Double
    private var measurements = 0
    /// The last few decode times. One slow decode is a hiccup — a thermal
    /// clamp, a compile, another app taking the GPU — and reading the pace
    /// from it would stretch the next minute of windows for no reason. The
    /// median of eight keeps the pace on the machine's real speed.
    private var recentWalls: [Double] = []

    public init(floorStep: Double, ceilingStep: Double) {
        self.floorStep = floorStep
        self.ceilingStep = max(ceilingStep, floorStep)
        self.step = floorStep
    }

    /// One decode finished. `wall` is how long it took, `backlog` how much
    /// audio sits between the newest absorbed window and the live edge, and
    /// `decoders` how many run side by side. Returns the next step.
    @discardableResult
    public mutating func record(wall: Double, backlog: Double, decoders: Int) -> Double {
        measurements += 1
        let parallel = Double(max(1, decoders))
        recentWalls.append(wall)
        if recentWalls.count > 8 { recentWalls.removeFirst() }
        let sorted = recentWalls.sorted()
        let typical = sorted[sorted.count / 2]
        // what the machine can sustain, whatever the pacer guessed so far,
        // read from the typical decode rather than the last one
        let sustainable = min(ceilingStep, max(floorStep, typical / parallel * floorMargin))

        var next = step
        if backlog > strainedBacklog {
            next *= 1.12
        } else if backlog < relaxedBacklog {
            next *= 0.94
        }
        // the first decode has no pace to correct yet: start from what it
        // measured rather than from the plan's wish
        if measurements == 1 { next = max(step, sustainable) }
        step = min(ceilingStep, max(sustainable, next))
        return step
    }
}
