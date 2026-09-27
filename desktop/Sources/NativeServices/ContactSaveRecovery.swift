import Foundation
import CryptoKit
import Darwin

public struct ContactSaveReceipt: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case dispatched, verified, complete, notSaved, dismissed }
    public let id: UUID
    public let proposalID: UUID?
    public let account: ContactAccount
    public let fields: ContactFields
    public let originalID: String?
    public var saved: ContactSnapshot?
    public var profile: ContactProfile?
    public var expectedProfile: ContactProfile?
    public var localSource: String?
    public var expectedSource: ContactProfile?
    public var state: State
    public var pending: Bool { state == .dispatched || state == .verified }
}
public enum ContactSaveRecoveryError: Error, LocalizedError {
    case storage, pending, uncertain, changed, missing
    public var errorDescription: String? {
        switch self {
        case .storage: "The contact save receipt could not be read or confirmed. Check recovery before starting another save."
        case .pending: "An earlier contact save needs recovery. Resolve or explicitly dismiss it in Contacts before saving another card."
        case .uncertain: "The Apple Contacts result is unconfirmed. Check recovery; the app will not repeat this native save."
        case .changed: "This card or its local notes changed. Recovery will not overwrite them. Inspect the current details before continuing."
        case .missing: "This recovery record is no longer pending. Refresh recovery."
        }
    }
}
/// Separate encrypted write-ahead ledger. Dispatch receipts survive process death;
/// recovery methods never invoke create/update on the native backend.
@MainActor public struct ContactSaveJournal {
    private struct Ledger: Codable { let version: Int; var receipts: [ContactSaveReceipt] }
    public let url: URL
    private let keys: any PlanKeyProvider
    private let domain = Data("MessageAssistant.contact-saves.v1".utf8)
    public init(url: URL? = nil, keys: any PlanKeyProvider = KeychainPlanKey(service: "local.messageassistant.prototype.contact-saves")) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MessageAssistant/contact-saves.encrypted")
        self.keys = keys
    }
    fileprivate func locked<T>(_ operation: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ContactSaveRecoveryError.storage }
            defer { _ = Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ContactSaveRecoveryError.storage }
            defer { _ = flock(fd, LOCK_UN) }
            return try operation()
        } catch let error as ContactSaveRecoveryError { throw error }
        catch let error as ContactSyncError { throw error }
        catch { throw ContactSaveRecoveryError.storage }
    }
    fileprivate func read() throws -> [ContactSaveReceipt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 4 * 1024 * 1024 else { throw ContactSaveRecoveryError.storage }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: keys.key(createIfMissing: false), authenticating: domain)
        let ledger = try JSONDecoder().decode(Ledger.self, from: plain)
        guard ledger.version == 1, Set(ledger.receipts.map(\.id)).count == ledger.receipts.count else { throw ContactSaveRecoveryError.storage }
        return ledger.receipts
    }
    fileprivate func write(_ receipts: [ContactSaveReceipt]) throws {
        let bytes = try JSONEncoder().encode(Ledger(version: 1, receipts: receipts))
        guard let encrypted = try AES.GCM.seal(bytes, using: keys.key(createIfMissing: !FileManager.default.fileExists(atPath: url.path)), authenticating: domain).combined,
              encrypted.count <= 4 * 1024 * 1024 else { throw ContactSaveRecoveryError.storage }
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try read() == receipts else { throw ContactSaveRecoveryError.storage }
    }
}
@MainActor public final class ContactSaveCoordinator {
    private let contacts: ContactSyncService
    private let profiles: ContactProfileStore
    private let journal: ContactSaveJournal
    private let isUnlocked: () -> Bool
    public init(contacts: ContactSyncService, profiles: ContactProfileStore = ContactProfileStore(), journal: ContactSaveJournal = ContactSaveJournal(), isUnlocked: @escaping () -> Bool) {
        self.contacts = contacts; self.profiles = profiles; self.journal = journal; self.isUnlocked = isUnlocked
    }
    private func authorize() throws { guard isUnlocked() else { throw ContactSyncError.locked } }
    public func pending() throws -> [ContactSaveReceipt] {
        try authorize(); return try journal.locked { try journal.read().filter(\.pending) }
    }
    public func commit(_ review: ContactSaveReview, profile: ContactProfile, expectedProfile: ContactProfile?, localSource: String?, expectedSource: ContactProfile?, proposalID: UUID?) throws -> ContactSaveReceipt {
        try authorize()
        return try journal.locked {
            var receipts = try journal.read()
            guard !receipts.contains(where: { $0.id == review.id }) else { throw ContactSaveRecoveryError.uncertain }
            guard !receipts.contains(where: \.pending) else { throw ContactSaveRecoveryError.pending }
            let current = try profiles.load()
            let currentTarget = review.base.flatMap { current["mac:" + $0.id] }
            guard currentTarget == expectedProfile, localSource.flatMap({ current[$0] }) == expectedSource else { throw ContactSaveRecoveryError.changed }
            var receipt = ContactSaveReceipt(id: review.id, proposalID: proposalID, account: review.account, fields: review.fields,
                originalID: review.base?.id, saved: nil, profile: profile, expectedProfile: expectedProfile,
                localSource: localSource, expectedSource: expectedSource, state: .dispatched)
            if let localSource { guard localSource.hasPrefix("local:"), receipt.expectedSource != nil else { throw ContactSaveRecoveryError.changed } }
            receipts.append(receipt)
            try journal.write(receipts) // Confirm durability before the native operation.
            do {
                receipt.saved = try contacts.commit(review)
            } catch let error as ContactSyncError {
                if case .uncertain = error { throw ContactSaveRecoveryError.uncertain }
                else {
                    receipt.state = .notSaved; receipt.profile = nil; receipt.expectedProfile = nil; receipt.expectedSource = nil
                    receipts[receipts.count - 1] = receipt; try journal.write(receipts)
                    throw error
                }
            } catch { throw ContactSaveRecoveryError.uncertain }
            receipt.state = .verified; receipts[receipts.count - 1] = receipt
            try journal.write(receipts)
            return receipt
        }
    }
    /// Readback only. Creation with no captured native ID requires an explicit source-card
    /// selection in the recovery UI, followed by exact field/account verification.
    public func check(_ id: UUID, selectedID: String? = nil) throws -> ContactSaveReceipt {
        try authorize()
        return try journal.locked {
            var receipts = try journal.read()
            guard let index = receipts.firstIndex(where: { $0.id == id && $0.pending }) else { throw ContactSaveRecoveryError.missing }
            var receipt = receipts[index]
            let boundID = receipt.saved?.id ?? receipt.originalID
            if let boundID, let selectedID, selectedID != boundID { throw ContactSaveRecoveryError.changed }
            guard let target = boundID ?? selectedID else { throw ContactSaveRecoveryError.uncertain }
            let fresh = try contacts.fetch(target)
            guard fresh.id == target, fresh.accountID == receipt.account.id, fresh.fields == receipt.fields else { throw ContactSaveRecoveryError.changed }
            receipt.saved = fresh; receipt.state = .verified; receipts[index] = receipt
            try journal.write(receipts); return receipt
        }
    }
    public func finishNotes(_ id: UUID) throws -> ContactSaveReceipt {
        try authorize()
        return try journal.locked {
            var receipts = try journal.read()
            guard let index = receipts.firstIndex(where: { $0.id == id && $0.state == .verified }), let saved = receipts[index].saved,
                  let desired = receipts[index].profile else { throw ContactSaveRecoveryError.missing }
            let fresh = try contacts.fetch(saved.id)
            guard fresh == saved else { throw ContactSaveRecoveryError.changed }
            let current = try profiles.load()
            let value = current["mac:" + saved.id]
            guard value == receipts[index].expectedProfile || value == desired else { throw ContactSaveRecoveryError.changed }
            if let source = receipts[index].localSource {
                guard current[source] == receipts[index].expectedSource || (current[source] == nil && value == desired) else { throw ContactSaveRecoveryError.changed }
            }
            try profiles.saveLinked(desired, nativeID: saved.id, replacing: receipts[index].localSource)
            receipts[index].state = .complete
            receipts[index].profile = nil; receipts[index].expectedProfile = nil; receipts[index].expectedSource = nil
            try journal.write(receipts); return receipts[index]
        }
    }
    /// Explicit acknowledgement only: does not assert success, roll back, or retry anything.
    public func dismiss(_ id: UUID) throws {
        try authorize()
        try journal.locked {
            var receipts = try journal.read()
            guard let index = receipts.firstIndex(where: { $0.id == id && $0.pending }) else { throw ContactSaveRecoveryError.missing }
            receipts[index].state = .dismissed; receipts[index].profile = nil; receipts[index].expectedProfile = nil; receipts[index].expectedSource = nil
            try journal.write(receipts)
        }
    }
}
