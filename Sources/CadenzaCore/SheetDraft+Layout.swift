import Foundation

/// Measure cells and the rows they wrap into at the page width.
extension SheetDraft {
    // MARK: measure cells and rows

    /// Both hands share the same bar times, so each measure is a cell of
    /// column items between its barlines. Returns one pair per measure.
    static func measureCells(top: [Symbol], bottom: [Symbol], measureTicks: Int)
        -> [(start: Int, top: [Symbol], bottom: [Symbol])] {
        func cells(_ symbols: [Symbol]) -> [(start: Int, items: [Symbol])] {
            var result: [(Int, [Symbol])] = []
            var start = 0
            var items: [Symbol] = []
            for s in symbols {
                switch s {
                case .bar(let t):
                    result.append((start, items))
                    start = t
                    items = []
                case .finalBar:
                    result.append((start, items))
                    items = []
                default:
                    if s.isColumn { items.append(s) }
                }
            }
            return result
        }
        let topCells = cells(top)
        let bottomCells = cells(bottom)
        let count = max(topCells.count, bottomCells.count)
        var result: [(Int, [Symbol], [Symbol])] = []
        for i in 0..<count {
            let t = i < topCells.count ? topCells[i].items : []
            let b = i < bottomCells.count ? bottomCells[i].items : []
            let start = i < topCells.count
                ? topCells[i].start
                : (i < bottomCells.count ? bottomCells[i].start : 0)
            result.append((start, t, b))
        }
        return result
    }

    /// The row layout: measures accumulate whole into rows at the page
    /// width; each measure's columns are the union of both hands' column
    /// times; a hand missing a column draws a zero-width blank. Leftover
    /// row width spreads equally across columns, capped at two spaces.
    /// Track indices run through the original symbol lists so beam
    /// partners stay findable.
    public static func layoutRows(top: [Symbol], bottom: [Symbol], clefsTop: [Clef], clefsBottom: [Clef],
                                  options: Options, pageWidth: Double) -> [Row] {
        let measureTicks = options.measureTicks
        let cells = measureCells(top: top, bottom: bottom, measureTicks: measureTicks)
        let framingWidth = 9.5
        var rows: [Row] = []
        var cellIndex = 0

        // An index of (track, symbol index) -> symbol for track lookups.
        func trackIndexOf(_ symbol: Symbol, at after: Int, list: [Symbol]) -> Int {
            var i = after
            while i < list.count {
                if list[i] == symbol { return i }
                i += 1
            }
            return -1
        }

        while cellIndex < cells.count {
            var width = framingWidth
            var fitting: [Int] = []
            while cellIndex < cells.count {
                let cell = cells[cellIndex]
                var cellWidth = cell.top.reduce(0.0) { $0 + $1.width }
                cellWidth = max(cellWidth, cell.bottom.reduce(0.0) { $0 + $1.width })
                cellWidth = max(cellWidth, 1.6) + 0.8
                if !fitting.isEmpty, width + cellWidth > pageWidth { break }
                width += cellWidth
                fitting.append(cellIndex)
                cellIndex += 1
            }
            if fitting.isEmpty {
                fitting.append(cellIndex)
                cellIndex += 1
            }

            // Column times across the row's measures.
            var columnTimes: [Int] = []
            for cellNumber in fitting {
                let cell = cells[cellNumber]
                var times = Set<Int>()
                for s in cell.top + cell.bottom where s.isColumn {
                    times.insert(s.startTicks)
                }
                columnTimes.append(contentsOf: times.sorted())
            }

            // Leftover width spreads across columns, up to two each.
            var extra = 0.0
            if width < pageWidth, !columnTimes.isEmpty {
                extra = min(2.0, (pageWidth - width) / Double(columnTimes.count))
                width = min(pageWidth, width + extra * Double(columnTimes.count))
            }

            var topPlaced: [Placed] = []
            var bottomPlaced: [Placed] = []
            var tx = framingWidth
            var bx = framingWidth
            var topCursor = 0
            var bottomCursor = 0
            let firstStart = cells[fitting[0]].start

            for cellNumber in fitting {
                let cell = cells[cellNumber]
                let barSymbol = Symbol.bar(startTicks: cell.start)
                topCursor = advanceCursor(topCursor, in: top, to: barSymbol.startTicks)
                bottomCursor = advanceCursor(bottomCursor, in: bottom, to: barSymbol.startTicks)
                topPlaced.append(Placed(x: tx, trackIndex: topCursor, symbol: barSymbol))
                bottomPlaced.append(Placed(x: bx, trackIndex: bottomCursor, symbol: barSymbol))
                tx += barSymbol.width
                bx += barSymbol.width

                // This measure's own column times, split between hands.
                var times = Set<Int>()
                for s in cell.top + cell.bottom where s.isColumn && s.startTicks >= cell.start
                    && s.startTicks < cell.start + measureTicks {
                    times.insert(s.startTicks)
                }
                for t in times.sorted() {
                    func draw(_ items: [Symbol], x: inout Double, cursor: inout Int,
                              placed: inout [Placed], list: [Symbol]) {
                        // every column item at this time takes its place in
                        // order (a pedal mark and its chord share a column)
                        var placedAny = false
                        for item in items where item.isColumn && item.startTicks == t {
                            let index = trackIndexOf(item, at: cursor, list: list)
                            placed.append(Placed(x: x, trackIndex: index, symbol: item))
                            x += item.width + extra
                            if index >= 0 { cursor = index }
                            placedAny = true
                        }
                        if !placedAny {
                            placed.append(Placed(x: x, trackIndex: -1, symbol: .blank(startTicks: t)))
                            x += extra
                        }
                    }
                    draw(cell.top, x: &tx, cursor: &topCursor, placed: &topPlaced, list: top)
                    draw(cell.bottom, x: &bx, cursor: &bottomCursor, placed: &bottomPlaced, list: bottom)
                }
            }

            // The closing bar of the piece lands at the last row's end.
            let end = cells[fitting[fitting.count - 1]].start + measureTicks
            let closing: Symbol = cellIndex >= cells.count ? .finalBar(startTicks: end) : .bar(startTicks: end)
            let topClose = { () -> Int in var i = topCursor; while i < top.count { if top[i] == closing { return i }; i += 1 }; return topCursor }()
            let bottomClose = { () -> Int in var i = bottomCursor; while i < bottom.count { if bottom[i] == closing { return i }; i += 1 }; return bottomCursor }()
            topPlaced.append(Placed(x: tx, trackIndex: topClose, symbol: closing))
            bottomPlaced.append(Placed(x: bx, trackIndex: bottomClose, symbol: closing))
            tx += closing.width
            bx += closing.width

            let firstMeasure = firstStart / measureTicks + 1
            let clefTop = Self.clef(at: firstStart, clefs: clefsTop, measureTicks: measureTicks)
            let clefBottom = Self.clef(at: firstStart, clefs: clefsBottom, measureTicks: measureTicks)
            rows.append(Row(clefTop: clefTop, clefBottom: clefBottom,
                            top: topPlaced, bottom: bottomPlaced,
                            firstMeasure: firstMeasure,
                            showsFraming: firstStart == 0,
                            width: max(tx, bx)))
        }
        if rows.isEmpty {
            rows.append(Row(clefTop: .treble, clefBottom: .bass, top: [], bottom: [],
                           firstMeasure: 1, showsFraming: true, width: framingWidth))
        }
        return rows
    }

    /// Move the cursor to the first symbol at or after the given time.
    private static func advanceCursor(_ cursor: Int, in symbols: [Symbol], to start: Int) -> Int {
        var i = cursor
        while i < symbols.count, symbols[i].startTicks < start { i += 1 }
        return i
    }
}
