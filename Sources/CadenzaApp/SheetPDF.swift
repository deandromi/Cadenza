import AppKit
import CadenzaCore

/// Engraves a finished session's notes to a PDF in its session folder.
///
/// The sheet is drawn page by page, each page holding whole systems: the
/// print pipeline used to slice the tall scroll view wherever the paper
/// ended, which cut staves in half. Here every page is written straight into
/// a vector PDF context, so the file is sharp at any zoom and a system is
/// never split.
@MainActor
enum SheetPDF {
    /// Systems on one page. Three fills A4 at the engraving's own size.
    static let systemsPerPage = 3

    static func write(notes: [NoteEvent], to url: URL) throws {
        let result = SheetDraft.draft(
            notes: notes, options: SheetDraft.inferredOptions(notes: notes),
            pageWidth: 86, pedals: [])
        try write(result: result, to: url)
    }

    static func write(result: SheetDraft.Result, to url: URL) throws {
        let gap = CGFloat(ScoreLayout.lineGap)
        let rowHeight = CGFloat(result.rowHeight) * gap
        let margin: CGFloat = 36
        let pageWidth = CGFloat(result.width) * gap + 2 * margin
        let pageHeight = CGFloat(systemsPerPage) * rowHeight + 2 * margin

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFError.nothingWritten(url)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFError.nothingWritten(url)
        }

        let view = ScoreView(result: result)
        view.frame = NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        view.topInset = margin

        let rows = result.rows.count
        let pageCount = max(1, (rows + systemsPerPage - 1) / systemsPerPage)
        for page in 0..<pageCount {
            let from = page * systemsPerPage
            let to = min(rows, from + systemsPerPage)
            guard from < to else { continue }
            view.visibleRows = from...(to - 1)

            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // the view draws in flipped coordinates: turn the page over once
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: margin, y: 0)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: -margin, y: 0, width: pageWidth, height: pageHeight))

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            view.draw(NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            NSGraphicsContext.restoreGraphicsState()

            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFError.nothingWritten(url)
        }
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
