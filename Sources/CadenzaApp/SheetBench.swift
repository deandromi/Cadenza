import AppKit
import CadenzaCore
import Foundation
import QuartzCore

/// Times the engraver on the shapes a live take actually produces: dense
/// chords, long held notes, fast runs, overlapping tails and thousands of
/// events. Run with `--draft-bench`; the case name prints before it runs, so
/// a hang names itself.
@MainActor
enum SheetBench {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let cases: [(String, [NoteEvent])] = [
            ("one note", [NoteEvent(pitch: 60, velocity: 80, onset: 0, duration: 0.5)]),
            ("ten-note cluster, 30 s", cluster(count: 10, onset: 0, duration: 30)),
            ("fast 16ths, 500 notes", run(count: 500, step: 0.0625, duration: 0.05)),
            ("chords every 0.25 s", chords(count: 100, size: 6)),
            ("overlapping arpeggios", arpeggios(count: 400)),
            ("duplicate pitches", duplicates()),
            ("random 3000 notes", random(count: 3000, duration: (0.05, 20))),
            ("random 3000, long tails", random(count: 3000, duration: (4, 30))),
            ("pedal-like overlap", run(count: 600, step: 0.08, duration: 8)),
            ("tiny durations", run(count: 400, step: 0.2, duration: 0.002)),
            ("5000 notes", random(count: 5000, duration: (0.05, 10))),
            ("whole-keyboard sweep", sweep(count: 800)),
        ]
        for options in [SheetDraft.Options(), SheetDraft.Options(numerator: 3, denominator: 4)] {
            print("— meter \(options.numerator)/\(options.denominator)")
            for (name, notes) in cases {
                print("  \(name) … ", terminator: "")
                let began = CACurrentMediaTime()
                let result = SheetDraft.draft(notes: notes, options: options, pageWidth: SheetEngraver.pageWidth)
                let milliseconds = (CACurrentMediaTime() - began) * 1000
                print(String(format: "%.0f ms, %d rows, %d symbols, %d beams",
                             milliseconds, result.rows.count,
                             result.topTrack.count + result.bottomTrack.count,
                             result.beamGroups.count))
            }
        }
    }

    /// Opens the real sheet window the way the menu does, waits for layout,
    /// and reports what actually landed on paper: the size of the scroll
    /// container, the engraved view, and the ink it drew. `--sheet-window-probe`
    static func windowProbe() {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        MusicFont.register()
        var notes: [NoteEvent] = []
        for index in 0..<120 {
            let onset = Double(index) * 0.4
            notes.append(NoteEvent(pitch: 60 + index % 12, velocity: 80, onset: onset, duration: 0.5))
            if index % 4 == 0 {
                notes.append(NoteEvent(pitch: 48 + index % 7, velocity: 70, onset: onset, duration: 0.9))
            }
        }
        let controller = SheetMusicController(notes: notes)
        controller.show(relativeTo: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        guard let window = NSApp.windows.first(where: { $0.title == "Sheet music" }),
              let root = window.contentView else {
            print("sheet-window-probe: no window")
            return
        }
        func describe(_ view: NSView, label: String, depth: Int = 0) {
            print(String(format: "  %@ %@ frame %.0fx%.0f bounds %.0fx%.0f",
                         String(repeating: " ", count: depth) as NSString,
                         label as NSString,
                         view.frame.width, view.frame.height,
                         view.bounds.width, view.bounds.height))
        }
        print("sheet-window-probe: window \(Int(window.frame.width))x\(Int(window.frame.height))")
        describe(root, label: "root")
        for subview in root.subviews {
            describe(subview, label: String(describing: type(of: subview)), depth: 1)
            for nested in subview.subviews.prefix(3) {
                describe(nested, label: String(describing: type(of: nested)), depth: 2)
            }
        }

        print(String(format: "sheet-window-probe: ink %.2f%% of the window", inkFraction(root)))

        // closing and reopening must not leave a dangling window behind
        window.close()
        controller.show(relativeTo: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("sheet-window-probe: reopened after close")

        // a long take: the live sheet redrafts the whole performance every
        // quarter second, so the cost of one redraft is the difference
        // between a flowing sheet and a frozen window
        var long: [NoteEvent] = []
        for index in 0..<1500 {
            let onset = Double(index) * 0.18
            long.append(NoteEvent(pitch: 40 + (index * 5) % 40, velocity: 80, onset: onset, duration: 0.45))
            if index % 3 == 0 {
                long.append(NoteEvent(pitch: 55 + index % 20, velocity: 70, onset: onset, duration: 1.1))
            }
        }
        let heavy = SheetMusicController(notes: long)
        let showBegan = CACurrentMediaTime()
        heavy.show(relativeTo: nil)
        let showMilliseconds = (CACurrentMediaTime() - showBegan) * 1000
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        for candidate in NSApp.windows {
            print(String(format: "  window %@ %dx%d ink %.2f%%",
                         candidate.title as NSString,
                         Int(candidate.frame.width), Int(candidate.frame.height),
                         candidate.contentView.map(inkFraction) ?? 0))
        }
        let heavyWindow = NSApp.windows.last { $0.title == "Sheet music" }
        let drawBegan = CACurrentMediaTime()
        if let heavyRoot = heavyWindow?.contentView, let heavyRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(heavyRoot.bounds.width), pixelsHigh: Int(heavyRoot.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            heavyRoot.cacheDisplay(in: heavyRoot.bounds, to: heavyRep)
        }
        let drawMilliseconds = (CACurrentMediaTime() - drawBegan) * 1000
        print(String(format: "sheet-window-probe: 2000 notes: show+engrave %.0f ms, draw %.0f ms",
                     showMilliseconds, drawMilliseconds))

        // the live path: one redraft of the whole take, as the engine feeds it
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var grown = long
        for index in 0..<200 {
            grown.append(NoteEvent(pitch: 45 + index % 30, velocity: 80,
                                   onset: Double(1500 + index) * 0.18, duration: 0.5))
        }
        let syncBegan = CACurrentMediaTime()
        heavy.sync(notes: grown)
        let syncMilliseconds = (CACurrentMediaTime() - syncBegan) * 1000
        print(String(format: "sheet-window-probe: live redraft of %d notes: %.0f ms, ink %.2f%%",
                     grown.count, syncMilliseconds,
                     heavyWindow?.contentView.map(inkFraction) ?? 0))
    }

    /// Share of the view's pixels that are not paper: a blank sheet reads
    /// near zero, an engraved one in the low teens.
    private static func inkFraction(_ view: NSView) -> Double {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return 0 }
        var ink = 0
        let stride = rep.bitsPerPixel / 8
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * stride
                let brightness = Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
                if brightness < 600 { ink += 1 }
            }
        }
        return Double(ink) / Double(max(rep.pixelsWide * rep.pixelsHigh, 1)) * 100
    }

    private static func cluster(count: Int, onset: Double, duration: Double) -> [NoteEvent] {
        (0..<count).map { index in
            NoteEvent(pitch: 48 + index * 2, velocity: 80, onset: onset, duration: duration)
        }
    }

    private static func run(count: Int, step: Double, duration: Double) -> [NoteEvent] {
        (0..<count).map { index in
            NoteEvent(pitch: 60 + (index * 5) % 24, velocity: 80,
                      onset: Double(index) * step, duration: duration)
        }
    }

    private static func chords(count: Int, size: Int) -> [NoteEvent] {
        var notes: [NoteEvent] = []
        for index in 0..<count {
            let onset = Double(index) * 0.25
            for voice in 0..<size {
                notes.append(NoteEvent(pitch: 40 + voice * 5, velocity: 80, onset: onset, duration: 0.9))
            }
        }
        return notes
    }

    private static func arpeggios(count: Int) -> [NoteEvent] {
        (0..<count).map { index in
            NoteEvent(pitch: 48 + (index % 12) * 2, velocity: 80,
                      onset: Double(index) * 0.11, duration: 2.5)
        }
    }

    private static func duplicates() -> [NoteEvent] {
        var notes: [NoteEvent] = []
        for index in 0..<200 {
            for _ in 0..<4 {
                notes.append(NoteEvent(pitch: 60, velocity: 80,
                                       onset: Double(index) * 0.5, duration: 2.0))
            }
        }
        return notes
    }

    private static func random(count: Int, duration: (Double, Double)) -> [NoteEvent] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            NoteEvent(pitch: Int.random(in: 21...108, using: &generator),
                      velocity: Int.random(in: 20...120, using: &generator),
                      onset: Double.random(in: 0...120, using: &generator),
                      duration: Double.random(in: duration.0...duration.1, using: &generator))
        }
    }

    private static func sweep(count: Int) -> [NoteEvent] {
        (0..<count).map { index in
            NoteEvent(pitch: 21 + index % 88, velocity: 80,
                      onset: Double(index) * 0.15, duration: 0.6)
        }
    }
}
