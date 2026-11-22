import AppKit
import CadenzaCore

/// Engraves a finished session's notes to a PDF in its session folder.
///
/// The sheet is drawn page by page, each page holding whole systems: the
/// print pipeline used to slice the tall scroll view wherever the paper
/// ended, which cut staves in half. Here every page is written straight into
/// a vector PDF context, so the file is sharp at any zoom and a system is
/// never split. Pages follow the engraver's own page groups, so the printed
/// sheet breaks exactly where the scrolling sheet does.
@MainActor
enum SheetPDF {
    static func write(notes: [NoteEvent], options: SheetDraft.Options? = nil,
                      originTicks: Int? = nil, title: String? = nil,
                      composer: String? = nil, pedals: [SheetDraft.PedalSpan] = [],
                      to url: URL) throws {
        let result = SheetDraft.draft(
            notes: notes, options: options ?? SheetDraft.inferredOptions(notes: notes),
            pageWidth: SheetEngraver.pageWidth, pedals: pedals, originTicks: originTicks)
        try write(result: result, title: title, composer: composer, to: url)
    }

    static func write(result: SheetDraft.Result, title: String? = nil,
                      composer: String? = nil, to url: URL) throws {
        let gap = CGFloat(ScoreLayout.lineGap)
        let rowHeight = CGFloat(result.rowHeight) * gap
        // A printed score is A4 at an engraved scale: a staff space of about
        // 1.75 mm, not the generous on-screen spacing. The paper's width
        // decides the scale, and the paper's height then decides how many
        // systems fit — which is how an edition is laid out.
        let margin: CGFloat = 36
        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        let drawnWidth = CGFloat(result.width) * gap
        let scale = min(1, (pageWidth - 2 * margin) / max(1, drawnWidth))
        // An edition opens with the title, the composer and the tempo; the
        // systems start below them. The space is kept on every page so the
        // page breaks stay identical, which is how a printed part reads.
        let header: CGFloat = title == nil ? 0 : 78
        let perPage = max(1, Int(((pageHeight - 2 * margin - header) / (rowHeight * scale)).rounded(.down)))
        let modelMargin = margin / scale
        let modelWidth = drawnWidth + 2 * modelMargin
        let modelHeight = pageHeight / scale

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFError.nothingWritten(url)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFError.nothingWritten(url)
        }

        let view = ScoreView(result: result)
        view.frame = NSRect(x: 0, y: 0, width: modelWidth, height: modelHeight)
        view.topInset = modelMargin

        let rows = result.rows.count
        let pageCount = max(1, (rows + perPage - 1) / perPage)
        for page in 0..<pageCount {
            let from = page * perPage
            let to = min(rows, from + perPage)
            guard from < to else { continue }
            view.visibleRows = from...(to - 1)

            view.topInset = modelMargin + (page == 0 ? header / scale : 0)

            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // the view draws in flipped coordinates: turn the page over once
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: modelWidth, height: modelHeight))

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            view.draw(NSRect(x: 0, y: 0, width: modelWidth, height: modelHeight))
            NSGraphicsContext.restoreGraphicsState()

            ctx.restoreGState()

            // title block and folio, drawn in page points
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            if page == 0, let title {
                drawHeader(title: title, composer: composer, bpm: result.options.bpm,
                           pageWidth: pageWidth, pageHeight: pageHeight, margin: margin)
            }
            if pageCount > 1 {
                drawFolio(page + 1, pageWidth: pageWidth, margin: margin)
            }
            NSGraphicsContext.restoreGraphicsState()

            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFError.nothingWritten(url)
        }
    }

    // MARK: page furniture

    /// The title block of the first page: name, subtitle, composer and the
    /// metronome mark an edition puts above the first system.
    private static func drawHeader(title: String, composer: String?, bpm: Double,
                                   pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat) {
        let ink = NSColor.black
        let serif = PaperTheme.displaySerif(23, weight: .semibold)
            ?? NSFont.systemFont(ofSize: 23, weight: .semibold)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: titleAttributes)
        let titleY = pageHeight - margin - size.height
        (title as NSString).draw(at: NSPoint(x: (pageWidth - size.width) / 2, y: titleY),
                                 withAttributes: titleAttributes)

        var lineY = titleY - 16
        if let composer, !composer.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.black.withAlphaComponent(0.72),
            ]
            let composerSize = (composer as NSString).size(withAttributes: attributes)
            (composer as NSString).draw(at: NSPoint(x: (pageWidth - composerSize.width) / 2, y: lineY),
                                        withAttributes: attributes)
            lineY -= 14
        }

        // the metronome mark sits at the left margin, where a player looks
        // U+ECA5 is the pre-composed metronome mark for a quarter note
        let quarter = String(UnicodeScalar(0xECA5)!)
        let musicAttributes: [NSAttributedString.Key: Any] = [
            .font: MusicFont.font(size: 13), .foregroundColor: ink,
        ]
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: ink,
        ]
        // One string, two fonts: the note glyph and its number share a
        // baseline, the way a metronome mark is set.
        let mark = NSMutableAttributedString(string: quarter, attributes: musicAttributes)
        mark.append(NSAttributedString(string: " = \(Int(bpm.rounded()))", attributes: markAttributes))
        mark.draw(at: NSPoint(x: margin, y: lineY))
    }

    private static func drawFolio(_ number: Int, pageWidth: CGFloat, margin: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.black.withAlphaComponent(0.55),
        ]
        let text = "\(number)"
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (pageWidth - size.width) / 2, y: margin / 2),
                                withAttributes: attributes)
    }
}

enum PDFError: LocalizedError {
    case printPipelineRefused
    case nothingWritten(URL)

    var errorDescription: String? {
        switch self {
        case .printPipelineRefused:
            return "The print pipeline refused the engraving"
        case .nothingWritten(let url):
            return "No PDF was written to \(url.lastPathComponent)"
        }
    }
}
