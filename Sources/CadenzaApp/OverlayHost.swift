import AppKit
import CadenzaCore
import QuartzCore

/// The app's motion vocabulary in one place: no screen animates with its own
/// invented curve or duration, so a panel, a sheet and a menu all settle the
/// same way.
@MainActor
enum Motion {
    /// Apple's out-quint: fast away from the finger, quiet at the end.
    static func settle(_ duration: CFTimeInterval = 0.32) -> CABasicAnimation {
        let animation = CABasicAnimation()
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        return animation
    }

    /// A short, slightly springy move for something that grew out of a click.
    static func spring(keyPath: String, from: Any, to: Any,
                       response: Double = 0.44, damping: Double = 0.82) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = 220
        animation.damping = CGFloat(damping) * 2 * sqrt(220)
        animation.duration = response
        animation.initialVelocity = 0
        return animation
    }

    /// The scale a surface grows from, and the opacity ramp that hides the
    /// first frames of it: 0.965 at the start reads as a lift, not a pop.
    static let growth: CGFloat = 0.965
}

/// Everything the app shows on top of the practice screen — the sheet, the
/// session archive, statistics, settings — lives here, inside the one window,
/// never in a window of its own.
///
/// The layer is "frozen glass": a snapshot of the screen as it was, held still,
/// gently pushed back and blurred by the native material on top of it, with a
/// dim that keeps the card readable. The music you were watching stays exactly
/// where it was, so opening a panel never loses your place.
@MainActor
final class OverlayHost: NSView {
    private let frozen = NSImageView()
    private let frozenGlass = NSVisualEffectView()
    private let dim = NSView()
    private let card = NSGlassEffectView()
    private let cardContent = NSView()
    private let closeLens: NSGlassEffectView
    private let closePill: NSStackView
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let escapeHint = makeInkLabel(
        "esc",
        font: .systemFont(ofSize: 10, weight: .medium),
        color: PaperTheme.secondaryInk
    )
    private var cardWidth: NSLayoutConstraint?
    private var cardHeight: NSLayoutConstraint?
    private var escapeMonitor: Any?
    private var onDismiss: (() -> Void)?
    private(set) var isPresented = false

    init() {
        closePill = padForLens(NSStackView(views: [closeButton, escapeHint]), horizontal: 14, vertical: 8)
        closeLens = makeGlassBackdrop(cornerRadius: 15, interactive: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        frozen.imageScaling = .scaleAxesIndependently
        frozen.wantsLayer = true
        frozen.layer?.transform = CATransform3DMakeScale(1.035, 1.035, 1)
        frozenGlass.material = .fullScreenUI
        frozenGlass.blendingMode = .withinWindow
        frozenGlass.state = .active
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        card.style = .regular
        card.cornerRadius = 26
        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.withAlphaComponent(0.30).cgColor
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = 44
        card.layer?.shadowOffset = CGSize(width: 0, height: -22)
        cardContent.wantsLayer = true
        cardContent.layer?.cornerRadius = 26
        cardContent.layer?.masksToBounds = true

        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.contentTintColor = PaperTheme.ink
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        for view in [frozen, frozenGlass, dim, card, closeLens, closePill] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // glass hosts its content through contentView: views added straight
        // to the effect view sit behind the material and never show
        card.contentView = cardContent
        cardContent.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            frozen.leadingAnchor.constraint(equalTo: leadingAnchor),
            frozen.trailingAnchor.constraint(equalTo: trailingAnchor),
            frozen.topAnchor.constraint(equalTo: topAnchor),
            frozen.bottomAnchor.constraint(equalTo: bottomAnchor),
            frozenGlass.leadingAnchor.constraint(equalTo: leadingAnchor),
            frozenGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
            frozenGlass.topAnchor.constraint(equalTo: topAnchor),
            frozenGlass.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            closePill.centerXAnchor.constraint(equalTo: centerXAnchor),
            closePill.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 14),
            closeLens.leadingAnchor.constraint(equalTo: closePill.leadingAnchor),
            closeLens.trailingAnchor.constraint(equalTo: closePill.trailingAnchor),
            closeLens.topAnchor.constraint(equalTo: closePill.topAnchor),
            closeLens.bottomAnchor.constraint(equalTo: closePill.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: presenting

    /// Shows `content` in the card on frozen glass. `size` is a wish: the card
    /// never grows past the window it lives in.
    func present(_ content: NSView, size: NSSize,
                 onDismiss: (() -> Void)? = nil) {
        guard window != nil else { return }
        if isPresented { dismiss(animated: false) }
        self.onDismiss = onDismiss

        freezeBackground()
        for view in cardContent.subviews { view.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            content.topAnchor.constraint(equalTo: cardContent.topAnchor),
            content.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),
        ])

        let limit = bounds.insetBy(dx: 40, dy: 40).size
        let width = max(320, min(size.width, limit.width))
        let height = max(240, min(size.height, limit.height))
        cardWidth?.isActive = false
        cardHeight?.isActive = false
        cardWidth = card.widthAnchor.constraint(equalToConstant: width)
        cardHeight = card.heightAnchor.constraint(equalToConstant: height)
        cardWidth?.isActive = true
        cardHeight?.isActive = true
        layoutSubtreeIfNeeded()

        isHidden = false
        isPresented = true
        installEscapeMonitor()
        card.layer?.removeAllAnimations()
        card.layer?.transform = CATransform3DMakeScale(Motion.growth, Motion.growth, 1)
        card.layer?.opacity = 0
        let move = Motion.spring(keyPath: "transform",
                                 from: NSValue(caTransform3D: CATransform3DMakeScale(Motion.growth, Motion.growth, 1)),
                                 to: NSValue(caTransform3D: CATransform3DIdentity))
        let fade = Motion.settle(0.22)
        fade.keyPath = "opacity"
        fade.fromValue = 0
        fade.toValue = 1
        card.layer?.add(move, forKey: "grow")
        card.layer?.add(fade, forKey: "fade")
        card.layer?.transform = CATransform3DIdentity
        card.layer?.opacity = 1

        // the room recedes while the card arrives: the frozen screen settles
        // back instead of just appearing behind a scrim
        frozen.layer?.removeAllAnimations()
        frozen.layer?.transform = CATransform3DIdentity
        let pushBack = Motion.settle(0.46)
        pushBack.keyPath = "transform"
        pushBack.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        pushBack.toValue = NSValue(caTransform3D: CATransform3DMakeScale(1.035, 1.035, 1))
        frozen.layer?.add(pushBack, forKey: "push")
        frozen.layer?.transform = CATransform3DMakeScale(1.035, 1.035, 1)

        let appear = Motion.settle(0.26)
        appear.keyPath = "opacity"
        appear.fromValue = 0
        appear.toValue = 1
        layer?.add(appear, forKey: "appear")
        alphaValue = 1
    }

    /// Swaps the card's content without moving the card: the archive after a
    /// rename, the sheet while notes keep landing.
    func replaceContent(_ content: NSView) {
        guard isPresented else { return }
        for view in cardContent.subviews { view.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            content.topAnchor.constraint(equalTo: cardContent.topAnchor),
            content.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),
        ])
    }

    func dismiss(animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        removeEscapeMonitor()
        let finish = { [weak self] in
            guard let self else { return }
            self.isHidden = true
            self.alphaValue = 0
            for view in self.cardContent.subviews { view.removeFromSuperview() }
            self.card.layer?.removeAllAnimations()
            self.card.layer?.transform = CATransform3DIdentity
            self.card.layer?.opacity = 1
            self.frozen.layer?.transform = CATransform3DMakeScale(1.035, 1.035, 1)
            let done = self.onDismiss
            self.onDismiss = nil
            done?()
        }
        guard animated else { finish(); return }
        let shrink = Motion.settle(0.20)
        shrink.keyPath = "transform"
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: CATransform3DMakeScale(0.985, 0.985, 1))
        card.layer?.add(shrink, forKey: "shrink")
        let fade = Motion.settle(0.18)
        fade.keyPath = "opacity"
        fade.fromValue = 1
        fade.toValue = 0
        layer?.add(fade, forKey: "disappear")
        alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: finish)
    }

    // MARK: frozen glass

    private func freezeBackground() {
        guard let source = superview, source.bounds.width > 1 else { return }
        guard let rep = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return }
        source.cacheDisplay(in: source.bounds, to: rep)
        let image = NSImage(size: source.bounds.size)
        image.addRepresentation(rep)
        frozen.image = image
    }

    // MARK: events

    /// A click anywhere on the frozen room closes the card, like clicking
    /// outside a sheet: the card itself keeps its own clicks.
    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isPresented else { return nil }
        return super.hitTest(point)
    }

    @objc private func closeTapped() {
        dismiss()
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
