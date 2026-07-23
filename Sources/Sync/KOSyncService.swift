import Foundation
import SwiftData

/// Orchestrates KOReader Progress Sync for ebooks: document hash, pull/push, LWW.
@MainActor
enum KOSyncService {
    /// Result of a pull that may need a UI prompt.
    enum PullOutcome: Equatable {
        case skipped
        case noRemote
        case appliedRemote
        case keptLocal
        case conflict(localFraction: Double, remote: KOSyncProgress)
        case error(String)
    }

    // MARK: - Document hash

    /// Cached partial MD5 for `book`, computing and persisting if needed.
    static func documentHash(for book: Book, context: ModelContext?) -> String? {
        if let h = book.koreaderDocumentHash, h.count == 32 { return h }
        guard let url = try? ContainerPaths.url(forRelativePath: book.fileRelPath) else {
            return nil
        }
        do {
            let hash = try PartialMD5.hash(fileAt: url)
            book.koreaderDocumentHash = hash
            try? context?.save()
            return hash
        } catch {
            #if DEBUG
            print("RHAPSODE-KOSYNC: hash failed \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Pull

    /// Fetch remote progress and apply per strategy. Call after the reader shell is ready.
    static func pullAndApply(
        book: Book,
        reader: FoliateWebReader?,
        context: ModelContext
    ) async -> PullOutcome {
        guard KOSyncSettings.isConfigured else { return .skipped }
        guard let client = KOSyncClient.fromSettings() else { return .skipped }
        guard let hash = documentHash(for: book, context: context) else {
            return .error("Couldn’t fingerprint this book for KOReader Sync.")
        }

        do {
            guard let remote = try await client.getProgress(documentHash: hash) else {
                return .noRemote
            }

            let strategy = KOSyncSettings.strategy
            let localFraction = book.fractionComplete
            let remoteFraction = remote.fraction ?? 0
            let remoteNewer = isRemoteNewer(remote, than: book.progressUpdatedAt)

            switch strategy {
            case .send:
                return .keptLocal
            case .receive:
                apply(remote: remote, to: book, reader: reader, context: context)
                return .appliedRemote
            case .silent:
                if remoteNewer {
                    apply(remote: remote, to: book, reader: reader, context: context)
                    return .appliedRemote
                }
                return .keptLocal
            case .prompt:
                if remoteNewer && abs(remoteFraction - localFraction) > 0.01 {
                    return .conflict(localFraction: localFraction, remote: remote)
                }
                if remoteNewer {
                    apply(remote: remote, to: book, reader: reader, context: context)
                    return .appliedRemote
                }
                return .keptLocal
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func apply(
        remote: KOSyncProgress,
        to book: Book,
        reader: FoliateWebReader?,
        context: ModelContext
    ) {
        let fraction = remote.fraction ?? 0
        let progressStr = remote.progress
        let json = FoliateProgress(
            cfi: progressStr.flatMap { isCFI($0) ? $0 : nil },
            locations: .init(totalProgression: fraction),
            kosyncProgress: progressStr
        ).jsonString

        book.readingLocator = json
        if let ts = remote.updatedAt {
            book.progressUpdatedAt = ts
        } else {
            book.progressUpdatedAt = Date()
        }
        try? context.save()

        // Navigate open reader: prefer CFI, else fraction.
        if let reader {
            if let p = progressStr, isCFI(p) {
                reader.applyRemoteLocator(json: json ?? "")
            } else if fraction > 0 {
                reader.applyRemoteFraction(fraction)
            }
        }
    }

    // MARK: - Push

    static func push(book: Book, context: ModelContext) async {
        guard KOSyncSettings.isConfigured else { return }
        if KOSyncSettings.strategy == .receive { return }
        guard let client = KOSyncClient.fromSettings() else { return }
        guard let hash = documentHash(for: book, context: context) else { return }

        let fraction = book.fractionComplete
        let cfi = FoliateProgress.cfi(fromLocatorJSON: book.readingLocator)
        let stored = FoliateProgress.parse(book.readingLocator ?? "")?.kosyncProgress
        // Wire progress: prefer last KOSync string (xpointer), else CFI, else percentage token.
        let progress: String
        if let stored, !stored.isEmpty {
            progress = stored
        } else if let cfi, !cfi.isEmpty {
            progress = cfi
        } else {
            progress = String(format: "%.6f", fraction)
        }

        do {
            try await client.updateProgress(
                documentHash: hash,
                progress: progress,
                percentage: fraction
            )
            #if DEBUG
            print("RHAPSODE-KOSYNC: pushed \(hash.prefix(8))… p=\(String(format: "%.3f", fraction))")
            #endif
        } catch {
            #if DEBUG
            print("RHAPSODE-KOSYNC: push failed \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private static func isRemoteNewer(_ remote: KOSyncProgress, than local: Date?) -> Bool {
        guard let remoteDate = remote.updatedAt else {
            // No timestamp — treat as newer only if we have no local stamp.
            return local == nil
        }
        guard let local else { return true }
        return remoteDate > local
    }

    static func isCFI(_ s: String) -> Bool {
        s.hasPrefix("epubcfi(") || s.hasPrefix("epubcfi")
    }

    static func isXPointer(_ s: String) -> Bool {
        s.hasPrefix("/body")
    }
}
