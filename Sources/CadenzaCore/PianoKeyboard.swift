import Foundation

/// The piano's own arithmetic: which pitches stand on ivory, and where a
/// pitch sits among the ivory keys.
///
/// A keybed's geometry and the light it paints are two drawings of the same
/// fact, so the fact lives here, once, counted the way an action is built:
/// seven ivory keys to the octave with five ebony ones between them, C D E F
/// G A B. Getting this wrong is invisible until a key lights under the wrong
/// finger, so `CadenzaCoreChecks` names each ivory class and walks the whole
/// eighty-eight.
public enum PianoKeyboard {
    /// A0 through C8: the full instrument the model hears.
    public static let firstPitch = 21
    public static let lastPitch = 108
    /// Ivory keys to the octave; the fifth and seventh are the pairs that
    /// have no ebony key between them.
    public static let ivoryPerOctave = 7

    /// The ivory pitch classes as a bit pattern: C, D, E, F, G, A, B.
    /// Written out rather than computed so the seven can be read at a glance.
    private static let ivoryClasses: UInt16 =
        (1 << 0) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11)

    /// How many ivory keys stand below each pitch class in its octave.
    /// C has none below it, D has C, E has C and D, and so on; the ebony
    /// classes carry the count of the ivory key they lean against.
    private static let ivoryBefore: [Int] = [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6]

    public static func pitchClass(of pitch: Int) -> Int {
        ((pitch % 12) + 12) % 12
    }

    /// True for the ivory keys: C D E F G A B.
    public static func isIvory(_ pitch: Int) -> Bool {
        ivoryClasses & (1 << UInt16(pitchClass(of: pitch))) != 0
    }

    /// Ivory keys strictly below `pitch`, counted from the bottom of the
    /// keyboard rather than from C.
    private static func ivoryCountBelow(_ pitch: Int) -> Int {
        // Swift's integer division already floors toward negative infinity,
        // so pitches below C-1 count correctly.
        ivoryPerOctave * (pitch / 12) + ivoryBefore[pitchClass(of: pitch)]
    }

    /// A pitch's place among the ivory keys, 0-based from A0, or nil when the
    /// pitch falls on ebony. A keybed lays its ivory keys out in this order,
    /// so this is also the column a key occupies.
    public static func ivoryIndex(of pitch: Int) -> Int? {
        guard isIvory(pitch) else { return nil }
        return ivoryCountBelow(pitch) - ivoryCountBelow(firstPitch)
    }

    /// The number of ivory keys in the instrument: fifty-two on a piano.
    public static var ivoryCount: Int {
        ivoryCountBelow(lastPitch + 1) - ivoryCountBelow(firstPitch)
    }

    /// The ivory key an ebony key leans to: the one below it. C sharp leans
    /// on C, which is also the boundary the key sits across.
    public static func ivoryBelow(_ ebony: Int) -> Int {
        var pitch = ebony
        while !isIvory(pitch) { pitch -= 1 }
        return pitch
    }
}
