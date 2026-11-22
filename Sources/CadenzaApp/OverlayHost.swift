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
/// The layer is one glass family floating over the live screen: the card and
/// the close pill are lenses in a single container, so they sample and react
/// to each other the way system glass does. Nothing is painted behind them —
/// no snapshot, no scrim, no shadow — because the practice screen is already
/// there, and its paper and notation are what the lens refracts. The music you
/// were watching stays exactly where it was, so opening a panel never loses
/// your place.
@MainActor
final class OverlayHost: NSView {
    /// one container: the card and the close pill are a single glass family
    private let family = NSGlassEffectContainerView()
    private let familyHost = NSView()
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
    /// Bumped by every present and dismiss. A dismiss that is still animating
    /// when the next section opens must not finish on top of it: it used to
    /// clear the new card, which is how opening a sheet from the archive
    /// closed the sheet again.
    private var transitionID = 0

    init() {
        closePill = padForLens(NSStackView(views: [closeButton, escapeHint]), horizontal: 14, vertical: 8)
        closeLens = makeGlassLens(closePill, cornerRadius: 15, interactive: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        card.style = .regular
        card.cornerRadius = LensRadius.card
        // the card holds controls, so its glass reacts to them
        setGlassInteractive(card, true)
        cardContent.wantsLayer = true
        cardContent.layer?.cornerRadius = LensRadius.card
        cardContent.layer?.masksToBounds = true

        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.contentTintColor = PaperTheme.ink
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        family.translatesAutoresizingMaskIntoConstraints = false
        familyHost.translatesAutoresizingMaskIntoConstraints = false
        family.contentView = familyHost
        addSubview(family)
        for view in [card, closeLens] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            familyHost.addSubview(view)
        }
        // glass hosts its content through contentView: views added straight
        // to the effect view sit behind the material and never show
        card.contentView = cardContent
        cardContent.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            family.leadingAnchor.constraint(equalTo: leadingAnchor),
            family.trailingAnchor.constraint(equalTo: trailingAnchor),
            family.topAnchor.constraint(equalTo: topAnchor),
            family.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: familyHost.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: familyHost.centerYAnchor, constant: -20),
            closeLens.centerXAnchor.constraint(equalTo: familyHost.centerXAnchor),
            closeLens.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: presenting

    /// Shows `content` in the card, on live glass. `size` is a wish: the card
    /// never grows past the window it lives in.
    func present(_ content: NSView, size: NSSize,
                 onDismiss: (() -> Void)? = nil) {
        guard window != nil else { return }
        transitionID += 1
        if isPresented { dismiss(animated: false) }
        self.onDismiss = onDismiss

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
        transitionID += 1
        let token = transitionID
        removeEscapeMonitor()
        let finish = { [weak self] in
            guard let self, self.transitionID == token else { return }
            self.isHidden = true
            self.alphaValue = 0
            for view in self.cardContent.subviews { view.removeFromSuperview() }
            self.card.layer?.removeAllAnimations()
            self.card.layer?.transform = CATransform3DIdentity
            self.card.layer?.opacity = 1
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

    // MARK: events

    /// A click anywhere outside the card closes it, like clicking outside a
    /// sheet: the card itself keeps its own clicks.
    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    /// The card and the close pill own their clicks; everything else is a
    /// click on the room, which closes the card. There is no scrim to catch
    /// it: the host itself is the catcher.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isPresented else { return nil }
        guard let hit = super.hitTest(point) else { return nil }
        if hit.isDescendant(of: card) || hit.isDescendant(of: closeLens) { return hit }
        return self
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
