import Foundation

/// The rhythm stage: one staff's columns become written voices.
///
/// This is the part MuseScore's MIDI import calls "simplify durations", and it
/// is what makes a performance read as notation:
///
/// 1. Notes still sounding when the next attack lands belong to a second
///    voice, the way a pianist's hands share a staff; each voice then has a
///    rhythm of its own.
/// 2. A note's written value comes from the room it owns in its voice — the
///    distance to that voice's next attack — not from the raw held length,
///    which a player stretches and clips at will. Only a note that is clearly
///    let go early prints short, and its silence is filled with rests.
/// 3. A value that would hide a beat is split into tied pieces (see `Meter`),
///    and a value that runs past a barline is split there and tied over it.
/// 4. Every silence of every voice is filled with rests, so each voice tiles
///    its bar exactly and the bars line up.
/// 5. Eighths and sixteenths beam inside their beat, never across a rest and
///    never across a barline. A dotted note beams with its own value.
extension SheetEngraver {
    struct StaffWriter {
        let meter: SheetDraft.Meter
        let clef: SheetDraft.Clef
        let fifths: Int
        let track: Int
        /// The take's own quantization step, in ticks.
        let grid: Int

        /// One printed column of a bar, before it becomes a `Symbol`.
        struct Written {
            var start: Int
            var length: Int
            var voice: Int
            /// nil for a rest.
            var pitches: [Int]?
            /// The value keeps sounding in the next piece of this voice.
            var tied: Bool
        }

        /// What a bar's beam pass needs to know about one symbol.
        struct BeamEntry {
            let index: Int
            let start: Int
            let length: Int
            let flags: Int
        }

        func write(_ bars: [[Column]], measureStarts: [Int],
                   ties: inout [SheetDraft.Tie],
                   groups: inout [SheetDraft.BeamGroup],
                   slurs: inout [SheetDraft.Slur],
                   nextID: inout Int) -> Staff {
            let measureTicks = meter.measureTicks
            var staff = Staff()

            // 1. Voices, across the whole staff.
            //
            // A column joins the first voice that has fallen silent; when
            // both voices are still sounding it joins the one that frees up
            // soonest, which keeps the melody line together.
            let legato = SheetDraft.ticksPerQuarter / 8
            var voiceEnd = [0, 0]
            var perVoice: [[Column]] = [[], []]
            for bar in bars {
                for column in bar.sorted(by: { $0.start < $1.start }) {
                    var voice = 0
                    if voiceEnd[0] > column.start + legato {
                        voice = voiceEnd[1] <= column.start + legato
                            ? 1
                            : (voiceEnd[0] <= voiceEnd[1] ? 0 : 1)
                    }
                    voiceEnd[voice] = max(voiceEnd[voice], column.start + column.held)
                    perVoice[voice].append(column)
                }
            }
            // 2. The values: each column owns the room up to its voice's next
            //    attack, and a value that crosses a barline or hides a beat is
            //    written as tied pieces.
            let pieceEnd = measureStarts.last.map { $0 + measureTicks } ?? 0
            var written: [[[Written]]] = Array(repeating: [[], []], count: bars.count)
            // The keys the player hung on past the next attack: those are the
            // joins that earn a phrase mark. A sheet that slurs every pair of
            // adjacent notes is a sheet with a slur on every bar.
            var joined = Set<Int>()
            for voice in 0..<2 {
                let list = perVoice[voice]
                for (index, column) in list.enumerated() {
                    let nextStart = index + 1 < list.count ? list[index + 1].start : pieceEnd
                    let gap = max(grid, nextStart - column.start)
                    let bar = barIndex(of: column.start, measureStarts: measureStarts)
                    guard bar < written.count else { continue }
                    let barStart = measureStarts[bar]
                    let nextBar = bar + 1 < measureStarts.count
                        ? measureStarts[bar + 1] : barStart + measureTicks
                    let room = max(grid, min(gap, nextBar - column.start))
                    let span = length(of: column, gap: gap, room: room)
                    if column.held > gap + grid / 4 { joined.insert(column.start) }
                    var start = column.start
                    var remaining = span
                    while remaining > 0 {
                        let pieceBar = barIndex(of: start, measureStarts: measureStarts)
                        guard pieceBar < written.count else { break }
                        let pieceBarStart = measureStarts[pieceBar]
                        let pieceBarEnd = pieceBar + 1 < measureStarts.count
                            ? measureStarts[pieceBar + 1] : pieceBarStart + measureTicks
                        let local = start - pieceBarStart
                        let pieceRoom = max(0, min(measureTicks - local, pieceBarEnd - start))
                        guard pieceRoom > 0 else { break }
                        let inBar = min(remaining, pieceRoom)
                        let pieces = meter.split(start: local, length: inBar)
                        for (offset, piece) in pieces.enumerated() {
                            let more = offset + 1 < pieces.count || inBar < remaining
                            written[pieceBar][voice].append(Written(
                                start: pieceBarStart + piece.start, length: piece.length,
                                voice: voice, pitches: column.pitches, tied: more))
                        }
                        remaining -= inBar
                        start += inBar
                    }
                }
            }

            // 3. The ties the split asked for: one per pitch that keeps
            //    sounding into the next piece of its own voice — which is the
            //    next piece in that voice, in the next bar as often as not.
            for voice in 0..<2 {
                let flat = written.flatMap { $0[voice] }.sorted { $0.start < $1.start }
                for (index, piece) in flat.enumerated() where piece.tied {
                    guard index + 1 < flat.count else { continue }
                    let next = flat[index + 1]
                    guard next.start == piece.start + piece.length,
                          let pitches = piece.pitches else { continue }
                    for pitch in pitches {
                        let tie = SheetDraft.Tie(track: track, pitch: pitch,
                                                 fromTicks: piece.start,
                                                 toTicks: next.start)
                        if !ties.contains(tie) { ties.append(tie) }
                    }
                }
            }

            // 4. Bars to symbols: two voices in time order, each with the
            //    rests that fill its silences.
            var shown = Set<String>()
            for bar in 0..<bars.count {
                let barStart = measureStarts[bar]
                staff.symbols.append(.bar(startTicks: barStart))
                var indices: [Int] = []
                let live = written[bar].contains { !$0.isEmpty }
                guard live else {
                    indices.append(staff.symbols.count)
                    staff.symbols.append(.rest(startTicks: barStart, kind: .whole))
                    staff.measures.append(indices)
                    shown.removeAll()
                    continue
                }
                let polyphonic = written[bar][0].isEmpty == false && written[bar][1].isEmpty == false
                var beams: [[BeamEntry]] = [[], []]
                for voice in 0..<2 {
                    var cursor = barStart
                    let pieces = written[bar][voice].sorted { $0.start < $1.start }
                    if pieces.isEmpty {
                        if voice == 0 {
                            // the upper voice is silent while the lower one
                            // plays: it still prints its own whole-bar rest
                            indices.append(staff.symbols.count)
                            staff.symbols.append(.restVoiced(startTicks: barStart, kind: .whole, voice: 0))
                        }
                        continue
                    }
                    for piece in pieces {
                        if piece.start > cursor {
                            for rest in meter.rests(start: cursor - barStart, end: piece.start - barStart) {
                                guard let kind = meter.restKind(rest.length) else { continue }
                                indices.append(staff.symbols.count)
                                staff.symbols.append(restSymbol(kind, at: barStart + rest.start,
                                                                voice: voice, polyphonic: polyphonic))
                            }
                        }
                        indices.append(staff.symbols.count)
                        if let pitches = piece.pitches {
                            let chord = self.chord(pitches: pitches, at: piece.start, length: piece.length,
                                                   voice: voice, polyphonic: polyphonic, tied: piece.tied,
                                                   shown: &shown)
                            staff.symbols.append(.chord(chord))
                            if let stem = chord.stems.first {
                                beams[voice].append(BeamEntry(index: staff.symbols.count - 1,
                                                              start: piece.start, length: piece.length,
                                                              flags: stem.flags))
                            }
                        }
                        cursor = max(cursor, piece.start + piece.length)
                    }
                    if cursor < barStart + measureTicks {
                        for rest in meter.rests(start: cursor - barStart, end: measureTicks) {
                            guard let kind = meter.restKind(rest.length) else { continue }
                            indices.append(staff.symbols.count)
                            staff.symbols.append(restSymbol(kind, at: barStart + rest.start,
                                                            voice: voice, polyphonic: polyphonic))
                        }
                    }
                }
                if indices.isEmpty {
                    indices.append(staff.symbols.count)
                    staff.symbols.append(.rest(startTicks: barStart, kind: .whole))
                }
                staff.measures.append(indices)
                shown.removeAll()

                // 5. Beams, inside the beat and inside the voice.
                for voice in 0..<2 {
                    beam(beams[voice], symbols: &staff.symbols,
                         groups: &groups, nextID: &nextID)
                }
            }

            // 6. Phrase marks: runs of notes the player joined with a finger
            //    still down, inside one bar and capped at four notes.
            for voice in 0..<2 {
                let chords = written.flatMap { $0[voice] }
                    .filter { $0.pitches != nil }
                    .sorted { $0.start < $1.start }
                var run: [Int] = []
                func flush() {
                    defer { run = [] }
                    guard run.count >= 2, let first = run.first, let last = run.last,
                          first / measureTicks == last / measureTicks else { return }
                    slurs.append(SheetDraft.Slur(track: track, fromTicks: first, toTicks: last))
                }
                for (index, piece) in chords.enumerated() {
                    let next = index + 1 < chords.count ? chords[index + 1] : nil
                    let carries = joined.contains(piece.start)
                        && next.map { $0.start == piece.start + piece.length } ?? false
                    if !carries { flush(); continue }
                    run.append(piece.start)
                    if run.count == 4 { flush() }
                }
                flush()
            }

            staff.symbols.append(.finalBar(startTicks: pieceEnd))
            return staff
        }

        // MARK: values

        /// The written length of a column: the room it owns in its own voice,
        /// cut at the barline, and what the player held when that is shorter.
        private func length(of column: Column, gap: Int, room: Int) -> Int {
            // A note held through the room — to the next attack, the barline,
            // or past both — keeps going and is tied where it crosses.
            if column.held >= room { return max(room, min(gap, column.held)) }
            // A note that fills at least half its room holds the room: a player
            // who lifts the key a little early is phrasing, not resting, and a
            // sheet that prints every such lift as a rest is a sheet nobody
            // plays. Only a note let go well before its room ends prints short,
            // and rests close the room behind it.
            if column.held * 2 >= room { return room }
            return max(grid, column.held)
        }

        private func barIndex(of tick: Int, measureStarts: [Int]) -> Int {
            guard !measureStarts.isEmpty else { return 0 }
            var low = 0
            var high = measureStarts.count - 1
            var found = 0
            while low <= high {
                let mid = (low + high) / 2
                if measureStarts[mid] <= tick {
                    found = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return found
        }

        // MARK: symbols

        private func restSymbol(_ kind: SheetDraft.RestKind, at tick: Int,
                                voice: Int, polyphonic: Bool) -> SheetDraft.Symbol {
            polyphonic
                ? .restVoiced(startTicks: tick, kind: kind, voice: voice)
                : .rest(startTicks: tick, kind: kind)
        }

        /// One chord from the pitches sharing a column.
        private func chord(pitches: [Int], at start: Int, length: Int,
                           voice: Int, polyphonic: Bool, tied: Bool,
                           shown: inout Set<String>) -> SheetDraft.Chord {
            let value = SheetDraft.noteValue(length)
            var glyphs: [SheetDraft.NoteGlyph] = []
            for pitch in pitches.sorted() {
                let position = clef.position(ofPitch: pitch)
                var accidental = SheetDraft.accidental(pitchClass: ((pitch % 12) + 12) % 12,
                                                      fifths: fifths)
                // a measure remembers: the same accidental on the same line
                // shows once, and a line the key already spells carries none
                if accidental != .none {
                    let key = "\(position)-\(accidental)"
                    if shown.contains(key) {
                        accidental = .none
                    } else {
                        shown.insert(key)
                    }
                }
                glyphs.append(SheetDraft.NoteGlyph(
                    pitch: pitch, staffPosition: position,
                    head: value.head, dots: value.dots,
                    accidental: accidental,
                    ledgers: SheetDraft.ledgers(forPosition: position),
                    tieToNext: tied))
            }
            var stems: [SheetDraft.Stem] = []
            if value.head != .whole {
                // in a bar with two voices the voice decides the direction, the
                // way polyphony is written; with one voice the classic rule does
                let positions = glyphs.map(\.staffPosition)
                let up = polyphonic
                    ? voice == 0
                    : positions.reduce(0, +) / max(1, positions.count) < 4
                stems = [SheetDraft.Stem(noteRange: 0..<pitches.count, up: up,
                                         flags: value.flags, beamGroupId: nil)]
            }
            return SheetDraft.Chord(startTicks: start, endTicks: start + length,
                                    notes: glyphs, stems: stems, voice: voice)
        }

        // MARK: beams

        /// Beam a voice's eighths and sixteenths inside one beat of one bar.
        /// A rest, a barline or a longer value closes a group, the members of
        /// a group share one flag count, and four is the most a beat can hold.
        private func beam(_ entries: [BeamEntry], symbols: inout [SheetDraft.Symbol],
                          groups: inout [SheetDraft.BeamGroup], nextID: inout Int) {
            let beat = meter.beatTicks
            var run: [BeamEntry] = []
            func close() {
                defer { run = [] }
                guard run.count >= 2 else { return }
                let flags = run.map(\.flags).max() ?? 1
                var up = true
                if case .chord(let first) = symbols[run[0].index],
                   let stem = first.stems.first {
                    up = stem.up
                }
                for entry in run {
                    guard case .chord(let chord) = symbols[entry.index] else { continue }
                    // every member keeps its own flag count — a sixteenth in a
                    // group of eighths still needs its second beam — and only
                    // the beam itself spans the group
                    let stems = chord.stems.map { stem in
                        SheetDraft.Stem(noteRange: stem.noteRange, up: stem.up,
                                        flags: stem.flags, beamGroupId: nextID)
                    }
                    symbols[entry.index] = .chord(SheetDraft.Chord(startTicks: chord.startTicks,
                                                                   endTicks: chord.endTicks,
                                                                   notes: chord.notes, stems: stems,
                                                                   voice: chord.voice))
                }
                groups.append(SheetDraft.BeamGroup(id: nextID, track: track,
                                                   chordIndices: run.map(\.index),
                                                   up: up, flags: flags))
                nextID += 1
            }
            for entry in entries {
                guard entry.flags > 0 else { close(); continue }
                if let last = run.last,
                   last.start / beat != entry.start / beat
                    || last.flags != entry.flags
                    || last.start + last.length != entry.start {
                    close()
                }
                run.append(entry)
                if run.count == 4 { close() }
            }
            close()
        }
    }
}
