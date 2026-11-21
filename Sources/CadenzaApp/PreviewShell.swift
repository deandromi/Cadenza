import AppKit
import CadenzaCore

/// A shell for the offscreen probes: it answers with the fixed state the
/// screenshot was posed with and ignores every action. The real shell is the
/// app delegate; this one exists so `--screen-shot` and friends can render a
/// screen without an engine, a store or a click.
@MainActor
final class PreviewShell: PracticeShell {
    var isListening: Bool
    var exportEnabled: Bool

    init(listening: Bool = false, exporting: Bool = false) {
        isListening = listening
        exportEnabled = exporting
    }
}
