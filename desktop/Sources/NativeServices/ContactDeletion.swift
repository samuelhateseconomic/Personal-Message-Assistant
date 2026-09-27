import Foundation
import CryptoKit
import Darwin

public struct ContactDeletionTarget: Equatable, Sendable {
    public let snapshot: ContactSnapshot
    public let changeToken: Data
    public init(snapshot: ContactSnapshot, changeToken: Data) {
        self.snapshot = snapshot; self.changeToken = changeToken
    }
}
@MainActor public protocol ContactDeletionBackend {
    func accounts() throws -> [ContactAccount]
    func deletionTarget(_ id: String) throws -> ContactDeletionTarget
    func delete(_ target: ContactDeletionTarget) throws
    /// Only a successful, fully authorized query may establish absence.
    func isAbsent(_ id: String) throws -> Bool
}
extension SystemContactSyncBackend: ContactDeletionBackend {}

public enum ContactDeletionError: Error, LocalizedError {
    case dependentPlans, invalidReview, interrupted, cleanup, storage
    public var errorDescription: String? {
        switch self {
        case .dependentPlans: "This contact has active saved drafts. Cancel or change their recipients in Plans, then review deletion again."
        case .invalidReview: "This deletion review expired or is no longer valid. Review the contact again."
        case .interrupted: "Deletion was attempted but its result is not confirmed. Use Check result; the app will not send another delete request."
        case .cleanup: "The Apple Contacts card was deleted, but local notes could not be removed. Retry local cleanup only. Changed notes are preserved."
        case .storage: "The deletion receipt could not be read or saved. No new deletion will be attempted."
        }
    }
}
public struct ContactDeletionReview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: ContactDeletionTarget
    public let account: ContactAccount
    public let profile: ContactProfile?
    public let expiresAt: Date
}
public struct ContactDeletionReceipt: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case dispatched, deleted, complete, notDeleted }
    public let id: UUID
    public let contactID: String
    public let name: String
    public let account: ContactAccount
    public var profile: ContactProfile?
    public var state: State
}

/// A durable write-ahead receipt prevents native replay after a crash. Uses the existing
/// local Keychain key with a distinct authenticated-data domain; never stores plaintext.
@MainActor public struct ContactDeletionJournal {
    private struct Ledger: Codable { var version = 1; var receipts: [ContactDeletionReceipt] = [] }
    public let url: URL
    private let keys: any PlanKeyProvider
    private let domain = Data("MessageAssistant.contact-deletions.v1".utf8)
    public init(url: URL? = nil, keys: any PlanKeyProvider = KeychainPlanKey()) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MessageAssistant/contact-deletions.encrypted")
        self.keys = keys
    }
    public func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ContactDeletionError.storage }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ContactDeletionError.storage }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    // Caller holds locked() over read/write/native dispatch; functions are module-private.
    fileprivate func read() throws -> [ContactDeletionReceipt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 8 * 1024 * 1024 else { throw ContactDeletionError.storage }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(sealed, using: keys.key(createIfMissing: false), authenticating: domain)
        let ledger = try JSONDecoder().decode(Ledger.self, from: data)
        guard ledger.version == 1, Set(ledger.receipts.map(\.id)).count == ledger.receipts.count else { throw ContactDeletionError.storage }
        return ledger.receipts
    }
    fileprivate func write(_ receipts: [ContactDeletionReceipt]) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let bytes = try JSONEncoder().encode(Ledger(receipts: receipts))
        guard let sealed = try AES.GCM.seal(bytes, using: keys.key(createIfMissing: !exists), authenticating: domain).combined,
              sealed.count <= 8 * 1024 * 1024 else { throw ContactDeletionError.storage }
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor public final class ContactDeletionService {
    private let backend: any ContactDeletionBackend
    private let profiles: ContactProfileStore
    private let journal: ContactDeletionJournal
    private let plans: PlanRepository
    private let isUnlocked: () -> Bool
    private var issued: [UUID: ContactDeletionReview] = [:]
    public init(backend: any ContactDeletionBackend = SystemContactSyncBackend(), profiles: ContactProfileStore = ContactProfileStore(),
                journal: ContactDeletionJournal = ContactDeletionJournal(), plans: PlanRepository, isUnlocked: @escaping () -> Bool) {
        self.backend = backend; self.profiles = profiles; self.journal = journal; self.plans = plans; self.isUnlocked = isUnlocked
    }
    public func invalidate() { issued = [:] }
    private func authorize() throws { guard isUnlocked() else { throw ContactSyncError.locked } }
    public func pending() throws -> [ContactDeletionReceipt] {
        try authorize()
        return try journal.locked { try journal.read().filter { $0.state == .dispatched || $0.state == .deleted } }
    }
    public func prepare(_ contactID: String, now: Date = Date()) throws -> ContactDeletionReview {
        try authorize()
        return try plans.withoutActivePlans(for: contactID) {
            try journal.locked {
                guard try !journal.read().contains(where: { $0.contactID == contactID && ($0.state == .dispatched || $0.state == .deleted) }) else {
                    throw ContactDeletionError.interrupted
                }
                let target = try backend.deletionTarget(contactID)
                guard let account = try backend.accounts().first(where: { $0.id == target.snapshot.accountID }) else { throw ContactSyncError.account }
                let review = ContactDeletionReview(id: UUID(), target: target, account: account,
                    profile: try profiles.load()["mac:" + contactID], expiresAt: now.addingTimeInterval(120))
                issued = issued.filter { $0.value.expiresAt > now }; issued[review.id] = review
                return review
            }
        }
    }
    public func confirm(_ review: ContactDeletionReview, now: Date = Date()) throws {
        try authorize()
        guard issued[review.id] == review, now < review.expiresAt else { throw ContactDeletionError.invalidReview }
        try plans.withoutActivePlans(for: review.target.snapshot.id) {
            try journal.locked {
                var receipts = try journal.read()
                guard !receipts.contains(where: { $0.contactID == review.target.snapshot.id && ($0.state == .dispatched || $0.state == .deleted) }) else {
                    throw ContactDeletionError.interrupted
                }
                guard try backend.deletionTarget(review.target.snapshot.id) == review.target,
                      try profiles.load()["mac:" + review.target.snapshot.id] == review.profile,
                      try backend.accounts().contains(review.account) else { throw ContactSyncError.changed }
                let index = receipts.count
                receipts.append(ContactDeletionReceipt(id: review.id, contactID: review.target.snapshot.id,
                    name: review.target.snapshot.fields.name, account: review.account, profile: review.profile, state: .dispatched))
                try journal.write(receipts) // Must succeed before any native side effect.
                issued.removeValue(forKey: review.id)
                do {
                    try backend.delete(review.target)
                    guard try backend.isAbsent(review.target.snapshot.id) else { throw ContactDeletionError.interrupted }
                } catch { throw ContactDeletionError.interrupted }
                receipts[index].state = .deleted
                try journal.write(receipts)
                try finish(index, receipts: &receipts)
            }
        }
    }
    /// Recovery never calls delete. Absence verification and annotation cleanup are separate
    /// from native dispatch, including after service/app recreation.
    @discardableResult public func recover(_ id: UUID) throws -> ContactDeletionReceipt.State {
        try authorize()
        return try journal.locked {
            var receipts = try journal.read()
            guard let index = receipts.firstIndex(where: { $0.id == id }) else { throw ContactDeletionError.invalidReview }
            if receipts[index].state == .complete || receipts[index].state == .notDeleted { return receipts[index].state }
            if receipts[index].state == .dispatched || receipts[index].state == .deleted {
                if try backend.isAbsent(receipts[index].contactID) { receipts[index].state = .deleted }
                else { receipts[index].state = .notDeleted; receipts[index].profile = nil }
                try journal.write(receipts)
            }
            if receipts[index].state == .deleted { try finish(index, receipts: &receipts) }
            return receipts[index].state
        }
    }
    private func finish(_ index: Int, receipts: inout [ContactDeletionReceipt]) throws {
        do {
            let id = "mac:" + receipts[index].contactID
            // Already-absent annotations are safe after an interrupted atomic cleanup.
            if try profiles.load()[id] != nil { try profiles.remove(id, expected: receipts[index].profile) }
            receipts[index].state = .complete; receipts[index].profile = nil
            try journal.write(receipts)
        } catch { throw ContactDeletionError.cleanup }
    }
}
