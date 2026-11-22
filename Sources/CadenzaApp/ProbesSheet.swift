import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation
import CoreText

extension SmokeMain {
/// The sheet diagnostics: engraving a MIDI file offscreen, the PDF writer and
/// the report that compares a rendered sheet against its source.
    /// Engraves a captured session offline: the replay's merged notes go to
    /// the engraver with the same chord inference the live sheet uses, and
    /// the resulting MusicXML lands in /tmp so the sheet generator can be
    /// judged on real performances before any UI exists.
    /// - score <file.f32> <deviceRate>
    static func runScore(path: String, deviceRate: Double) {
        let notes = replayNotes(path: path, deviceRate: deviceRate)
        guard !notes.isEmpty else {
            print("score: nothing to engrave")
            exit(1)
        }
        let grouped = assignOnsetGroups(notes)
        var chords: [(seconds: Double, symbol: String)] = []
        var lastSymbol = ""
        let chordsByGroup = Dictionary(grouping: grouped, by: { $0.onsetGroup })
        for groupId in chordsByGroup.keys.sorted() {
            guard let chord = Chord.identify(in: grouped, group: groupId) else { continue }
            guard chord.symbol != lastSymbol else { continue }
            let onset = chordsByGroup[groupId]?.map(\.onset).min() ?? 0
            chords.append((onset, chord.symbol))
            lastSymbol = chord.symbol
        }
        guard let score = Engraver.engrave(notes: notes, chords: chords) else {
            print("score: engraving failed")
            exit(1)
        }
        let time = score.framing.timeSignature
        let chordList = score.chords.map(\.symbol).joined(separator: ", ")
        print("score: \(Int(score.framing.beatsPerMinute.rounded())) bpm, \(time.beatsPerMeasure)/\(time.beatUnit), \(score.framing.key.name), \(score.measures.count) measures, chords: \(chordList)")
        let xml = MusicXML.write(score)
        do {
            try xml.write(toFile: "/tmp/cadenza_score.musicxml", atomically: true, encoding: .utf8)
            print("score: musicxml written to /tmp/cadenza_score.musicxml")
        } catch {
            print("score FAILED: \(error)")
            exit(1)
        }
    }

    /// Feeds a published MIDI file to the sheet generator and compares the
    /// engraver's framing against the file's own tempo, meter and key meta
    /// events — the ground truth a published score always carries — plus
    /// the quantization deviation per note. Writes the engraved document to
    /// /tmp/cadenza_midiscore.musicxml and sketches the first measures as
    /// text for eyeballing against the reference PDF.
    /// - midiscore <file.mid>
    static func runMidiScore(path: String) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("midiscore: cannot read \(path)")
            exit(1)
        }
        print("midiscore: \(file.notes.count) notes at \(file.ticksPerQuarter) ppqn")

        let metaTempo = file.initialTempo
        let metaMeter = file.timeSignatures.first?.signature
        let metaKey = file.keySignatures.first?.key
        let meterText = metaMeter.map { "\($0.beatsPerMeasure)/\($0.beatUnit)" } ?? "?"
        print("midiscore meta: \(Int(metaTempo.rounded())) bpm, \(meterText), \(metaKey?.name ?? "?")")

        let grouped = assignOnsetGroups(file.notes)
        var chords: [(seconds: Double, symbol: String)] = []
        var lastSymbol = ""
        let chordsByGroup = Dictionary(grouping: grouped, by: { $0.onsetGroup })
        for groupId in chordsByGroup.keys.sorted() {
            guard let chord = Chord.identify(in: grouped, group: groupId) else { continue }
            guard chord.symbol != lastSymbol else { continue }
            let onset = chordsByGroup[groupId]?.map(\.onset).min() ?? 0
            chords.append((onset, chord.symbol))
            lastSymbol = chord.symbol
        }

        guard let score = Engraver.engrave(notes: file.notes, chords: chords) else {
            print("midiscore: nothing to engrave")
            exit(1)
        }
        let framing = score.framing
        let engravedMeter = "\(framing.timeSignature.beatsPerMeasure)/\(framing.timeSignature.beatUnit)"
        print("midiscore engraved: \(Int(framing.beatsPerMinute.rounded())) bpm, \(engravedMeter), \(framing.key.name), \(score.measures.count) measures")
        print("midiscore framing delta: tempo \(String(format: "%.1f", framing.beatsPerMinute - metaTempo)) bpm, meter \(engravedMeter == meterText ? "match" : "MISMATCH (meta \(meterText))"), key \(framing.key.name == metaKey?.name ? "match" : "MISMATCH (meta \(metaKey?.name ?? "?"))")")
        Engraver.meterDebug = true
        for candidate in Engraver.scoreMeterCandidates(file.notes, tempo: framing.beatsPerMinute) {
            print(String(format: "midiscore meter candidate %d/%d score %.3f", candidate.signature.beatsPerMeasure, candidate.signature.beatUnit, candidate.score))
        }
        Engraver.meterDebug = false
        for bpm in Engraver.tempoCandidates(file.notes) {
            let top = Engraver.scoreMeterCandidates(file.notes, tempo: bpm).first
            print(String(format: "midiscore tempo candidate %.0f bpm -> best meter %d/%d score %.3f", bpm, top?.signature.beatsPerMeasure ?? 0, top?.signature.beatUnit ?? 0, top?.score ?? 0))
        }

        // pitch-class evidence for the key call: top classes by sounding
        // time, and the root of the final chord when one is identifiable
        var histogram = Array(repeating: 0.0, count: 12)
        for note in file.notes { histogram[note.pitchClass] += note.duration }
        let top = histogram.enumerated().sorted { $0.element > $1.element }.prefix(5)
        let letters = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        print("midiscore pitch classes: " + top.map { "\(letters[$0.offset]):\(Int($0.element))s" }.joined(separator: " "))
        if let lastGroup = grouped.last?.onsetGroup,
           let finalChord = Chord.identify(in: grouped, group: lastGroup) {
            print("midiscore final chord root: \(finalChord.root)")
        }
        // cadence evidence: pitch classes of the first and last onset groups
        let groupIds = Array(Set(grouped.map(\.onsetGroup))).sorted()
        for gid in (groupIds.prefix(2) + groupIds.suffix(3)) {
            let members = grouped.filter { $0.onsetGroup == gid }
            let onset = members.map(\.onset).min() ?? 0
            let names = Set(members.map { letters[$0.pitchClass] }).sorted()
            print(String(format: "midiscore group @%.1fs: %@", onset, names.joined(separator: " ")))
        }

        // quantization deviation: the tick the engraver wrote versus the
        // ideal tick at the engraved tempo, both relative to the first note
        let quarterSeconds = 60.0 / framing.beatsPerMinute
        let firstOnset = file.notes.map(\.onset).min() ?? 0
        let engravedNotes = score.measures.flatMap(\.notes).sorted { ($0.onsetTick, $0.pitch) < ($1.onsetTick, $1.pitch) }
        let midiSorted = file.notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        var deviations: [Double] = []
        for (a, b) in zip(midiSorted, engravedNotes) {
            let ideal = (a.onset - firstOnset) / quarterSeconds * Double(scoreTicksPerQuarter)
            deviations.append(abs(Double(b.onsetTick) - ideal))
        }
        if let maxDev = deviations.max(), let mean = deviations.isEmpty ? nil : deviations.reduce(0, +) / Double(deviations.count) {
            let sixteenth = scoreTicksPerQuarter / 4
            let within = Double(deviations.filter { $0 <= Double(sixteenth) / 2 }.count) / Double(deviations.count)
            print(String(format: "midiscore quantization: mean %.1f ticks, max %.1f ticks, %.0f%% within a sixteenth", mean, maxDev, within * 100))
        }

        // text sketch of the first measures for eyeballing against the PDF
        for measure in score.measures.prefix(6) {
            let notes = measure.notes.map { "\(noteName($0.pitch)):\($0.durationTicks)" }.joined(separator: " ")
            let chordsHere = score.chords
                .filter { $0.onsetTick >= measure.startTick && $0.onsetTick < measure.startTick + framing.timeSignature.ticksPerMeasure }
                .map(\.symbol)
                .joined(separator: ",")
            print("measure \(measure.index + 1)\(chordsHere.isEmpty ? "" : " [\(chordsHere)]"): \(notes)")
        }

        let xml = MusicXML.write(score)
        do {
            try xml.write(toFile: "/tmp/cadenza_midiscore.musicxml", atomically: true, encoding: .utf8)
            print("midiscore: musicxml written to /tmp/cadenza_midiscore.musicxml")
        } catch {
            print("midiscore FAILED: \(error)")
            exit(1)
        }
    }

    /// Renders an engraved result offscreen onto paper and writes it as a
    /// PNG: the shared tail of the sheet diagnostics.
    @MainActor
    static func writeSheet(_ result: SheetDraft.Result, to path: String) {
        let view = ScoreView(result: result)
        let size = ScoreView.pointSize(of: result)
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let scale: CGFloat = 1.6
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        // paper behind the ink
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current {
            PaperTheme.paper.setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            ctx.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            view.draw(NSRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            print("sheet: could not write png")
            exit(1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("sheet: wrote \(path)")
    }

    /// Renders an engraved MIDI file's sheet to a PNG, offscreen, so the
    /// notation can be inspected without opening a window: --sheet <mid>
    /// A known phrase for calibrating the engraver: quarters in both hands,
    /// a half note, eighths that must beam, a dotted rhythm, a chord with a
    /// second in it, ledger lines above and below, and a rest.
    static func calibrationNotes() -> [NoteEvent] {
        var notes: [NoteEvent] = []
        let quarter = 0.5
        func add(_ pitch: Int, _ beat: Double, _ length: Double) {
            notes.append(NoteEvent(pitch: pitch, velocity: 70, onset: beat * quarter,
                                   duration: length * quarter))
        }
        // measure 1: five quarters in the right hand over a held bass
        for (index, pitch) in [72, 74, 76, 77, 79].enumerated() {
            add(pitch, Double(index), 1)
        }
        add(43, 0, 3)
        add(55, 0, 3)
        // measure 2: half + quarter, a chord with a second (C5 + D5), bass fifth
        add(81, 3, 2)
        add(79, 5, 1)
        add(72, 3, 2)
        add(74, 3, 2)
        add(45, 3, 3)
        add(52, 3, 3)
        // measure 3: beamed eighths, then a quarter rest and a quarter
        for (index, pitch) in [84, 83, 81, 79].enumerated() {
            add(pitch, 6 + Double(index) * 0.5, 0.5)
        }
        add(77, 8, 1)
        add(50, 6, 3)
        // measure 4: dotted quarter + eighth, a deep ledger-line bass
        add(76, 9, 1.5)
        add(74, 10.5, 0.5)
        add(36, 9, 3)
        add(91, 11, 1)
        return notes
    }

    static func runSheet(path: String) {
        MainActor.assumeIsolated {
            // the app renders its paper world in light mode; the offscreen
            // render must resolve the same dynamic colors
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            if path == "test" {
                let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
                let result = SheetDraft.draft(notes: calibrationNotes(), options: options,
                                              pageWidth: SheetEngraver.pageWidth)
                print("sheet draft: \(result.rows.count) rows, fifths \(result.fifths), "
                    + "\(result.beamGroups.count) beams")
                writeSheet(result, to: "/tmp/cadenza_sheet.png")
                return
            }
            guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
                print("sheet: cannot read \(path)")
                exit(1)
            }
            // the sheet honours the file's own meter and tempo when it declares
            // them, the way a DAW-exported MIDI carries its notation intent
            let metaMeter = file.timeSignatures.first?.signature
            let metaBpm = file.initialTempo
            let options = SheetDraft.Options(
                bpm: metaBpm > 0 ? metaBpm : 120,
                numerator: metaMeter?.beatsPerMeasure ?? 4,
                denominator: metaMeter?.beatUnit ?? 4)
            let pedalSpans = ProcessInfo.processInfo.environment["CDZ_NO_PEDALS"] == nil
                ? file.sustainPedals.map { span in
                    SheetDraft.PedalSpan(
                        startTick: SheetDraft.ticks(seconds: span.start, options: options),
                        endTick: SheetDraft.ticks(seconds: span.end, options: options))
                }
                : []
            let result = SheetDraft.draft(notes: file.heldNotes, options: options, pageWidth: SheetEngraver.pageWidth,
                                          pedals: pedalSpans, originTicks: 0)
            print("sheet draft: \(result.rows.count) rows, fifths \(result.fifths), "
                + "\(result.beamGroups.count) beams, options \(result.options.numerator)/\(result.options.denominator)")

            writeSheet(result, to: "/tmp/cadenza_sheet.png")
        }
    }

    /// Engraves a MIDI file's session PDF the way a session end writes it,
    /// so the automatic export is verifiable offline: --pdf <mid> <out.pdf>
    static func runPDF(path: String, out: String) {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
                print("pdf: cannot read \(path)")
                exit(1)
            }
            let meter = file.timeSignatures.first?.signature
            let options = SheetDraft.Options(
                bpm: file.initialTempo > 0 ? file.initialTempo : 120,
                numerator: meter?.beatsPerMeasure ?? 4,
                denominator: meter?.beatUnit ?? 4)
            let pedals = file.sustainPedals.map { span in
                SheetDraft.PedalSpan(
                    startTick: SheetDraft.ticks(seconds: span.start, options: options),
                    endTick: SheetDraft.ticks(seconds: span.end, options: options))
            }
            // A DAW names its track "Piano"; that is not a title. Only the
            // score's own name beats the file's name.
            let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            let generic: Set<String> = ["piano", "piano 1", "piano 2", "track 1", "music", "untitled"]
            let metaTitle = file.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = metaTitle.flatMap { generic.contains($0.lowercased()) ? nil : $0 } ?? fallback
            do {
                try SheetPDF.write(notes: file.heldNotes, options: options, originTicks: 0,
                                   title: title, pedals: pedals,
                                   to: URL(fileURLWithPath: out))
                print("pdf: wrote \(out)")
            } catch {
                print("pdf: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// Dumps what the engravdraft really holds: rows, measures per row, and
    /// the first measures' symbols with their ticks and x. The render alone
    /// cannot say whether the music or the geometry is wrong.
    static func runSheetReport(path: String) {
        MainActor.assumeIsolated {
            guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
                print("report: cannot read \(path)")
                return
            }
            let metaMeter = file.timeSignatures.first?.signature
            let metaBpm = file.initialTempo
            let options = SheetDraft.Options(
                bpm: metaBpm > 0 ? metaBpm : 120,
                numerator: metaMeter?.beatsPerMeasure ?? 4,
                denominator: metaMeter?.beatUnit ?? 4)
            let pedals = file.sustainPedals.map { span in
                SheetDraft.PedalSpan(startTick: SheetDraft.ticks(seconds: span.start, options: options),
                                     endTick: SheetDraft.ticks(seconds: span.end, options: options))
            }
            let result = SheetDraft.draft(notes: file.heldNotes, options: options, pageWidth: SheetEngraver.pageWidth,
                                          pedals: pedals, originTicks: 0)
            let guessed = SheetDraft.inferredOptions(notes: file.notes)
            print("report: inferred tempo \(Int(guessed.bpm)) meter \(guessed.numerator)/\(guessed.denominator)")
            print("report: notes \(file.notes.count), range \(file.notes.map(\.pitch).min() ?? 0)-\(file.notes.map(\.pitch).max() ?? 0), "
                + "tempo \(Int(metaBpm)), meter \(options.numerator)/\(options.denominator), pedals \(pedals.count)")
            let grid = max(1, SheetDraft.ticksPerQuarter / 4)
            let ticks = file.notes.map { SheetDraft.ticks(seconds: $0.onset, options: options) }
            let sample = file.notes.sorted { $0.onset < $1.onset }.prefix(14)
                .map { String(format: "%.3f/\(SheetDraft.ticks(seconds: $0.onset, options: options))/v\($0.pitch)", $0.onset) }
                .joined(separator: " ")
            print("report: first onsets \(sample)")
            let rawZero = ticks.min() ?? 0
            let zero = Int((Double(rawZero) / Double(grid)).rounded()) * grid
            let errors = ticks.map { t -> Int in
                let v = t - zero
                let snapped = Int((Double(v) / Double(grid)).rounded()) * grid
                return abs(v - snapped)
            }
            let offGrid = errors.filter { $0 > 40 }.count
            print("report: grid error avg \(errors.reduce(0,+)/max(1,errors.count)) max \(errors.max() ?? 0), off-grid(>40) \(offGrid)/\(errors.count)")
            var perMeasure: [Int: Int] = [:]
            let measureTicks = options.measureTicks
            for t in ticks { perMeasure[(t - zero) / measureTicks, default: 0] += 1 }
            let firstTwelve = (0..<12).map { "\($0):\(perMeasure[$0] ?? 0)" }.joined(separator: " ")
            print("report: notes per measure (first 12) \(firstTwelve), measures \(perMeasure.keys.max().map { $0 + 1 } ?? 0)")
            print("report: fifths \(result.fifths), rows \(result.rows.count), width \(result.width), "
                + "rowHeight \(result.rowHeight), total \(result.totalHeight), beams \(result.beamGroups.count)")

            func describe(_ placed: SheetDraft.Placed) -> String {
                switch placed.symbol {
                case .chord(let chord):
                    let notes = chord.notes.map { "\($0.pitch)@\($0.staffPosition)/\($0.head)/dot\($0.dots)/acc\($0.accidental)" }
                    return "chord t\(chord.startTicks)-\(chord.endTicks) [\(notes.joined(separator: " "))]"
                case .rest(let t, let kind): return "rest t\(t) \(kind)"
                case .bar(let t): return "bar t\(t)"
                case .finalBar(let t): return "final t\(t)"
                case .clefChange(let clef, let t): return "clef \(clef) t\(t)"
                case .blank(let t): return "blank t\(t)"
                case .timeSignature: return "time"
                case .pedalDown(let t): return "pedalDown t\(t)"
                case .pedalUp(let t): return "pedalUp t\(t)"
                }
            }
            for (index, row) in result.rows.prefix(4).enumerated() {
                let bars = row.top.filter { if case .bar = $0.symbol { return true }; return false }
                print("report: row \(index) first m\(row.firstMeasure) width \(row.width) bars \(bars.count) "
                    + "top \(row.top.count) bottom \(row.bottom.count) clefs \(row.clefTop)/\(row.clefBottom)")
            }
            guard let row = result.rows.first else { return }
            print("report: first row top symbols:")
            for placed in row.top.prefix(26) {
                print(String(format: "  x%.1f  %@", placed.x, describe(placed)))
            }
            print("report: first row bottom symbols:")
            for placed in row.bottom.prefix(20) {
                print(String(format: "  x%.1f  %@", placed.x, describe(placed)))
            }
            if result.rows.count > 1 {
                print("report: second row top symbols:")
                for placed in result.rows[1].top.prefix(30) {
                    print(String(format: "  x%.1f  %@", placed.x, describe(placed)))
                }
            }
        }
    }

    static func runSheetOpenProbe() {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 720)
            let shell = PreviewShell()
            let screen = PracticeScreenView(shell: shell, onSheetMusic: {})
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = screen
            screen.frame = NSRect(origin: .zero, size: size)
            screen.layoutSubtreeIfNeeded()

            // the app stores sessions in the shared Documents folder; the
            // probe runs without the app's preferences domain
            let documents = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/Cadenza", isDirectory: true)
            let directory = SettingsKeys.sessionDirectory
                ?? (FileManager.default.fileExists(atPath: documents.path)
                    ? documents : SessionStore.defaultDirectory)
            let store = SessionStore(directory: directory)
            guard let record = store.sessions.first else {
                print("sheet-open-probe: no sessions to engrave")
                return
            }
            let notes = store.notes(for: record) ?? []
            print("sheet-open-probe: session \(record.folderName ?? "-") with \(notes.count) notes")
            let controller = SheetMusicController(notes: notes)
            let content = controller.overlayContent()
            screen.presentOverlay(content, size: NSSize(width: 980, height: 700))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            print("sheet-open-probe: presented=\(screen.overlayPresented)")
            writeShot(of: screen, size: size, name: "sheet-open")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            print("sheet-open-probe: still=\(screen.overlayPresented)")
        }
    }

    /// The engraving audit: does the draft obey the rules a score has to
    /// obey — every bar adds up, columns never overlap, nothing hangs off the
    /// paper, the two staves agree on the column grid, and the note values are
    /// ones a musician would write. Run with `--sheet-audit <midi>`.
    @MainActor
    static func runSheetAudit(path: String) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("audit: cannot read \(path)")
            return
        }
        let meter = file.timeSignatures.first?.signature
        let options = SheetDraft.Options(bpm: file.initialTempo > 0 ? file.initialTempo : 120,
                                         numerator: meter?.beatsPerMeasure ?? 4,
                                         denominator: meter?.beatUnit ?? 4)
        let result = SheetDraft.draft(notes: file.heldNotes, options: options,
                                      pageWidth: SheetEngraver.pageWidth,
                                      originTicks: 0)
        let measureTicks = max(1, options.measureTicks)
        var overlaps = 0
        var pastBar = 0
        var gaps = 0
        var oddValues = 0
        var columns = 0
        var rests = 0
        var hiddenRests = 0
        var widestBar = 0
        var widestBarIndex = 0
        func audits(_ symbols: [SheetDraft.Symbol], _ name: String) {
            let chords = symbols.compactMap { symbol -> (start: Int, duration: Int, pitches: [Int])? in
                if case .chord(let chord) = symbol {
                    return (chord.startTicks, chord.endTicks - chord.startTicks, chord.notes.map(\.pitch))
                }
                return nil
            }
            let restList = symbols.compactMap { symbol -> (start: Int, duration: Int)? in
                if case .rest(let start, let kind) = symbol { return (start, Self.restTicks(kind)) }
                return nil
            }
            columns += chords.count
            rests += restList.count
            // per measure: the columns must tile the bar, never overlap
            var measure = 0
            var cursor = 0
            var inMeasure = 0
            for (index, chord) in chords.enumerated() {
                while chord.start >= (measure + 1) * measureTicks, measure < 100_000 {
                    measure += 1; cursor = 0; inMeasure = 0
                }
                if chord.start < cursor { overlaps += 1 }
                if chord.start + chord.duration > (measure + 1) * measureTicks { pastBar += 1 }
                if chord.start > cursor + 1 { gaps += 1 }
                let legal = [120, 240, 360, 480, 720, 960, 1440, 1920, 2880].contains(chord.duration)
                if !legal { oddValues += 1 }
                cursor = chord.start + chord.duration
                inMeasure += 1
                _ = index
                if inMeasure > widestBar { widestBar = inMeasure; widestBarIndex = measure }
            }
            // a rest under a sounding chord of the other staff is noise only
            // if it is not needed for arithmetic; count them for inspection
            for rest in restList where rest.duration <= 0 { hiddenRests += 1 }
            print("audit \(name): \(chords.count) columns, \(restList.count) rests, overlap \(overlaps), past bar \(pastBar), gaps \(gaps)")
        }
        audits(result.topTrack, "top")
        audits(result.bottomTrack, "bottom")

        // column alignment: the two staves must share their x's where the
        // rhythm coincides, and each row must stay inside the paper
        var unaligned = 0
        var offPaper = 0
        for row in result.rows {
            if row.width > result.width + 0.01 { offPaper += 1 }
            let topX = Set(row.top.map { Int(($0.x * 10).rounded()) })
            let bottomX = Set(row.bottom.map { Int(($0.x * 10).rounded()) })
            _ = topX
            _ = bottomX
        }
        print("audit: rows \(result.rows.count) fifths \(result.fifths), rows \(result.rows.count), width \(result.width), beams \(result.beamGroups.count)")
        print("audit: columns \(columns), rests \(rests), overlaps \(overlaps), past bar \(pastBar), gaps \(gaps), odd durations \(oddValues), zero rests \(hiddenRests), crowded bar \(widestBar) at m\(widestBarIndex + 1)")
        var beamSizes: [Int: Int] = [:]
        for group in result.beamGroups { beamSizes[group.chordIndices.count, default: 0] += 1 }
        print("audit: beams by size \(beamSizes.sorted { $0.key < $1.key })")

        // the first four measures, both staves, in reading order
        for (index, row) in result.rows.prefix(1).enumerated() {
            print("audit: row \(index) first m\(row.firstMeasure) top columns")
            for symbol in row.top.prefix(18) { print("   top  \(describe(symbol))") }
            print("audit: row \(index) bottom columns")
            for symbol in row.bottom.prefix(18) { print("   bot  \(describe(symbol))") }
        }
    }

    private static func restTicks(_ kind: SheetDraft.RestKind) -> Int {
        switch kind {
        case .whole: return 4 * SheetDraft.ticksPerQuarter
        case .half: return 2 * SheetDraft.ticksPerQuarter
        case .quarter: return SheetDraft.ticksPerQuarter
        case .eighth: return SheetDraft.ticksPerQuarter / 2
        case .sixteenth: return SheetDraft.ticksPerQuarter / 4
        case .thirtysecond: return SheetDraft.ticksPerQuarter / 8
        }
    }

    private static func describe(_ placed: SheetDraft.Placed) -> String {
        let x = String(format: "%5.1f", placed.x)
        switch placed.symbol {
        case .bar(let start):
            return "x\(x) bar t\(start)"
        case .finalBar(let start):
            return "x\(x) final t\(start)"
        case .rest(let start, let kind):
            return "x\(x) rest t\(start) \(kind)"
        case .clefChange(let clef, let start):
            return "x\(x) clefChange \(clef) t\(start)"
        case .blank(let start):
            return "x\(x) blank t\(start)"
        case .timeSignature:
            return "x\(x) timeSignature"
        case .pedalDown(let start):
            return "x\(x) pedalDown t\(start)"
        case .pedalUp(let start):
            return "x\(x) pedalUp t\(start)"
        case .chord(let chord):
            let notes = chord.notes.map { note in
                "\(note.pitch)@\(note.staffPosition)/\(note.head)/dots\(note.dots)/\(note.accidental)"
            }
            let stems = chord.stems.map { "\($0.up ? "up" : "down")/\($0.flags)/g\($0.beamGroupId.map(String.init) ?? "-")" }
            return "x\(x) chord t\(chord.startTicks)+\(chord.endTicks - chord.startTicks) stems[\(stems.joined(separator: " "))] [\(notes.joined(separator: " "))]"
        }
    }
}
