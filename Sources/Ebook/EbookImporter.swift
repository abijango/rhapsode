import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import UIKit

/// Opens a downloaded local EPUB with Readium and builds a `Book` (title, author,
/// cover). Stores only container-relative paths. The reader (`ReaderView`) re-opens
/// the same file for rendering.
///
/// `@MainActor`: Readium's `Publication`/parser types are not `Sendable`, and the
/// navigator must be built on the main actor, so opening stays main-isolated.
@MainActor
enum EbookImporter {
    /// Shared Readium components for opening publications.
    static func makeOpener() -> (AssetRetriever, PublicationOpener) {
        let http = DefaultHTTPClient()
        let retriever = AssetRetriever(httpClient: http)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: http,
                assetRetriever: retriever,
                pdfFactory: PDFKitPDFDocumentFactory()
            )
        )
        return (retriever, opener)
    }

    /// Open the EPUB at `localURL` (inside the container) into a `Publication`.
    static func openPublication(at localURL: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: localURL) else {
            throw LibrarySourceError.notFound(path: localURL.path)
        }
        let (retriever, opener) = makeOpener()
        let asset = try await retriever.retrieve(url: fileURL).get()
        return try await opener.open(asset: asset, allowUserInteraction: false).get()
    }

    /// Build a `Book` model from a local EPUB. Not yet inserted into a context.
    static func makeBook(fromLocal localURL: URL) async throws -> Book {
        let publication = try await openPublication(at: localURL)
        let rel = try relPath(localURL)
        let title = publication.metadata.title ?? localURL.deletingPathExtension().lastPathComponent
        let author = publication.metadata.authors.first?.name
        let coverPath = await extractCover(publication, baseName: title)
        return Book(title: title, author: author, coverPath: coverPath,
                    fileRelPath: rel, readingLocator: nil)
    }

    private static func extractCover(_ publication: Publication, baseName: String) async -> String? {
        guard let data = await coverJPEGData(from: publication) else { return nil }
        let rel = "Covers/\(UUID().uuidString).jpg"
        guard let dest = try? ContainerPaths.url(forRelativePath: rel) else { return nil }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? rel : nil
    }

    /// JPEG bytes for the publication cover, or nil. Used by import and by remote cover prefetch.
    static func coverJPEGData(from publication: Publication) async -> Data? {
        guard let image = (try? await publication.cover().get()) ?? nil else { return nil }
        return image.jpegData(compressionQuality: 0.82)
    }

    /// Open a local EPUB and return its cover as JPEG (does not write to Covers/).
    static func coverJPEGData(fromLocalEPUB url: URL) async -> Data? {
        guard let publication = try? await openPublication(at: url) else { return nil }
        return await coverJPEGData(from: publication)
    }

    private static func relPath(_ url: URL) throws -> String {
        guard let rel = try ContainerPaths.relativePath(for: url) else {
            throw LibrarySourceError.notFound(path: url.path)
        }
        return rel
    }
}
