import Foundation

/// How much room the accidentals of one chord take on the page, in staff
/// spaces — read by the engraver that reserves the width and by the renderer
/// that draws it.
///
/// Accidentals stand in columns to the left of a chord's leftmost head, so a
/// chord carrying three of them is wider than its noteheads say. When the
/// engraver prices a chord by its heads alone, the line packs one chord too
/// many and the accidental is printed in the chord beside it: the smudged,
/// colliding look of a transcription. One table, two readers, no drift.
public enum AccidentalInk {

    /// A glyph, as far as its width is concerned.
    public enum Kind: Sendable, Equatable {
        case sharp, flat, natural
    }

    /// The advance of each glyph in Bravura, in staff spaces. These are the
    /// font's own metrics (a sharp is just under a space wide, a natural two
    /// thirds of one), measured rather than guessed.
    public static func advance(_ kind: Kind) -> Double {
        switch kind {
        case .sharp: return 0.996
        case .flat: return 0.904
        case .natural: return 0.672
        }
    }

    /// How far the right edge of the first accidental stands left of the
    /// chord's leftmost head.
    public static let glyphGap: Double = 0.85

    /// The distance between two accidental columns.
    public static let columnStep: Double = 0.72

    /// The column each accidental stands in, in the order given. Two marks a
    /// second apart share no column: they would print as one smudged sign over
    /// the note it does not belong to.
    public static func columns(_ marks: [(position: Int, kind: Kind)]) -> [Int] {
        var taken: [(position: Int, column: Int)] = []
        var result: [Int] = []
        for mark in marks {
            var column = 0
            while taken.contains(where: { $0.column == column && abs($0.position - mark.position) < 3 }) {
                column += 1
            }
            taken.append((mark.position, column))
            result.append(column)
        }
        return result
    }

    /// The ink one chord's accidentals take to the left of its leftmost head:
    /// the gap, the width of each column that is used, and the widest glyph in
    /// the stack standing past its own column.
    public static func width(_ marks: [(position: Int, kind: Kind)]) -> Double {
        guard !marks.isEmpty else { return 0 }
        let columns = columns(marks)
        let widest = marks.map { advance($0.kind) }.max() ?? 0
        let deepest = columns.max() ?? 0
        return glyphGap + Double(deepest) * columnStep + widest
    }
}

extension SheetDraft.Accidental {
    /// The glyph this spelling draws with, when it draws one.
    public var ink: AccidentalInk.Kind? {
        switch self {
        case .sharp: return .sharp
        case .flat: return .flat
        case .natural: return .natural
        case .none: return nil
        }
    }
}
