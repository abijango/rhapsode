import Foundation

// MARK: - Data-driven font catalog (Path 1e.2)

/// One `@font-face` source file served from `rhapsode://reader/fonts/<file>`.
struct ReaderFontFaceSpec: Hashable, Sendable, Codable {
    /// Basename in the app bundle (e.g. `Bitter-Variable.ttf`).
    var file: String
    /// CSS `font-weight` — single value (`"400"`) or variable range (`"100 900"`).
    var weight: String
    /// CSS `font-style` — `"normal"` or `"italic"`.
    var style: String

    static func regular(_ file: String, weight: String = "400") -> Self {
        .init(file: file, weight: weight, style: "normal")
    }

    static func italic(_ file: String, weight: String = "400") -> Self {
        .init(file: file, weight: weight, style: "italic")
    }

    static func variable(_ file: String, style: String = "normal", range: String = "100 900") -> Self {
        .init(file: file, weight: range, style: style)
    }
}

/// A selectable reading typeface. New curated faces are rows in `ReaderFontCatalog.presets`
/// only — no bridge/Swift switch cases required.
struct ReaderFontPreset: Identifiable, Hashable, Sendable {
    /// Stable preference key (`literata`, `bitter`, …). Stored in UserDefaults.
    var id: String
    var label: String
    var subtitle: String
    /// CSS `font-family` stack applied to the book, or `nil` for publisher styles.
    var cssStack: String?
    /// Family name used inside `@font-face` (usually the first quoted name in `cssStack`).
    var familyName: String?
    /// Bundled face files. Empty for publisher / system-only stacks.
    var faces: [ReaderFontFaceSpec]

    var isPublisher: Bool { id == "publisher" }

    /// Payload fragment for the Foliate bridge `setStyles` / `open` settings object.
    func bridgePayload() -> [String: Any] {
        [
            "fontFamilyId": id,
            "cssStack": cssStack ?? NSNull(),
            "familyName": familyName ?? NSNull(),
            "faces": faces.map { face -> [String: String] in
                [
                    "file": face.file,
                    "weight": face.weight,
                    "style": face.style,
                    "family": familyName ?? "",
                ]
            },
        ]
    }
}

/// Single source of truth for built-in + curated reading faces.
/// User imports are merged at read time via `allSelectablePresets()` (Path 1e.3).
enum ReaderFontCatalog {
    /// Default when preference is missing or unknown.
    static let defaultID = "literata"

    /// Built-in / curated faces only (no user imports).
    static let presets: [ReaderFontPreset] = [
        ReaderFontPreset(
            id: "publisher",
            label: "Publisher's font",
            subtitle: "The typeface chosen by the book's designer.",
            cssStack: nil,
            familyName: nil,
            faces: []
        ),
        ReaderFontPreset(
            id: "literata",
            label: "Literata",
            subtitle: "A warm serif designed for long-form reading.",
            cssStack: #""Literata", "Iowan Old Style", "Palatino Linotype", Palatino, serif"#,
            familyName: "Literata",
            faces: [
                .regular("Literata-Regular.ttf"),
                .italic("Literata-Italic.ttf"),
                .regular("Literata-Bold.ttf", weight: "700"),
                .italic("Literata-BoldItalic.ttf", weight: "700"),
            ]
        ),
        ReaderFontPreset(
            id: "bitter",
            label: "Bitter",
            subtitle: "A contemporary slab serif, comfortable on screens.",
            cssStack: #""Bitter", "Literata", "Palatino Linotype", Palatino, serif"#,
            familyName: "Bitter",
            faces: [
                .variable("Bitter-Variable.ttf"),
                .variable("Bitter-Italic-Variable.ttf", style: "italic"),
            ]
        ),
        ReaderFontPreset(
            id: "vollkorn",
            label: "Vollkorn",
            subtitle: "A soft classical serif with quiet personality.",
            cssStack: #""Vollkorn", "Literata", Georgia, serif"#,
            familyName: "Vollkorn",
            faces: [
                .variable("Vollkorn-Variable.ttf"),
                .variable("Vollkorn-Italic-Variable.ttf", style: "italic"),
            ]
        ),
        ReaderFontPreset(
            id: "ptSerif",
            label: "PT Serif",
            subtitle: "A sturdy transitional serif for continuous reading.",
            cssStack: #""PT Serif", "Times New Roman", Times, serif"#,
            familyName: "PT Serif",
            faces: [
                .regular("PTSerif-Regular.ttf"),
                .italic("PTSerif-Italic.ttf"),
                .regular("PTSerif-Bold.ttf", weight: "700"),
                .italic("PTSerif-BoldItalic.ttf", weight: "700"),
            ]
        ),
        ReaderFontPreset(
            id: "robotoSlab",
            label: "Roboto Slab",
            subtitle: "A geometric slab serif (variable weight).",
            cssStack: #""Roboto Slab", "Bitter", Georgia, serif"#,
            familyName: "Roboto Slab",
            faces: [
                .variable("RobotoSlab-Variable.ttf"),
            ]
        ),
        ReaderFontPreset(
            id: "atkinsonHyperlegible",
            label: "Atkinson Hyperlegible",
            subtitle: "A highly legible sans for low-vision readers.",
            cssStack: #""Atkinson Hyperlegible", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif"#,
            familyName: "Atkinson Hyperlegible",
            faces: [
                .regular("AtkinsonHyperlegible-Regular.ttf"),
                .italic("AtkinsonHyperlegible-Italic.ttf"),
                .regular("AtkinsonHyperlegible-Bold.ttf", weight: "700"),
                .italic("AtkinsonHyperlegible-BoldItalic.ttf", weight: "700"),
            ]
        ),
        ReaderFontPreset(
            id: "openDyslexic",
            label: "OpenDyslexic",
            subtitle: "Dyslexia-oriented letterforms (system fallback if not installed).",
            cssStack: #""OpenDyslexic", "Comic Sans MS", "Arial", sans-serif"#,
            familyName: "OpenDyslexic",
            faces: []
        ),
    ]

    private static let builtInByID: [String: ReaderFontPreset] = {
        Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    }()

    /// Built-ins plus user-imported faces (for pickers).
    static func allSelectablePresets() -> [ReaderFontPreset] {
        presets + CustomReaderFontStore.presets()
    }

    static func preset(id: String?) -> ReaderFontPreset {
        guard let id else { return builtInByID[defaultID]! }
        if let builtIn = builtInByID[id] { return builtIn }
        if let custom = CustomReaderFontStore.font(preferenceID: id) {
            return custom.asPreset()
        }
        return builtInByID[defaultID]!
    }

    /// Alias for `preset(id:)` (call sites that want explicit resolve naming).
    static func resolve(id: String?) -> ReaderFontPreset { preset(id: id) }

    /// All basenames that must exist in the app bundle for scheme serving.
    static var bundledFilenames: [String] {
        presets.flatMap(\.faces).map(\.file).filter { !$0.hasPrefix("custom/") }
    }
}

// MARK: - Preference-facing type (stable raw values = catalog ids)

/// Thin Identifiable wrapper so SwiftUI pickers and UserDefaults keep working.
/// Prefer `ReaderFontCatalog.resolve(id:)` for metadata.
struct ReaderFontChoice: RawRepresentable, Hashable, Identifiable, CaseIterable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static var allCases: [ReaderFontChoice] {
        ReaderFontCatalog.presets.map { ReaderFontChoice(rawValue: $0.id) }
    }

    static let publisher = ReaderFontChoice(rawValue: "publisher")
    static let literata = ReaderFontChoice(rawValue: "literata")
    static let bitter = ReaderFontChoice(rawValue: "bitter")
    static let atkinsonHyperlegible = ReaderFontChoice(rawValue: "atkinsonHyperlegible")
    static let openDyslexic = ReaderFontChoice(rawValue: "openDyslexic")

    var preset: ReaderFontPreset { ReaderFontCatalog.resolve(id: rawValue) }
    var label: String { preset.label }
    var subtitle: String { preset.subtitle }
}

/// Catalog helpers (filenames for diagnostics).
enum ReaderFonts {
    static var bundledFilenames: [String] { ReaderFontCatalog.bundledFilenames }
}
