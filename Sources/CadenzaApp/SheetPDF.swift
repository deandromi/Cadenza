import AppKit
import CadenzaCore

/// Engraves a finished session's notes to a PDF in its session folder.
/// Only what the layout produces: the same SheetDraft pass the sheet window
/// uses, drawn and paginated by the printing pipeline, which writes PDFs
/// natively with no print panel and no user round trip.
@MainActor
enum SheetPDF {
    static func write(notes: [NoteEvent], to url: URL) throws {
        let result = SheetDraft.draft(
            notes: notes, options: SheetDraft.Options(), pageWidth: 86, pedals: [])
        let view = ScoreView(result: result)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
}
