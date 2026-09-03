import Foundation
import Security

/// Stable per-install id for true-sum stats. Lives in the Keychain so it survives
/// UserDefaults wipes. Not the KOReader device id.
enum ProgressDeviceIdentity {
    private static let service = "com.naufalmir.rhapsode.progress"
    private static let account = "deviceId"

    static var deviceId: String {
        if let existing = KeychainStringStore.load(service: service, account: account),
           !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        try? KeychainStringStore.save(id, service: service, account: account)
        return id
    }
}
