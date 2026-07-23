import CoreText
import Foundation
import UniformTypeIdentifiers

// MARK: - Model

/// User-imported reading face (Path 1e.3). Files live under Application Support
/// (`Media/ReaderFonts/Custom/`), not Caches.
struct CustomReaderFont: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Label shown in the typeface picker.
    var displayName: String
    /// CSS / @font-face family name (from the file when possible).
    var familyName: String
    /// Basename only, e.g. `A1B2….ttf` under `ReaderFonts/Custom/`.
    var fileName: String
    var createdAt: Date

    /// Preference / catalog id: `custom:<uuid>`.
    var preferenceID: String { "custom:\(id.uuidString)" }

    /// Media-root-relative path for `ContainerPaths`.
    var relativePath: String { "ReaderFonts/Custom/\(fileName)" }

    /// Scheme path segment used in `@font-face` URLs: `custom/<fileName>`.
    var schemeFontPath: String { "custom/\(fileName)" }

    func asPreset() -> ReaderFontPreset {
        let family = familyName
        let escaped = family.replacingOccurrences(of: "\"", with: "")
        return ReaderFontPreset(
            id: preferenceID,
            label: displayName,
            subtitle: "Imported typeface",
            cssStack: #""\#(escaped)", "Literata", Georgia, serif"#,
            familyName: family,
            faces: [
                ReaderFontFaceSpec(file: schemeFontPath, weight: "100 900", style: "normal"),
            ]
        )
    }
}

// MARK: - Store

/// Persists the user font catalog in UserDefaults and files on disk.
enum CustomReaderFontStore {
    private static let defaultsKey = "reader.customFonts"
    private static let customDirRel = "ReaderFonts/Custom"

    static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]

    static var contentTypes: [UTType] {
        var types: [UTType] = [.font]
        if let ttf = UTType(filenameExtension: "ttf") { types.append(ttf) }
        if let otf = UTType(filenameExtension: "otf") { types.append(otf) }
        if let woff = UTType(filenameExtension: "woff") { types.append(woff) }
        if let woff2 = UTType(filenameExtension: "woff2") { types.append(woff2) }
        return types
    }

    // MARK: Read / write catalog

    private static func loadRaw() -> [CustomReaderFont] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([CustomReaderFont].self, from: data)
        else { return [] }
        return list
    }

    static func all() -> [CustomReaderFont] {
        // Drop entries whose files vanished (user cleared storage, etc.).
        let existing = loadRaw().filter { font in
            guard let url = try? ContainerPaths.url(forRelativePath: font.relativePath) else {
                return false
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
        // Opportunistically prune stale catalog rows.
        if existing.count != loadRaw().count {
            save(existing)
        }
        return existing
    }

    private static func save(_ fonts: [CustomReaderFont]) {
        guard let data = try? JSONEncoder().encode(fonts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func font(preferenceID: String) -> CustomReaderFont? {
        guard preferenceID.hasPrefix("custom:") else { return nil }
        return all().first { $0.preferenceID == preferenceID }
    }

    static func presets() -> [ReaderFontPreset] {
        all().sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { $0.asPreset() }
    }

    // MARK: Import

    enum ImportError: LocalizedError {
        case unsupportedType
        case unreadable
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType:
                return "Use a TrueType or OpenType font (.ttf, .otf)."
            case .unreadable:
                return "Couldn’t read that font file."
            case .copyFailed(let msg):
                return "Couldn’t import font: \(msg)"
            }
        }
    }

    /// Copy `source` into Application Support and register it. Returns the new record.
    @discardableResult
    static func importFont(from source: URL) throws -> CustomReaderFont {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }

        let ext = source.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw ImportError.unsupportedType }

        // Coalesce security-scoped / iCloud placeholders.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.copyItem(at: source, to: tmp)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let rel = "\(customDirRel)/\(fileName)"
        let dest = try ContainerPaths.url(forRelativePath: rel)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.copyItem(at: tmp, to: dest)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        let baseLabel = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let family = detectFamilyName(at: dest) ?? (baseLabel.isEmpty ? "Custom Font" : baseLabel)
        let display = baseLabel.isEmpty ? family : baseLabel

        let record = CustomReaderFont(
            id: id,
            displayName: display,
            familyName: family,
            fileName: fileName,
            createdAt: Date()
        )
        var list = all()
        list.append(record)
        save(list)
        return record
    }

    // MARK: Delete

    /// Remove catalog entry and file. Returns whether the deleted font was the active preference.
    @discardableResult
    static func delete(_ font: CustomReaderFont) -> Bool {
        let wasSelected = ReaderPreferences.fontChoice.rawValue == font.preferenceID
        if let url = try? ContainerPaths.url(forRelativePath: font.relativePath) {
            try? FileManager.default.removeItem(at: url)
        }
        save(loadRaw().filter { $0.id != font.id })
        if wasSelected {
            ReaderPreferences.fontChoice = ReaderFontChoice(rawValue: ReaderFontCatalog.defaultID)
        }
        return wasSelected
    }

    // MARK: CoreText

    private static func detectFamilyName(at url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }
}
