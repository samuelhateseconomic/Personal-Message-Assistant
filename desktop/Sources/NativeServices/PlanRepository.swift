import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin
import Combine
import AssistantCore

public enum PlanStorageError: Error, LocalizedError {
    case locked, unavailable, version, invalid, missing, stale
    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock the workspace to access saved plans."
        case .unavailable: "Saved plans could not be opened or updated. Check Keychain access and local storage, then retry."
        case .version: "This plan file uses an unsupported version. Update the app; the file has not been replaced."
        case .invalid: "The plan is invalid or its identifier conflicts with an existing plan."
        case .stale: "The saved plan changed or was cancelled. Refresh it and review your edit again."
        case .missing: "This saved plan no longer exists. Refresh the plan list."
        }
    }
}
public struct StoredPlan: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case draftOnly, cancelled }
    public let id: UUID
    public var snapshot: Review
    public let createdAt: Date
    public var status: Status
    public var revision: Int
    public var timezone: String?
    public init(id: UUID, snapshot: Review, createdAt: Date, status: Status, revision: Int = 1, timezone: String? = nil) {
        self.id = id; self.snapshot = snapshot; self.createdAt = createdAt; self.status = status
        self.revision = revision; self.timezone = timezone
    }
    private enum CodingKeys: String, CodingKey { case id, snapshot, createdAt, status, revision, timezone }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(Review.self, forKey: .snapshot)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? snapshot.id
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status = try values.decode(Status.self, forKey: .status)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        timezone = try values.decodeIfPresent(String.self, forKey: .timezone)
    }
}
public struct PlanOperationReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let planID: UUID
    public let revision: Int
    public let digest: String
    public let completedAt: Date
}
@MainActor public protocol PlanKeyProvider {
    func key(createIfMissing: Bool) throws -> SymmetricKey
}
@MainActor public struct KeychainPlanKey: PlanKeyProvider {
    private let service: String
    public init(service: String = "local.messageassistant.prototype.plan-ledger") { self.service = service }
    public func key(createIfMissing: Bool) throws -> SymmetricKey {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "AES256-v1"]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, createIfMissing else { throw PlanStorageError.unavailable }
        let generated = SymmetricKey(size: .bits256)
        var item = identity
        item[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(createIfMissing: false) }
        guard added == errSecSuccess else { throw PlanStorageError.unavailable }
        return generated
    }
}

/// Authenticated encryption; the lock file serializes cooperating app processes.
@MainActor public struct EncryptedPlanStore {
    private struct Ledger: Codable {
        var version = 2
        var plans: [StoredPlan] = []
        var receipts: [PlanOperationReceipt] = []
        init() {}
        private enum CodingKeys: String, CodingKey { case version, plans, receipts }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            plans = try values.decode([StoredPlan].self, forKey: .plans)
            receipts = try values.decodeIfPresent([PlanOperationReceipt].self, forKey: .receipts) ?? []
        }
    }
    private struct Envelope: Codable { let version: Int; let sealed: Data }
    public let url: URL
    private let keys: any PlanKeyProvider
    private let associatedData = Data("MessageAssistant.plan-ledger.v1".utf8)
    public init(url: URL? = nil, keys: any PlanKeyProvider = KeychainPlanKey()) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MessageAssistant/plans-v1.encrypted")
        self.keys = keys
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PlanStorageError.unavailable }
        defer { _ = Darwin.close(descriptor) }
        // Do not block the UI indefinitely if another process is using the file.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw PlanStorageError.unavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func read() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 8 * 1024 * 1024 else { throw PlanStorageError.unavailable }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else { throw PlanStorageError.version }
        let key = try keys.key(createIfMissing: false)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: associatedData)
        let ledger = try JSONDecoder().decode(Ledger.self, from: data)
        guard ledger.version == 1 || ledger.version == 2 else { throw PlanStorageError.version }
        guard Set(ledger.plans.map(\.id)).count == ledger.plans.count, ledger.plans.allSatisfy({ $0.revision > 0 }),
              Set(ledger.receipts.map(\.operationID)).count == ledger.receipts.count else { throw PlanStorageError.invalid }
        return ledger
    }
    private func write(_ ledger: Ledger) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let key = try keys.key(createIfMissing: !exists)
        var upgraded = ledger
        upgraded.version = 2
        let plain = try JSONEncoder().encode(upgraded)
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: associatedData).combined else { throw PlanStorageError.unavailable }
        let encoded = try JSONEncoder().encode(Envelope(version: 1, sealed: sealed))
        guard encoded.count <= 8 * 1024 * 1024 else { throw PlanStorageError.unavailable }
        if exists && ledger.version == 1 {
            let original = try Data(contentsOf: url)
            let backup = url.appendingPathExtension("schema1-backup")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == original else { throw PlanStorageError.unavailable }
            } else {
                try original.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        // Only encrypted bytes reach disk, including Foundation's atomic temporary file.
        try encoded.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load() throws -> [StoredPlan] { try locked { try read().plans } }
    public func withoutActivePlans<T>(for nativeID: String, operation: () throws -> T) throws -> T {
        try locked {
            guard try !read().plans.contains(where: { $0.status == .draftOnly && $0.snapshot.recipient.nativeID == nativeID }) else {
                throw ContactDeletionError.dependentPlans
            }
            return try operation()
        }
    }
    public static func digest(_ mutation: PlanMutation) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(mutation)).map { String(format: "%02x", $0) }.joined()
    }
    public func apply(_ mutation: PlanMutation, now: Date = Date()) throws -> [StoredPlan] {
        try locked {
            var ledger = try read()
            let digest = try Self.digest(mutation)
            if let receipt = ledger.receipts.first(where: { $0.operationID == mutation.operationID }) {
                guard receipt.digest == digest else { throw PlanStorageError.invalid }
                return ledger.plans
            }
            if mutation.kind != .cancel {
                guard let review = mutation.review, review.date > now,
                      !review.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      review.message.count <= 2000, !review.message.contains("\0"), !review.recipient.address.isEmpty,
                      let zone = mutation.timezone, TimeZone(identifier: zone) != nil else { throw PlanStorageError.invalid }
            }
            switch mutation.kind {
            case .create:
                guard let review = mutation.review, mutation.expectedRevision == nil else { throw PlanStorageError.invalid }
                if let existing = ledger.plans.first(where: { $0.id == mutation.planID }) {
                    guard existing.snapshot == review else { throw PlanStorageError.invalid }
                    return ledger.plans // Legacy retry cannot reactivate a cancelled record.
                }
                ledger.plans.append(StoredPlan(id: mutation.planID, snapshot: review, createdAt: now,
                                               status: .draftOnly, timezone: mutation.timezone))
            case .update, .cancel:
                guard let index = ledger.plans.firstIndex(where: { $0.id == mutation.planID }) else { throw PlanStorageError.missing }
                guard ledger.plans[index].revision == mutation.expectedRevision,
                      ledger.plans[index].status == .draftOnly else { throw PlanStorageError.stale }
                if mutation.kind == .update {
                    guard let review = mutation.review else { throw PlanStorageError.invalid }
                    ledger.plans[index].snapshot = review; ledger.plans[index].timezone = mutation.timezone
                } else {
                    guard mutation.review == nil else { throw PlanStorageError.invalid }
                    ledger.plans[index].status = .cancelled
                }
                ledger.plans[index].revision += 1
            }
            let changed = ledger.plans.first { $0.id == mutation.planID }!
            ledger.receipts.append(PlanOperationReceipt(operationID: mutation.operationID, planID: mutation.planID,
                revision: changed.revision, digest: digest, completedAt: now))
            try write(ledger)
            return ledger.plans
        }
    }
    public func add(_ review: Review, now: Date = Date()) throws -> [StoredPlan] {
        try apply(PlanMutation(operationID: review.id, kind: .create, planID: review.id,
                               review: review, timezone: TimeZone.current.identifier), now: now)
    }
    public func cancel(_ id: UUID) throws -> [StoredPlan] {
        guard let plan = try load().first(where: { $0.id == id }) else { throw PlanStorageError.missing }
        if plan.status == .cancelled { return try load() }
        return try apply(PlanMutation(kind: .cancel, planID: id, expectedRevision: plan.revision))
    }

}

@MainActor public final class PlanRepository: ObservableObject {
    @Published public private(set) var plans: [StoredPlan] = []
    @Published public private(set) var ready = false
    @Published public private(set) var errorMessage = ""
    private let store: EncryptedPlanStore
    private let isUnlocked: () -> Bool
    public init(store: EncryptedPlanStore = EncryptedPlanStore(), isUnlocked: @escaping () -> Bool) {
        self.store = store; self.isUnlocked = isUnlocked
    }
    private func requireUnlocked() throws { guard isUnlocked() else { throw PlanStorageError.locked } }
    public func lock() { plans = []; ready = false; errorMessage = "" }
    public func refresh() {
        do { try requireUnlocked(); plans = try store.load(); ready = true; errorMessage = "" }
        catch { plans = []; ready = false; errorMessage = message(error) }
    }
    public func confirm(_ review: Review, workspace: inout Workspace, now: Date = Date()) throws {
        try requireUnlocked()
        guard ready else { throw PlanStorageError.unavailable }
        var candidate = workspace
        try candidate.addPlan(review, now: now)
        // No await between authorization, persistence, and committing the new composer state.
        do {
            plans = try store.add(review, now: now)
            workspace = candidate
            errorMessage = ""
        } catch { errorMessage = message(error); throw PlanStorageError.unavailable }
    }
    public func cancel(_ id: UUID) throws {
        try requireUnlocked()
        do { plans = try store.cancel(id); errorMessage = "" }
        catch { errorMessage = message(error); throw PlanStorageError.unavailable }
    }
    public func current(_ id: UUID) throws -> StoredPlan {
        try requireUnlocked()
        guard let plan = try store.load().first(where: { $0.id == id }) else { throw PlanStorageError.missing }
        return plan
    }
    public func withoutActivePlans<T>(for nativeID: String, operation: () throws -> T) throws -> T {
        try requireUnlocked()
        guard ready else { throw PlanStorageError.unavailable }
        return try store.withoutActivePlans(for: nativeID, operation: operation)
    }
    public func execute(_ mutation: PlanMutation, workspace: inout Workspace, now: Date = Date()) throws {
        try requireUnlocked()
        guard ready else { throw PlanStorageError.unavailable }
        var candidate = workspace
        if let review = mutation.review { try candidate.addPlan(review, now: now) }
        do {
            plans = try store.apply(mutation, now: now)
            workspace = candidate; errorMessage = ""
        } catch let error as PlanStorageError { errorMessage = message(error); throw error }
        catch { errorMessage = message(error); throw PlanStorageError.unavailable }
    }
    private func message(_ error: any Error) -> String {
        (error as? PlanStorageError)?.localizedDescription ?? PlanStorageError.unavailable.localizedDescription
    }
}
