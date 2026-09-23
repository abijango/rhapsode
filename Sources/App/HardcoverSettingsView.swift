import SwiftData
import SwiftUI

/// Connect an account, see what's matched, review the ambiguous ones.
///
/// Token entry follows the KOSync sign-in shape (paste + verify + clear), with one addition:
/// the "Create a token" button deep-links to Hardcover's New API Key form with the scopes we
/// need already ticked, so the user doesn't have to work out which of ~30 scopes to grant.
struct HardcoverSettingsView: View {
    @Environment(HardcoverSyncService.self) private var hardcover
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Audiobook.title) private var audiobooks: [Audiobook]

    @State private var isEnabled = HardcoverSettings.isEnabled
    @State private var finishPrompt = HardcoverSettings.finishPromptEnabled
    @State private var tokenField = ""
    @State private var username = HardcoverSettings.username
    @State private var verifying = false
    @State private var verifyError: String?

    private var hasToken: Bool { HardcoverSettings.token?.isEmpty == false }
    private var matched: [Audiobook] { audiobooks.filter { $0.hardcoverState.syncs } }
    private var unmatched: [Audiobook] {
        audiobooks.filter { $0.hardcoverState == .unmatched }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Sync audiobooks to Hardcover", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, new in HardcoverSettings.isEnabled = new }
                if let username {
                    LabeledContent("Account", value: "@\(username)")
                }
            } footer: {
                Text("Progress is pushed when you pause or stop — never while you're listening.")
            }

            Section {
                if !hasToken {
                    Button {
                        openURL(HardcoverSettings.newTokenURL)
                    } label: {
                        Label("Create a token on Hardcover", systemImage: "key")
                    }
                }
                SecureField(hasToken ? "Token saved — paste to replace" : "Paste your API token",
                            text: $tokenField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await verify() }
                } label: {
                    HStack {
                        Text(hasToken ? "Re-verify" : "Verify and connect")
                        if verifying { Spacer(); ProgressView() }
                    }
                }
                .disabled(verifying || (tokenField.isEmpty && !hasToken))

                if let verifyError {
                    Text(verifyError).font(.footnote).foregroundStyle(.red)
                }

                if hasToken {
                    Button("Disconnect", role: .destructive) { disconnect() }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("The token needs read:library and write:library. The link above pre-selects them.")
            }

            if hasToken {
                Section {
                    LabeledContent("Matched", value: "\(matched.count) of \(audiobooks.count)")
                    NavigationLink {
                        HardcoverReviewList(books: unmatched)
                    } label: {
                        LabeledContent("Review matches", value: "\(unmatched.count)")
                    }
                    .disabled(unmatched.isEmpty)

                    Button {
                        Task { await hardcover.matchLibrary(audiobooks) }
                    } label: {
                        HStack {
                            Text("Find matches now")
                            if hardcover.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(hardcover.isBusy)
                } header: {
                    Text("Library")
                } footer: {
                    Text("Only near-exact matches are applied automatically — an edition whose "
                         + "runtime is within 30 seconds of your file. Everything else waits for you.")
                }

                Section {
                    Toggle("Ask to rate when I finish a book", isOn: $finishPrompt)
                        .onChange(of: finishPrompt) { _, new in
                            HardcoverSettings.finishPromptEnabled = new
                        }
                } footer: {
                    Text("Nothing is marked as Read on Hardcover unless you confirm it.")
                }
            }

            if let error = hardcover.lastError {
                Section("Last error") {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Hardcover")
        .navigationBarTitleDisplayMode(.inline)
        .task { hardcover.attach(context: modelContext) }
    }

    private func verify() async {
        verifying = true
        verifyError = nil
        defer { verifying = false }
        let trimmed = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { HardcoverSettings.token = trimmed }
        do {
            username = try await hardcover.verifyToken()
            tokenField = ""
            isEnabled = true
            HardcoverSettings.isEnabled = true
        } catch {
            verifyError = (error as? HardcoverError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func disconnect() {
        HardcoverSettings.signOut()
        username = nil
        isEnabled = false
        tokenField = ""
        // Leave the matches in place: reconnecting later shouldn't mean re-matching the library.
    }
}

/// The books the matcher wasn't confident about, queued for a decision.
private struct HardcoverReviewList: View {
    let books: [Audiobook]
    @State private var matching: Audiobook?

    var body: some View {
        List(books) { book in
            Button {
                matching = book
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).lineLimit(2)
                    if let author = book.author {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Review matches")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $matching) { HardcoverMatchSheet(book: $0) }
        .overlay {
            if books.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle")
            }
        }
    }
}
