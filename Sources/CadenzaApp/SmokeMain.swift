import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation
import CoreText

/// The diagnostic entry points the app exposes with launch flags. The app
/// itself never calls them; they exist so a note-detection question can be
/// answered from the same binary that plays the piano. Each area lives in its
/// own file beside this one.
enum SmokeMain {}
