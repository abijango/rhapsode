import Foundation
import SwiftData
import SwiftUI

// MARK: - Continue + search helpers

enum LibraryShelf {
    /// In-progress audiobooks, most recently touched first.
    static func continueAudiobooks(_ books: [Audiobook]) -> [Audiobook] {
        books
            .filter { $0.shelfFractionComplete > 0.001 && $0.shelfFractionComplete < 0.995 }
            .sorted {
                ($0.progressUpdatedAt ?? .distantPast) > ($1.progressUpdatedAt ?? .distantPast)
            }
    }

    /// In-progress e-books, most recently touched first.
    static func continueEbooks(_ books: [Book]) -> [Book] {
        books
            .filter {
                ($0.readingLocator != nil || ($0.readingSeconds ?? 0) > 0)
                    && $0.finishedAt == nil
                    && $0.fractionComplete < 0.98
            }
            .sorted {
                ($0.progressUpdatedAt ?? .distantPast) > ($1.progressUpdatedAt ?? .distantPast)
            }
    }

    static func matchesAudiobook(_ book: Audiobook, query: String) -> Bool {
        matches(title: book.title, author: book.author, query: query)
    }

    static func matchesEbook(_ book: Book, query: String) -> Bool {
        matches(title: book.title, author: book.author, query: query)
    }

    /// When `filterID` is nil, every item passes. Otherwise the item must belong to that collection.
    static func inCollection(_ memberCollections: [LibraryCollection], filterID: UUID?) -> Bool {
        guard let filterID else { return true }
        return memberCollections.contains { $0.id == filterID }
    }

    static func matchesRemote(_ entry: RemoteCatalogEntry, query: String) -> Bool {
        matches(title: entry.title, author: entry.author, query: query)
    }

    private static func matches(title: String, author: String?, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let needle = q.localizedLowercase
        if title.localizedLowercase.contains(needle) { return true }
        if let author, author.localizedLowercase.contains(needle) { return true }
        return false
    }
}

// MARK: - Shelf chrome

struct ShelfSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.sm)
    }
}

/// Horizontal strip of covers for the pinned Continue section.
struct ContinueShelfRow<Book: Identifiable, Tile: View>: View {
    let items: [Book]
    @ViewBuilder let tile: (Book) -> Tile
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DS.Shelf.spacing) {
                ForEach(items) { item in
                    if hSize == .regular {
                        // iPad / Mac: match the fixed regular grid tile width.
                        tile(item)
                            .frame(width: DS.Shelf.coverWidthRegular)
                    } else {
                        // iPhone: match the two-column compact grid width.
                        tile(item)
                            .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: DS.Shelf.spacing)
                    }
                }
            }
            .padding(.bottom, DS.Spacing.xs)
        }
    }
}

/// Material banner for background catalogue refresh / scan — one surface, not overlay + toolbar spinner.
struct LibraryScanBanner: View {
    let label: String

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}