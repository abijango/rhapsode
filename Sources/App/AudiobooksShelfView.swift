import SwiftData
import SwiftUI

/// Audiobooks library shelf. Renders downloaded audiobooks in a cover grid and
/// navigates to the player. Books arrive via the Dropbox download pipeline.
struct AudiobooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Query(sort: \Audiobook.title) private var audiobooks: [Audiobook]

    private var columns: [GridItem] { DS.Shelf.columns(regular: hSizeClass == .regular) }

    var body: some View {
        NavigationStack {
            Group {
                if audiobooks.isEmpty {
                    ContentUnavailableView(
                        "No Audiobooks",
                        systemImage: "headphones",
                        description: Text("Drop an M4B or MP3 folder into your Dropbox Audiobooks folder.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: DS.Shelf.spacing) {
                            ForEach(audiobooks) { book in
                                NavigationLink {
                                    PlayerView(audiobook: book)
                                } label: {
                                    CoverTile(
                                        title: book.title,
                                        subtitle: book.author,
                                        coverPath: book.coverPath,
                                        progress: book.fractionComplete
                                    )
                                }
                                .tint(.primary)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        LibraryStore(context: modelContext).deleteAudiobook(book)
                                    }
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                    }
                }
            }
            .navigationTitle("Audiobooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Scan now", systemImage: "arrow.clockwise") {
                    Task { await sync.scanNow() }
                }
                .disabled(sync.isScanning)
            }
            .overlay(alignment: .top) {
                if sync.isScanning { ProgressView("Scanning Dropbox…").padding(DS.Spacing.sm) }
            }
            .alert("Sync Issue", isPresented: Binding(
                get: { sync.lastError != nil },
                set: { if !$0 { sync.lastError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(sync.lastError ?? "")
            }
            .background(DS.Palette.shelfBackground)
        }
    }
}
