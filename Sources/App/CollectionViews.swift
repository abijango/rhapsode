import SwiftData
import SwiftUI

// MARK: - Filter bar

/// Horizontal collection chips for a shelf: All · Collection names · Manage.
struct CollectionFilterBar: View {
    let collections: [LibraryCollection]
    @Binding var selectedID: UUID?
    let onManage: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                CollectionChip(title: "All", isSelected: selectedID == nil) {
                    selectedID = nil
                }
                ForEach(collections) { collection in
                    CollectionChip(title: collection.name, isSelected: selectedID == collection.id) {
                        selectedID = collection.id
                    }
                }
                Button(action: onManage) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.body)
                        .foregroundStyle(DS.Palette.accent)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 6)
                }
                .accessibilityLabel("Manage collections")
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
        }
    }
}

private struct CollectionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? DS.Palette.accent : Color(.tertiarySystemFill),
                            in: Capsule())
                .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Assign sheet

/// Toggle collection membership for one shelf item; inline create at the bottom.
struct AssignCollectionSheet: View {
    let kind: FolderKind
    let title: String
    let collections: [LibraryCollection]
    let isMember: (LibraryCollection) -> Bool
    let onToggle: (LibraryCollection) -> Void
    let onCreate: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if collections.isEmpty {
                    Text("No collections yet. Create one below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(collections) { collection in
                        Button {
                            onToggle(collection)
                        } label: {
                            HStack {
                                Text(collection.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isMember(collection) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                    }
                }
                Section("New collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Add") { create() }
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(Color(.systemGroupedBackground))
            }
        }
    }

    private func create() {
        do {
            try onCreate(newName)
            newName = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Manage sheet

/// Create, rename, and delete collections for one shelf.
struct ManageCollectionsView: View {
    let kind: FolderKind
    let collections: [LibraryCollection]
    let onCreate: (String) throws -> Void
    let onRename: (LibraryCollection, String) throws -> Void
    let onDelete: (LibraryCollection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renameTarget: LibraryCollection?
    @State private var renameText = ""
    @State private var errorText: String?

    private var shelfLabel: String { kind == .audiobooks ? "Audiobooks" : "E-books" }

    var body: some View {
        NavigationStack {
            List {
                if collections.isEmpty {
                    Text("Collections help you group your \(shelfLabel.lowercased()).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(collections) { collection in
                        Button { beginRename(collection) } label: {
                            Text(collection.name)
                                .foregroundStyle(.primary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                onDelete(collection)
                            }
                        }
                    }
                }
                Section("New collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Add") { create() }
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Collection", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    private func create() {
        do {
            try onCreate(newName)
            newName = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func beginRename(_ collection: LibraryCollection) {
        renameTarget = collection
        renameText = collection.name
        errorText = nil
    }

    private func saveRename() {
        guard let target = renameTarget else { return }
        do {
            try onRename(target, renameText)
            renameTarget = nil
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}