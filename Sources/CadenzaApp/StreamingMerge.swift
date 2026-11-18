import CadenzaCore

/// The streaming merge layer: turns a sequence of sliding window decodes into
/// a growing note history plus emission events for the live MIDI path.
///
/// Every decode re-decodes almost everything the previous one saw, with more
/// context, so the same note returns refined in many windows before it is
/// final. The merge keeps one live note per pitch and separates re-decode
/// jitter (under about 35 ms) from true re-attacks:
///
/// - a decoding onset with no live note on the pitch strikes a note
/// - an interval overlapping the live note refines or extends it without
///   re-emitting: jitter refines the stored interval, a continuation extends
///   its end
/// - an observed offset releases the note: the forced-start chain anchors at
///   the observed frame, so later windows can never re-decode its region
///   again, which is what makes the merged history stable
/// - an onset on the live pitch past the jitter threshold re-strikes the
///   key: the old note releases, the new one sounds
/// - a live note absent from two consecutive decodes releases too: the
///   model changed its mind
struct StreamingMerge {
    enum Kind: Sendable { case struck, extended, released }

    struct Emission: Sendable {
        let kind: Kind
        let event: NoteEvent
    }

    /// symbol -> content seconds of its last offset-observed interval end in
    /// the latest decode; 0 means the symbol never observed an offset, so
    /// the forced-start translation anchors it as far back as the margin
    /// allows and still-sounding symbols decode as continuations rather
    /// than new onsets.
    private(set) var anchors: [Double]
    private var history: [NoteEvent] = []
    /// pitch -> history index of the pitch's live note
    private var liveIndex: [Int: Int] = [:]
    /// pitch -> consecutive decodes that did not cover its live note
    private var vanishStreak: [Int: Int] = [:]
    /// content seconds covered by the most recent decode
    private(set) var coveredSeconds = 0.0

    /// onsets re-decode within about 35 ms of their first appearance while
    /// a true re-attack on the same key is at least about 80 ms apart
    static let reOnsetThreshold = 0.06
    /// release a live note after this many consecutive decodes without it
    static let vanishLimit = 2
    /// regions re-decode this far behind a symbol's last observed offset, so
    /// a note missed at a tight trailing edge gets more chances as context
    /// grows. The reference grid takes its margin as the whole step (8 s)
    /// for the same reason; the windows overlap either way.
    static let anchorMargin = 2.0

    init(symbolCount: Int) {
        anchors = Array(repeating: 0, count: symbolCount)
    }

    /// The merged note history in confirmation order, like the engine
    /// published before.
    var notes: [NoteEvent] { history }

    /// The notes still sounding, for stop-time release.
    var livePitches: [Int] {
        Array(liveIndex.keys)
    }

    /// Reads a history slot for a live pitch.
    func liveNote(of pitch: Int) -> NoteEvent? {
        guard let index = liveIndex[pitch], history.indices.contains(index) else { return nil }
        return history[index]
    }

    /// Forced-start positions for a window beginning at `windowBegin`
    /// content seconds, in window-local frames.
    func forcedStart(for windowBegin: Double) -> [Int] {
        anchors.map { anchor in
            let reference = anchor - Self.anchorMargin
            return Int(max((reference - windowBegin) / WindowGeometry.frameDuration, 0))
        }
    }

    /// Applies one decoded window, updating the anchors and the merged
    /// history and returning the events worth emitting live.
    ///
    /// The window's events are sorted by onset; each symbol's lastP maps its
    /// latest offset-observed interval end.
    mutating func absorb(_ result: WindowResult) -> [Emission] {
        var emissions: [Emission] = []
        let begin = result.beginSeconds
        coveredSeconds = begin + WindowGeometry.segmentSeconds

        for symbol in anchors.indices where symbol < result.lastP.count {
            if result.lastP[symbol] > 0 {
                anchors[symbol] = begin + Double(result.lastP[symbol]) * WindowGeometry.frameDuration
            } else {
                anchors[symbol] = 0
            }
        }

        var seenLive = Set<Int>()
        for event in result.events {
            var note = NoteEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                onset: max(event.onsetSeconds, 0),
                duration: 0
            )
            let end = max(event.offsetSeconds, note.onset + 1e-8)
            note.duration = end - note.onset

            // noise-floor phantoms never become events
            let isStrikeCandidate = event.hasOnset && note.duration >= WindowGeometry.minimumNoteDuration

            seenLive.insert(event.pitch)
            if let index = liveIndex[event.pitch], history.indices.contains(index) {
                let live = history[index]
                if note.onset >= live.onset - Self.reOnsetThreshold {
                    mergeWithLive(index, candidate: note, hasOnset: event.hasOnset,
                                  hasOffset: event.hasOffset, isStrikeCandidate: isStrikeCandidate,
                                  into: &emissions)
                } else if isStrikeCandidate {
                    // an interval well before the live note: a margin
                    // re-decode of an already-released note (or a warmup
                    // recovery) — refresh it, never re-sound it, never touch
                    // the live note
                    if let prior = releasedSlot(of: note) {
                        history[prior] = note
                    } else {
                        history.append(note)
                        emissions.append(Emission(kind: .struck, event: note))
                    }
                }
            } else if isStrikeCandidate {
                if let prior = releasedSlot(of: note) {
                    // a re-decode returning an already-released note: refresh
                    // its stored interval the way the reference merge replaces
                    // its tail event, but never re-sound it
                    history[prior] = note
                } else {
                    history.append(note)
                    liveIndex[event.pitch] = history.count - 1
                    emissions.append(Emission(kind: .struck, event: note))
                }
            }
        }

        // a pitch covered by this decode keeps its live note alive
        for pitch in seenLive {
            vanishStreak[pitch] = 0
        }

        for (pitch, index) in liveIndex where !seenLive.contains(pitch) {
            vanishStreak[pitch, default: 0] += 1
            if vanishStreak[pitch] ?? 0 >= Self.vanishLimit, history.indices.contains(index) {
                liveIndex[pitch] = nil
                vanishStreak[pitch] = nil
                emissions.append(Emission(kind: .released, event: history[index]))
            }
        }

        return emissions
    }

    /// Releases every live note, for stop time.
    mutating func releaseAll() -> [Emission] {
        var emissions: [Emission] = []
        for (pitch, index) in liveIndex where history.indices.contains(index) {
            emissions.append(Emission(kind: .released, event: history[index]))
            liveIndex[pitch] = nil
        }
        vanishStreak = [:]
        return emissions
    }

    private func clipped(_ value: Double, to note: NoteEvent) -> Double {
        max(note.onset, min(value, note.offset))
    }

    /// A history slot holding an already-released note of the same pitch
    /// whose onset matches the candidate within the jitter threshold, the
    /// note a margin re-decode is returning for refinement. The history is
    /// confirmation-ordered, not onset-ordered, so the scan is complete.
    private func releasedSlot(of candidate: NoteEvent) -> Int? {
        for index in history.indices.reversed() {
            let prior = history[index]
            if prior.pitch == candidate.pitch,
               abs(prior.onset - candidate.onset) < Self.reOnsetThreshold {
                return index
            }
        }
        return nil
    }

    private mutating func mergeWithLive(
        _ index: Int,
        candidate: NoteEvent,
        hasOnset: Bool,
        hasOffset: Bool,
        isStrikeCandidate: Bool,
        into emissions: inout [Emission]
    ) {
        let live = history[index]
        let pitch = live.pitch
        let overlap = candidate.onset < live.offset + Self.reOnsetThreshold

        if overlap {
            let isReStrike = hasOnset && abs(candidate.onset - live.onset) >= Self.reOnsetThreshold
            if isReStrike {
                // the old key releases as it is re-struck; the merged history
                // takes the new interval, mirroring the reference replace
                let releaseEnd = min(live.offset, candidate.onset - 0.002)
                var released = live
                released.duration = max(clipped(releaseEnd, to: live) - live.onset, 1e-8)
                emissions.append(Emission(kind: .released, event: released))
                history[index] = candidate
                emissions.append(Emission(kind: .struck, event: candidate))
                return
            }
            if hasOnset {
                // re-decode jitter: refine the stored interval, never re-emit
                history[index] = candidate
            } else {
                // continuation: the sounding note simply lasts longer
                let newEnd = max(live.offset, candidate.offset)
                if newEnd > live.offset + 1e-8 {
                    history[index].duration = newEnd - live.onset
                    emissions.append(Emission(kind: .extended, event: history[index]))
                }
            }
            if hasOffset {
                liveIndex[pitch] = nil
                vanishStreak[pitch] = nil
                emissions.append(Emission(kind: .released, event: history[index]))
            }
        } else if isStrikeCandidate {
            // a fresh strike beyond the live region: the old sounding note
            // cannot keep ringing through it, release it at the strike
            if liveIndex[pitch] != nil {
                let releaseEnd = min(live.offset, candidate.onset - 0.002)
                var released = live
                released.duration = max(clipped(releaseEnd, to: live) - live.onset, 1e-8)
                emissions.append(Emission(kind: .released, event: released))
                liveIndex[pitch] = nil
            }
            history.append(candidate)
            liveIndex[pitch] = history.count - 1
            emissions.append(Emission(kind: .struck, event: candidate))
        }
    }
}
