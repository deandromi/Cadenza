import Foundation

/// The room one chord's heads take, in staff spaces — the table both the
/// engraver and the renderer read.
///
/// Two heads a second apart would sit on one another, so engraving displaces
/// the lower one left by a whole head. That displacement is ink the engraver
/// has to pay for: priced by the head at the chord's own column, the chord
/// runs into the column before it, which is what makes a dense bar look like a
/// smear of touching ovals.
public enum ChordInk {

    /// How far a displaced head stands to the left, in staff spaces. A head is
    /// a little wider than a space, and the two heads must stay round.
    public static let secondStep: Double = 1.05

    /// The column of every head of a chord, given its staff positions in any
    /// order: 0 for the chord's own column, -1 for a head displaced left
    /// because a second sits directly above it.
    ///
    /// Alternating is deliberate: three notes a second apart stack as
    /// left, right, left, the way an engraver sets a cluster, so no two heads
    /// ever land on the same spot.
    public static func headColumns(_ positions: [Int]) -> [Int] {
        var columns = [Int](repeating: 0, count: positions.count)
        let order = positions.indices.sorted { positions[$0] < positions[$1] }
        var previousPosition: Int?
        var previousColumn = 0
        for index in order {
            let position = positions[index]
            if let previous = previousPosition, position - previous == 1 {
                columns[index] = previousColumn == 0 ? -1 : 0
            }
            previousColumn = columns[index]
            previousPosition = position
        }
        return columns
    }

    /// How far the heads reach left of the chord's own column: nothing for a
    /// chord of separate lines, a head's worth for one that holds a second.
    public static func headReach(_ positions: [Int]) -> Double {
        headColumns(positions).contains(-1) ? secondStep : 0
    }
}
