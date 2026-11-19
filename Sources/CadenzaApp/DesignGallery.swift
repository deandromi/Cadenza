import AppKit
import ScreenCaptureKit

/// The design gallery: one inspectable draft of the practice screen running a
/// simulated session. Launch with `--designs`; add `--designs-shot` to print
/// a layout report with pixel probes and exit instead of staying open.
///
/// The drafts' building blocks live in PaperChrome.swift, shared with the
/// real practice screen: this gallery feeds them a simulated transport so the
/// approved composition stays inspectable while the app moves on.
@MainActor
final class DesignGalleryController: NSObject, NSApplicationDelegate {
    private let clock = DesignSessionClock()
    private var window: NSWindow?
    private var draft: KeyboardBloomDraft?
    private var practiceScreen: PracticeScreenView?
    /// ink rectangles of whichever screen the gallery is showing; the
    /// practice variant is the real screen the app ships
    private var inkRectsProvider: (() -> [(String, NSRect)])?

    /// The gallery builds inside applicationDidFinishLaunching, the same
    /// lifecycle the working main app uses: a window built before the run
    /// loop starts never joins the live layout engine, and its nested
    /// views stay at zero frames forever.
    func applicationDidFinishLaunching(_ notification: Notification) {
        openGallery()
    }

    /// Assembles the window and starts the simulated session; called from
    /// applicationDidFinishLaunching once the run loop owns the app. With
    /// `--practice` the window shows the real practice screen at rest
    /// instead, so the live capture report can prove the shipped UI.
    func openGallery() {
        // the gallery is a paper world: it always renders in light mode,
        // whatever the system prefers
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        let practiceMode = CommandLine.arguments.contains("--practice")
        let content: NSView
        if practiceMode {
            let screen = PracticeScreenView(transport: PanelTransport(
                isListening: { false },
                toggleListening: {},
                exportEnabled: { false },
                export: {}
            ))
            practiceScreen = screen
            content = screen
            inkRectsProvider = { [weak screen] in screen?.inkRects() ?? [] }
        } else {
            let newDraft = KeyboardBloomDraft(clock: clock)
            draft = newDraft
            content = newDraft
            inkRectsProvider = { [weak newDraft] in newDraft?.inkRects() ?? [] }
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 120, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = practiceMode ? "Practice screen" : "Design draft"
        newWindow.minSize = NSSize(width: 900, height: 620)
        newWindow.center()
        // the window's content is a frame-driven root with autoresizing,
        // exactly like the working main app: a constraint-pinned content
        // view breaks the deeper layout passes on this OS build
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        root.autoresizingMask = [.width, .height]
        newWindow.contentView = root
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window = newWindow
        window?.makeKeyAndOrderFront(nil)
        print("[designs] \(practiceMode ? "practice screen" : "draft") window opened")
        fflush(stdout)

        if !practiceMode {
            clock.onUpdate = { [weak self] moment in
                self?.draft?.handle(moment)
            }
            clock.start()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--designs-shot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.shoot()
            }
        }
        print("[designs] session clock started, gallery running")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Probes inside the panel where label and button ink should be.
    private func draftingPanelContentProbes() -> [KeyboardBloomDraft.PixelProbe] {
        [
            KeyboardBloomDraft.PixelProbe(label: "panel caption row", point: NSPoint(x: 838, y: 470)),
            KeyboardBloomDraft.PixelProbe(label: "panel time digits", point: NSPoint(x: 840, y: 440)),
            KeyboardBloomDraft.PixelProbe(label: "panel level line", point: NSPoint(x: 940, y: 360)),
            KeyboardBloomDraft.PixelProbe(label: "panel buttons row", point: NSPoint(x: 845, y: 292)),
            KeyboardBloomDraft.PixelProbe(label: "menu buttons", point: NSPoint(x: 992, y: 680)),
            KeyboardBloomDraft.PixelProbe(label: "bloom staff wash", point: NSPoint(x: 260, y: 380)),
        ]
    }

    /// Layout report plus pixel probes over the captured draft, written to
    /// the gallery log. Nothing is trusted until the pixels say so: the
    /// cacheDisplay bitmap proves geometry, the live capture proves ink.
    private func shoot() {
        print("[shot] --- layout report ---")
        if let theWindow = window {
            print("[shot] window frame \(theWindow.frame)")
            if let content = theWindow.contentView {
                print("[shot] content view frame \(content.frame)")
            }
        }
        if let theDraft = draft {
            theDraft.reportLayout()
        }
        if let practiceScreen {
            print("[shot] practice screen bounds \(practiceScreen.bounds)")
        }
        guard let contentView = window?.contentView else {
            print("[shot] no content view")
            fflush(stdout)
            exit(0)
        }
        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("[shot] no bitmap")
            fflush(stdout)
            exit(0)
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/cadenza_draft.png"))
            print("[shot] png written to /tmp/cadenza_draft.png (\(png.count) bytes)")
        }
        /// view coordinates are bottom-up, bitmap rows run top-down
        func sample(_ point: NSPoint) -> String {
            let x = Int(point.x)
            let y = Int(bitmap.pixelsHigh) - 1 - Int(point.y)
            if x < 0 || y < 0 || x >= Int(bitmap.pixelsWide) || y >= Int(bitmap.pixelsHigh) {
                return "out of bounds"
            }
            guard let color = bitmap.colorAt(x: x, y: y) else { return "no color" }
            return String(
                format: "(%.3f %.3f %.3f)",
                color.redComponent, color.greenComponent, color.blueComponent
            )
        }
        print("[shot] paper reference at (60, 640): \(sample(NSPoint(x: 60, y: 640)))")
        if let theDraft = draft {
            for probe in draftingPanelContentProbes() {
                print("[shot] probe \(probe.label) at \(Int(probe.point.x)),\(Int(probe.point.y)): \(sample(probe.point))")
            }
            for probe in theDraft.pixelProbes() {
                print("[shot] probe \(probe.label) at \(Int(probe.point.x)),\(Int(probe.point.y)): \(sample(probe.point))")
            }
        }
        for (name, rect) in inkRectsProvider?() ?? [] {
            print("[shot] ink \(name) rect \(rect), darkest \(darkestPixel(in: rect, bitmap: bitmap))")
        }
        liveCaptureReport()
    }

    /// Scans a rect in view coordinates for the darkest pixel, reporting
    /// its luminance: text ink reads near 0.2, empty paper near 0.95.
    private func darkestPixel(in rect: NSRect, bitmap: NSBitmapImageRep) -> String {
        let minX = max(0, Int(rect.minX))
        let maxX = min(Int(bitmap.pixelsWide) - 1, Int(rect.maxX))
        let minY = max(0, bitmap.pixelsHigh - 1 - Int(rect.maxY))
        let maxY = min(Int(bitmap.pixelsHigh) - 1, bitmap.pixelsHigh - 1 - Int(rect.minY))
        guard minX <= maxX, minY <= maxY else { return "out of bounds" }
        var darkest = 1.0
        for x in minX...maxX {
            for y in minY...maxY {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let luminance = 0.299 * color.redComponent
                    + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                darkest = min(darkest, luminance)
            }
        }
        return String(format: "%.3f", darkest)
    }

    /// Captures this app's own window through the window server and scans
    /// the ink rectangles there. The cacheDisplay bitmap above never paints
    /// text fields into its pixels, so only the live compositor proves the
    /// panel's ink and the glass lenses actually reach the screen. The
    /// ScreenCaptureKit calls carry only values, so nothing main-actor
    /// crosses a boundary; the whole shot exits when the scan is done.
    private func liveCaptureReport() {
        let windowNumber = window?.windowNumber ?? 0
        var regions: [(String, NSRect)] = [
            ("paper reference", NSRect(x: 320, y: 640, width: 60, height: 20))
        ]
        regions.append(contentsOf: inkRectsProvider?() ?? [])
        // the capture is taken of the window alone, at native backing scale,
        // so glyph strokes land as real pixels instead of smear
        let frame = window?.frame ?? .zero
        let backing = Double(window?.screen?.backingScaleFactor ?? 2)
        Task { [windowNumber, regions, frame, backing] in
            guard let content = try? await SCShareableContent.currentProcess else {
                print("[shot] live capture listing failed")
                exitShot()
                return
            }
            guard let own = content.windows.first(where: { $0.windowID == windowNumber }) else {
                print("[shot] live capture: own window missing from the window list")
                exitShot()
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: 0, y: 0, width: frame.width, height: frame.height
            )
            configuration.width = Int(frame.width * backing)
            configuration.height = Int(frame.height * backing)
            configuration.scalesToFit = true
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) else {
                print("[shot] live capture image failed")
                exitShot()
                return
            }
            scanLiveFrame(image, regions: regions, windowFrame: frame)
            exitShot()
        }
    }
}

/// Ends the shot from whatever queue the capture landed on, once every
/// report line is printed.
private func exitShot() {
    print("[shot] --- end ---")
    fflush(stdout)
    exit(0)
}

/// Scans the live compositor image for the darkest pixel inside each
/// rectangle: ink reads near 0.2, empty paper near 0.95. The capture holds
/// the window alone, captured at backing scale, in top-left order: 32
/// points of title bar above the 720-point content, the view rectangles
/// bottom-up inside that content.
private func scanLiveFrame(
    _ image: CGImage,
    regions: [(String, NSRect)],
    windowFrame: NSRect
) {
    let width = image.width
    let height = image.height
    guard width > 0, windowFrame.width > 0 else { return }
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("[shot] live capture context failed")
        return
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else {
        print("[shot] live capture buffer missing")
        return
    }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    func luminance(column: Int, row: Int) -> Double {
        let offset = (row * width + column) * 4
        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    // pixels per point between the window and the capture
    let scale = Double(width) / windowFrame.width

    print("[shot] live capture \(width)x\(height) at scale \(String(format: "%.2f", scale))")

    func rowRange(of rect: NSRect) -> ClosedRange<Int> {
        let top = (32.0 + 720.0 - rect.maxY) * scale
        let bottom = (32.0 + 720.0 - rect.minY) * scale
        let clampedTop = max(0, Int(top))
        let clampedBottom = min(height - 1, Int(bottom))
        return clampedTop...max(clampedTop, clampedBottom)
    }

    func columnRange(of rect: NSRect) -> ClosedRange<Int> {
        let left = rect.minX * scale
        let right = rect.maxX * scale
        let clampedLeft = max(0, Int(left))
        let clampedRight = min(width - 1, Int(right))
        return clampedLeft...max(clampedLeft, clampedRight)
    }

    for (name, rect) in regions {
        var darkest = 1.0
        outer: for column in columnRange(of: rect) {
            for row in rowRange(of: rect) {
                darkest = min(darkest, luminance(column: column, row: row))
                if darkest < 0.05 { break outer }
            }
        }
        print(String(format: "[shot] live ink %@ darkest %.3f", name, darkest))
    }
    let pngURL = URL(fileURLWithPath: "/tmp/cadenza_live.png") as CFURL
    if let destination = CGImageDestinationCreateWithURL(pngURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("[shot] live png written to /tmp/cadenza_live.png")
        }
    }
}

/// The practice screen draft: the keybed along the bottom, musical notes
/// blooming in the left field while they sound, the control panel as a glass
/// lens at the right, the wordmark and a menu for future sections on top.
/// The draft is the window's content; the lenses sit far apart, so the glass
/// contract asks for no container and the window keeps its given size.
final class KeyboardBloomDraft: NSView {
    private let clock: DesignSessionClock
    private let keybed = KeybedView()
    private let bloom = NoteBloomView()
    private var panel: ControlPanelLens!
    private let menuLens = MenuLens()
    private let wordmark = makeInkLabel(
        "Cadenza",
        font: PaperTheme.displaySerif(27, weight: .semibold),
        color: PaperTheme.ink
    )
    private var wasSounding = false

    init(clock: DesignSessionClock) {
        self.clock = clock
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // the transport closures capture self, so the panel waits for the
        // run of super.init
        panel = ControlPanelLens(transport: PanelTransport(
            isListening: { [weak clock] in clock?.isRunning ?? false },
            toggleListening: { [weak self] in self?.toggleClock() },
            exportEnabled: { false },
            export: {}
        ))
        panel.syncTransport()

        let paper = PaperView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paper)
        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: trailingAnchor),
            paper.topAnchor.constraint(equalTo: topAnchor),
            paper.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addSubview(keybed)
        addSubview(bloom)

        wordmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordmark)
        let dot = StampDot()
        addSubview(dot)

        addSubview(panel)
        addSubview(menuLens)

        NSLayoutConstraint.activate([
            keybed.leadingAnchor.constraint(equalTo: leadingAnchor),
            keybed.trailingAnchor.constraint(equalTo: trailingAnchor),
            keybed.bottomAnchor.constraint(equalTo: bottomAnchor),
            keybed.heightAnchor.constraint(equalToConstant: 118),

            bloom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            bloom.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -40),
            bloom.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 8),
            bloom.bottomAnchor.constraint(equalTo: keybed.topAnchor, constant: -30),

            wordmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            wordmark.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            dot.leadingAnchor.constraint(equalTo: wordmark.trailingAnchor, constant: 7),
            dot.bottomAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: -6),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            // the two floating lenses carry explicit sizes at required
            // priority: intrinsic consultation proved unreliable here, so
            // geometry is pinned, never guessed
            menuLens.widthAnchor.constraint(equalToConstant: 75),
            menuLens.heightAnchor.constraint(equalToConstant: 40),
            menuLens.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            menuLens.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            panel.widthAnchor.constraint(equalToConstant: 240),
            panel.heightAnchor.constraint(equalToConstant: 251),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -26),

        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The simulated transport's listen toggle: pauses the clock and settles
    /// whatever was sounding, the way a stopped session should come to rest.
    private func toggleClock() {
        clock.toggleRunning()
        if !clock.isRunning {
            wasSounding = false
            keybed.soundingPitches = []
            bloom.releaseAll()
        }
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        panel.syncTransport()
        keybed.soundingPitches = moment.sounding ? Set(moment.pitches) : []
        if moment.sounding, !wasSounding {
            bloom.strike(pitches: moment.pitches, serial: moment.noteCount)
        }
        if !moment.sounding, wasSounding {
            bloom.releaseAll()
        }
        wasSounding = moment.sounding
        panel.setSession(
            time: sessionTimeString(moment.seconds),
            notes: "\(moment.noteCount) notes",
            level: moment.level,
            sounding: moment.sounding
        )
    }

    // MARK: shot diagnostics

    func reportLayout() {
        print("[shot] draft bounds \(bounds.width)x\(bounds.height)")
        print("[shot] draft fitting \(fittingSize)")
        subviews.forEach { child in
            print("[shot] child \(type(of: child)) frame \(child.frame), fitting \(child.fittingSize)")
        }
        print("[shot] keybed frame \(keybed.frame)")
        print("[shot] bloom frame \(bloom.frame)")
        print("[shot] wordmark frame \(wordmark.frame)")
        print("[shot] panel frame \(panel.frame), intrinsic \(panel.intrinsicContentSize)")
        print("[shot] menu frame \(menuLens.frame), intrinsic \(menuLens.intrinsicContentSize)")
        panel.reportLayout(prefix: "[shot] ")
    }

    struct PixelProbe {
        let label: String
        let point: NSPoint
    }

    /// Probes the panel and keybed regions inside draft coordinates.
    func pixelProbes() -> [PixelProbe] {
        let panelFrame = panel.frame
        let inset = min(panelFrame.width, panelFrame.height) / 4
        return [
            PixelProbe(label: "panel center", point: NSPoint(
                x: panelFrame.midX, y: panelFrame.midY
            )),
            PixelProbe(label: "panel inside corner", point: NSPoint(
                x: panelFrame.minX + inset, y: panelFrame.minY + inset
            )),
            PixelProbe(label: "keybed midway", point: NSPoint(
                x: bounds.width / 2, y: keybed.frame.midY
            )),
        ]
    }

    /// Live ink rectangles in draft coordinates: the panel's labels and
    /// buttons, plus the wordmark, straight from their laid-out frames.
    /// The shot scans these for the darkest pixel so ink presence is
    /// proven from real geometry, not from hand-picked points.
    func inkRects() -> [(String, NSRect)] {
        paperInkRects(panel: panel, wordmark: wordmark, in: self)
    }
}
