import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData
import SwiftUI

/// Reader-view appearance settings, mapped onto Readium's `EPUBPreferences`.
struct ReaderSettings: Equatable {
    enum ReaderTheme: String, CaseIterable, Identifiable {
        case light, dark, sepia
        var id: String { rawValue }
        var readium: ReadiumNavigator.Theme {
            switch self {
            case .light: .light
            case .dark: .dark
            case .sepia: .sepia
            }
        }
    }

    var fontSize: Double = 1.0   // 1.0 = 100%
    var theme: ReaderTheme = .light

    var epubPreferences: EPUBPreferences {
        EPUBPreferences(fontSize: fontSize, theme: theme.readium)
    }
}

/// Owns the Readium `Publication` + `EPUBNavigatorViewController`, applies
/// appearance preferences, persists the reading `Locator`, and exposes the TOC.
@MainActor
@Observable
final class EbookReader: NSObject {
    private(set) var navigator: EPUBNavigatorViewController?
    private(set) var toc: [ReadiumShared.Link] = []
    private(set) var loadError: String?
    var settings = ReaderSettings() {
        didSet { if settings != oldValue { navigator?.submitPreferences(settings.epubPreferences) } }
    }

    private var book: Book?
    private var context: ModelContext?

    /// Open the book and build the navigator, restoring the saved locator.
    func open(_ book: Book, context: ModelContext) async {
        self.book = book
        self.context = context
        do {
            let url = try ContainerPaths.url(forRelativePath: book.fileRelPath)
            let publication = try await EbookImporter.openPublication(at: url)

            let initial = book.readingLocator.flatMap { Self.locator(fromJSON: $0) }
            var config = EPUBNavigatorViewController.Configuration()
            config.preferences = settings.epubPreferences

            let nav = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initial,
                config: config
            )
            nav.delegate = self
            navigator = nav
            toc = (try? await publication.tableOfContents().get()) ?? []
        } catch {
            loadError = "Couldn’t open book: \(error.localizedDescription)"
        }
    }

    func go(to link: ReadiumShared.Link) {
        guard let navigator else { return }
        Task { await navigator.go(to: link) }
    }

    // MARK: Locator persistence

    private func persist(_ locator: Locator) {
        guard let book, let context else { return }
        book.readingLocator = try? locator.jsonString()
        try? context.save()
    }

    private static func locator(fromJSON json: String) -> Locator? {
        guard let value = try? JSONValue(jsonString: json, warnings: nil) else { return nil }
        return try? Locator(json: value, warnings: nil)
    }
}

extension EbookReader: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        persist(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        loadError = "Reader error: \(error)"
    }
}
