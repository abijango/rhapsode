import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

extension FontFamily {
    /// Bundled serif reading face (OFL — Google Fonts Literata).
    static let literata: FontFamily = "Literata"
    /// Bundled sans reading face (OFL — Braille Institute Atkinson Hyperlegible).
    static let atkinsonHyperlegible: FontFamily = "Atkinson Hyperlegible"
}

/// Curated typefaces offered in the EPUB reader settings sheet.
enum ReaderFontChoice: String, CaseIterable, Identifiable {
    /// Respect the EPUB publisher's original CSS typography.
    case publisher
    /// Bundled Literata (serif).
    case literata
    /// Bundled Atkinson Hyperlegible (sans, accessibility-oriented).
    case atkinsonHyperlegible
    /// Embedded in Readium (no extra bundle weight).
    case openDyslexic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publisher: "Publisher's font"
        case .literata: "Literata"
        case .atkinsonHyperlegible: "Atkinson Hyperlegible"
        case .openDyslexic: "OpenDyslexic"
        }
    }

    var subtitle: String {
        switch self {
        case .publisher: "The typeface chosen by the book's designer."
        case .literata: "A warm serif designed for long-form reading."
        case .atkinsonHyperlegible: "A highly legible sans for low-vision readers."
        case .openDyslexic: "Weighted letterforms that reduce character confusion."
        }
    }

    var readiumFontFamily: FontFamily? {
        switch self {
        case .publisher: nil
        case .literata: .literata
        case .atkinsonHyperlegible: .atkinsonHyperlegible
        case .openDyslexic: .openDyslexic
        }
    }
}

/// Declares bundled reader fonts for Readium's EPUB webview (`@font-face` injection).
enum ReaderFonts {
    private static let subdirectory = "ReaderFonts"

    static func fontFamilyDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        guard let root = Bundle.main.resourceURL.flatMap({ FileURL(url: $0) }) else { return [] }
        let dir = root.appendingPath(subdirectory, isDirectory: true)

        return [
            CSSFontFamilyDeclaration(
                fontFamily: .literata,
                fontFaces: [
                    face(file: dir.appendingPath("Literata-Regular.ttf", isDirectory: false),
                         style: .normal, weight: .standard(.normal)),
                    face(file: dir.appendingPath("Literata-Italic.ttf", isDirectory: false),
                         style: .italic, weight: .standard(.normal)),
                    face(file: dir.appendingPath("Literata-Bold.ttf", isDirectory: false),
                         style: .normal, weight: .standard(.bold)),
                    face(file: dir.appendingPath("Literata-BoldItalic.ttf", isDirectory: false),
                         style: .italic, weight: .standard(.bold)),
                ]
            ).eraseToAnyHTMLFontFamilyDeclaration(),

            CSSFontFamilyDeclaration(
                fontFamily: .atkinsonHyperlegible,
                fontFaces: [
                    face(file: dir.appendingPath("AtkinsonHyperlegible-Regular.ttf", isDirectory: false),
                         style: .normal, weight: .standard(.normal)),
                    face(file: dir.appendingPath("AtkinsonHyperlegible-Italic.ttf", isDirectory: false),
                         style: .italic, weight: .standard(.normal)),
                    face(file: dir.appendingPath("AtkinsonHyperlegible-Bold.ttf", isDirectory: false),
                         style: .normal, weight: .standard(.bold)),
                    face(file: dir.appendingPath("AtkinsonHyperlegible-BoldItalic.ttf", isDirectory: false),
                         style: .italic, weight: .standard(.bold)),
                ]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
        ]
    }

    private static func face(
        file: FileURL,
        style: CSSFontStyle,
        weight: CSSFontWeight
    ) -> CSSFontFace {
        CSSFontFace(file: file, style: style, weight: weight)
    }
}