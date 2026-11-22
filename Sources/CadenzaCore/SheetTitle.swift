import Foundation

/// The furniture at the head of a printed score: the title, the line under
/// it, the composer at the left and the credit at the right.
///
/// A performance MIDI is not a score file. It carries a track name — "Piano",
/// in every file this app has met — and nothing else about its title page,
/// so the block is assembled from the one thing that is certain, the file's
/// own name, plus a short gazetteer of composers. Anything the gazetteer
/// cannot name is left blank: an empty credit line is honest, an invented
/// one is not.
public struct SheetTitle: Sendable, Equatable {
    public var title: String
    /// The line under the title: the movement, or the dance the meter and
    /// tempo argue for.
    public var subtitle: String?
    /// The full name, set at the left of the block.
    public var composer: String?
    /// The name the edition credits, set at the right.
    public var credit: String?
    /// The composer's dates, under the credit.
    public var dates: String?

    public init(title: String, subtitle: String? = nil, composer: String? = nil,
                credit: String? = nil, dates: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.credit = credit
        self.dates = dates
    }

    /// True when the block says something beyond a bare title: the page then
    /// reserves the full head an edition gives it.
    public var isComplete: Bool { subtitle != nil || composer != nil || credit != nil }

    // MARK: reading a file

    /// Track names that are not titles. A DAW names its track after the
    /// instrument, not after the piece.
    static let genericTitles: Set<String> = [
        "piano", "piano 1", "piano 2", "grand piano", "track 1", "track 2",
        "music", "untitled", "new song", "midi",
    ]

    /// The block a file argues for.
    ///
    /// `fileTitle` is the MIDI's own title meta event, when it carries one;
    /// `fileName` is the file's name without its extension. The name is read
    /// as `work[-composer][-movement]`, which is how this repertoire's files
    /// are actually named, and a known composer's name is taken out of the
    /// title and set in the credits where it belongs.
    public static func inferred(fileTitle: String?, fileName: String,
                                meter: (beats: Int, unit: Int)? = nil,
                                bpm: Double? = nil) -> SheetTitle {
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let tokens = words(name)
        let declared = fileTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let specific = declared.flatMap { genericTitles.contains($0.lowercased()) ? nil : $0 }

        var composer: Composer?
        var composerAt: Int?
        for (index, token) in tokens.enumerated() {
            guard let found = Composer.named(token) else { continue }
            composer = found
            composerAt = index
            break
        }

        var titleTokens = tokens
        var subtitleTokens: [String] = []
        if let composer, let at = composerAt {
            // a first name in front of the surname belongs to the composer,
            // not to the piece
            var first = at
            if at > 0, composer.absorbs(tokens[at - 1]) { first = at - 1 }
            titleTokens = Array(tokens[..<first])
            subtitleTokens = Array(tokens[(at + 1)...])
        }

        let title: String
        if let specific, !specific.isEmpty {
            title = specific
        } else if titleTokens.isEmpty {
            title = name.replacingOccurrences(of: "-", with: " ")
        } else {
            title = phrase(titleTokens)
        }
        var subtitle: String? = subtitleTokens.isEmpty ? nil : phrase(subtitleTokens)
        if subtitle == nil, let meter, let bpm {
            subtitle = character(beats: meter.beats, unit: meter.unit, bpm: bpm)
        }
        // An edition does not print the same name twice: when the credit is
        // simply the composer's own name, the right column keeps the dates
        // alone and the name stands once, at the left.
        var credit: String?
        if let composer, !sameName(composer.credit, composer.fullName) {
            credit = composer.credit
        }
        return SheetTitle(title: title, subtitle: subtitle,
                          composer: composer?.fullName,
                          credit: credit, dates: composer?.dates)
    }

    /// Two spellings of one name: accents and case do not make them differ.
    static func sameName(_ one: String, _ other: String) -> Bool {
        one.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            == other.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    // MARK: typography

    /// Words that stay lowercase inside a title unless they open it: the
    /// French and English particles, the way an edition sets a title page.
    private static let particles: Set<String> = [
        "de", "du", "des", "la", "le", "les", "dans", "sur", "sous", "pour",
        "et", "en", "au", "aux", "un", "une", "of", "the", "and", "in", "on",
        "to", "with", "for", "a", "à", "l",
    ]

    /// French ordinals arrive from file names without their accents:
    /// "1ere-serie" is "1ère Série" on a title page.
    private static let ordinals: [String: String] = [
        "1er": "1er", "1ere": "1ère", "1ère": "1ère",
        "2e": "2e", "2eme": "2ème", "2ème": "2ème",
        "3e": "3e", "3eme": "3ème", "3ème": "3ème",
    ]

    /// A title-cased phrase from the words of a file name.
    static func phrase(_ words: [String]) -> String {
        words.enumerated().compactMap { index, word -> String? in
            let lower = word.lowercased()
            guard !lower.isEmpty else { return nil }
            if let ordinal = ordinals[lower] { return ordinal }
            if index > 0, particles.contains(lower) { return lower }
            return capitalised(lower)
        }.joined(separator: " ")
    }

    private static func capitalised(_ word: String) -> String {
        var result = ""
        var startOfWord = true
        for character in word {
            if startOfWord, character.isLetter {
                result.append(contentsOf: character.uppercased())
            } else {
                result.append(character)
            }
            startOfWord = character == "-" || character == "'" || character == "’"
        }
        return result
    }

    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { "-_ .".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The dance a meter and a tempo name together, when they are sure.
    ///
    /// This is the block's one guess. A 3/4 played at a walking pace or
    /// faster is a waltz in this repertoire, and a slow 3/4 is a minuet;
    /// every other meter gets no subtitle at all rather than a wrong one.
    static func character(beats: Int, unit: Int, bpm: Double) -> String? {
        guard beats == 3, unit == 4 else { return nil }
        return bpm >= 100 ? "Valse" : "Menuet"
    }
}

/// One name in the composer gazetteer: what a file calls the composer, the
/// name an edition prints, and the dates it sets under the credit.
struct Composer {
    let surname: String
    let firstNames: [String]
    let fullName: String
    let credit: String
    let dates: String

    func absorbs(_ token: String) -> Bool { firstNames.contains(token.lowercased()) }

    static func named(_ token: String) -> Composer? {
        let lower = token.lowercased()
        return all.first { $0.surname == lower }
    }

    /// The names this app can recognise. Data, not logic: a score that names
    /// its composer in the file name is the common case in this repertoire,
    /// and a name that is not here simply prints no credit line.
    static let all: [Composer] = [
        Composer(surname: "satie", firstNames: ["erik", "eric", "alfred"],
                 fullName: "Éric Alfred Leslie Satie", credit: "Erik Satie", dates: "1866–1925"),
        Composer(surname: "debussy", firstNames: ["claude", "achille"],
                 fullName: "Claude Debussy", credit: "Claude Debussy", dates: "1862–1918"),
        Composer(surname: "ravel", firstNames: ["maurice"],
                 fullName: "Maurice Ravel", credit: "Maurice Ravel", dates: "1875–1937"),
        Composer(surname: "chopin", firstNames: ["frederic", "fryderyk", "frédéric"],
                 fullName: "Fryderyk Chopin", credit: "Frédéric Chopin", dates: "1810–1849"),
        Composer(surname: "liszt", firstNames: ["franz", "ferenc"],
                 fullName: "Franz Liszt", credit: "Franz Liszt", dates: "1811–1886"),
        Composer(surname: "bach", firstNames: ["johann", "js", "j"],
                 fullName: "Johann Sebastian Bach", credit: "J. S. Bach", dates: "1685–1750"),
        Composer(surname: "mozart", firstNames: ["wolfgang", "wa", "w"],
                 fullName: "Wolfgang Amadeus Mozart", credit: "W. A. Mozart", dates: "1756–1791"),
        Composer(surname: "beethoven", firstNames: ["ludwig"],
                 fullName: "Ludwig van Beethoven", credit: "Ludwig van Beethoven", dates: "1770–1827"),
        Composer(surname: "schubert", firstNames: ["franz"],
                 fullName: "Franz Schubert", credit: "Franz Schubert", dates: "1797–1828"),
        Composer(surname: "schumann", firstNames: ["robert", "clara"],
                 fullName: "Robert Schumann", credit: "Robert Schumann", dates: "1810–1856"),
        Composer(surname: "brahms", firstNames: ["johannes"],
                 fullName: "Johannes Brahms", credit: "Johannes Brahms", dates: "1833–1897"),
        Composer(surname: "grieg", firstNames: ["edvard"],
                 fullName: "Edvard Grieg", credit: "Edvard Grieg", dates: "1843–1907"),
        Composer(surname: "faure", firstNames: ["gabriel"],
                 fullName: "Gabriel Fauré", credit: "Gabriel Fauré", dates: "1845–1924"),
        Composer(surname: "saens", firstNames: ["camille", "saint"],
                 fullName: "Camille Saint-Saëns", credit: "Camille Saint-Saëns", dates: "1835–1921"),
        Composer(surname: "rameau", firstNames: ["jean-philippe", "jean"],
                 fullName: "Jean-Philippe Rameau", credit: "Jean-Philippe Rameau", dates: "1683–1764"),
        Composer(surname: "tchaikovsky", firstNames: ["pyotr", "peter", "ilyich"],
                 fullName: "Pyotr Ilyich Tchaikovsky", credit: "Pyotr Tchaikovsky", dates: "1840–1893"),
    ]
}
