#if DEBUG
import SwiftData
import SwiftUI

/// Launch-arg-gated harness that imports the sample EPUB and shows the reader
/// directly, so the Readium rendering can be screenshotted in isolation.
///   xcrun simctl launch <device> com.naufalmir.rhapsode -readerscreenshot 1
struct DebugReaderHarness: View {
    @Environment(\.modelContext) private var modelContext
    @State private var book: Book?

    var body: some View {
        NavigationStack {
            if let book {
                ReaderView(book: book)
            } else {
                ProgressView("Importing sample…")
                    .task { await importFirst() }
            }
        }
    }

    private func importFirst() async {
        let mock = MockLibrarySource()
        guard let epub = try? await mock.listFolder(DropboxConfig.booksPath).first,
              let dest = try? ContainerPaths.url(forRelativePath: "Books/\(epub.name)")
        else { return }
        do {
            try await mock.download(epub, to: dest)
            let imported = try await EbookImporter.makeBook(fromLocal: dest)
            modelContext.insert(imported)
            try? modelContext.save()
            book = imported
        } catch {
            print("DebugReaderHarness import failed: \(error)")
        }
    }
}
#endif
