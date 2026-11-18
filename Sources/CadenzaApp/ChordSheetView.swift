import AppKit
import CadenzaCore

/// The chord sheet content area: the sounding chord rendered large at the
/// top with the performance history scrolling beneath it.
final class ChordSheetView: NSView {
    private let currentLabel = NSTextField(labelWithString: "—")
    private let hintLabel = NSTextField(labelWithString: "Start listening and play")
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        currentLabel.font = .systemFont(ofSize: 56, weight: .medium)
        currentLabel.textColor = .tertiaryLabelColor
        currentLabel.lineBreakMode = .byClipping
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(currentLabel)

        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 16, right: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = rowsStack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            currentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            currentLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            hintLabel.leadingAnchor.constraint(equalTo: currentLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 10),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Refreshes the large chord and the history rows.
    func update(sheet: [SheetEntry], current: Chord?) {
        currentLabel.stringValue = current?.symbol ?? "—"
        currentLabel.textColor = current == nil ? .tertiaryLabelColor : .labelColor
        hintLabel.isHidden = !sheet.isEmpty

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in sheet.suffix(30) {
            rowsStack.addArrangedSubview(makeRow(entry: entry))
        }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToLatest()
        }
    }

    private func makeRow(entry: SheetEntry) -> NSView {
        let time = NSTextField(labelWithString: Self.timeString(entry.onset))
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let symbol = NSTextField(labelWithString: entry.chord.symbol)
        symbol.font = .systemFont(ofSize: 17, weight: .regular)
        symbol.textColor = .labelColor

        let row = NSStackView(views: [time, symbol])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .firstBaseline
        return row
    }

    private func scrollToLatest() {
        guard let documentView = scrollView.documentView else { return }
        let height = documentView.bounds.height
        let visible = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(height - visible, 0)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
