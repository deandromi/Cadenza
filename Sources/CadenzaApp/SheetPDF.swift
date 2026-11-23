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
                      timeMap: SheetDraft.TimeMap? = nil,
                      declaredFifths: Int? = nil,
                      to url: URL) throws {
        let result = SheetDraft.draft(
            notes: notes, options: options ?? SheetDraft.inferredOptions(notes: notes),
            pageWidth: SheetEngraver.pageWidth, pedals: pedals, originTicks: originTicks,
            timeMap: timeMap, declaredFifths: declaredFifths)
        // A file name is the only title page a performance has: build the
        // block from it rather than printing the file name as a title.
        var block = SheetTitle.inferred(
            fileTitle: nil,
            fileName: url.deletingPathExtension().lastPathComponent,
            meter: (result.options.numerator, result.options.denominator),
            bpm: result.options.bpm,
            meterIsDeclared: false)
        if let composer, !composer.isEmpty { block.composer = composer }
        try write(result: result, block: block, to: url)
    }

    static func write(result: SheetDraft.Result, title: String? = nil,
                      composer: String? = nil, to url: URL) throws {
        var block = SheetTitle.inferred(fileTitle: title, fileName: title ?? "")
        if let composer, !composer.isEmpty { block.composer = composer }
        try write(result: result, block: block, to: url)
    }

    static func write(result: SheetDraft.Result, block: SheetTitle?, to url: URL) throws {
        let gap = CGFloat(ScoreLayout.lineGap)
        let rowHeight = CGFloat(result.rowHeight) * gap
        // A printed score is A4 at an engraved scale: a staff space of about
        // 1.75 mm, not the generous on-screen spacing. The paper's width
        // decides the scale, and the paper's height then decides how many
        // systems fit — which is how an edition is laid out.
        let margin: CGFloat = 36
        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        // The sheet is measured by its ink, not by its nominal width: the
        // brace hangs left of the first barline and the last head reaches a
        // little past its column. Framing on the nominal width is what set the
        // music against the paper's edge and off-centre.
        let inkLeft = ScoreView.inkLeftX(gap: gap)
        let inkRight = ScoreView.inkRightX(rowWidth: result.width, gap: gap)
        let drawnWidth = inkRight - inkLeft
        let scale = min(1, (pageWidth - 2 * margin) / max(1, drawnWidth))
        // An edition opens with the title, the composer and the tempo; the
        // systems start below them. The space is kept on every page so the
        // page breaks stay identical, which is how a printed part reads.
        let header: CGFloat = block == nil ? 0 : 104
        let rowPitch = rowHeight * scale
        let perPage = max(1, Int(((pageHeight - 2 * margin - header) / rowPitch).rounded(.down)))
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
        view.showsTempoMark = true
        view.frame = NSRect(x: 0, y: 0, width: modelWidth, height: modelHeight)

        let rows = result.rows.count
        let pageCount = max(1, (rows + perPage - 1) / perPage)
        for page in 0..<pageCount {
            let from = page * perPage
            let to = min(rows, from + perPage)
            guard from < to else { continue }
            view.page = ScoreView.Page(
                rows: from..<to,
                top: modelMargin + (page == 0 ? header / scale : 0))

            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // the view draws in flipped coordinates: turn the page over once
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: scale, y: scale)
            // The view measures a system from its first barline; the paper
            // measures it from the brace. Shifting by the ink's own origin,
            // less the margin the page keeps, puts every line on the same
            // left edge with the same air on both sides of the paper.
            ctx.translateBy(x: modelMargin - inkLeft, y: 0)
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
            if page == 0, let block {
                drawHeader(block, pageWidth: pageWidth,
                           pageHeight: pageHeight, margin: margin)
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

    /// The title block of the first page, set the way an edition sets it: the
    /// title centred in the italic serif, the movement under it, the composer
    /// at the left margin and the credit with the dates at the right. The
    /// names come from `SheetTitle`, which reads the file's own name and never
    /// invents a credit it cannot find.
    private static func drawHeader(_ block: SheetTitle,
                                   pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat) {
        let ink = NSColor.black
        let roman = PaperTheme.displaySerif(24, weight: .regular)
        let italic = NSFontManager.shared.convert(roman, toHaveTrait: .italicFontMask)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: italic, .foregroundColor: ink]
        let size = (block.title as NSString).size(withAttributes: titleAttributes)
        let titleY = pageHeight - margin - size.height
        (block.title as NSString).draw(at: NSPoint(x: (pageWidth - size.width) / 2, y: titleY),
                                       withAttributes: titleAttributes)

        let subtitleY = titleY - 20
        let partAttributes: [NSAttributedString.Key: Any] = [
            .font: PaperTheme.displaySerif(12.5, weight: .regular),
            .foregroundColor: ink,
        ]
        if let subtitle = block.subtitle {
            let partSize = (subtitle as NSString).size(withAttributes: partAttributes)
            (subtitle as NSString).draw(at: NSPoint(x: (pageWidth - partSize.width) / 2, y: subtitleY),
                                        withAttributes: partAttributes)
        }

        // the composer at the left margin, the credit and its dates at the
        // right: the two ends of the line an edition puts under the title
        let creditAttributes: [NSAttributedString.Key: Any] = [
            .font: PaperTheme.displaySerif(10, weight: .regular),
            .foregroundColor: ink,
        ]
        let datesAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: ink.withAlphaComponent(0.75),
        ]
        let creditY = subtitleY - 18
        if let composer = block.composer {
            (composer as NSString).draw(at: NSPoint(x: margin, y: creditY),
                                        withAttributes: creditAttributes)
        }
        if let credit = block.credit {
            let creditSize = (credit as NSString).size(withAttributes: creditAttributes)
            (credit as NSString).draw(at: NSPoint(x: pageWidth - margin - creditSize.width,
                                                  y: creditY),
                                      withAttributes: creditAttributes)
        }
        if let dates = block.dates {
            let datesSize = (dates as NSString).size(withAttributes: datesAttributes)
            (dates as NSString).draw(at: NSPoint(x: pageWidth - margin - datesSize.width,
                                                 y: creditY - 13),
                                     withAttributes: datesAttributes)
        }
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
