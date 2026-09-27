import Foundation
import Combine
import CryptoKit
import Darwin

public struct WritingStyle: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, CaseIterable, Sendable { case neutral, warm, professional, casual }
    public enum Length: String, Codable, CaseIterable, Sendable { case brief, standard }
    public enum Emoji: String, Codable, CaseIterable, Sendable { case none, light }
    public var tone: Tone = .neutral
    public var length: Length = .brief
    public var emoji: Emoji = .none
    public init() {}
    public var summary: String { "\(tone.rawValue.capitalized) tone · \(length.rawValue) length · \(emoji == .none ? "no emoji" : "light emoji use")" }
}
public struct WritingPreferenceRecord: Codable, Equatable, Sendable {
    public let revision: UUID
    public let style: WritingStyle?
    public let updatedAt: Date
}
public enum WritingPreferenceError: Error, LocalizedError {
    case locked, unavailable, stale
    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock the workspace to access writing preferences."
        case .unavailable: "Writing preferences could not be read or the save confirmed. Check Keychain access and local storage, then reload before retrying."
        case .stale: "Saved preferences changed. Reload them before saving or generating again. Your edits have been kept."
        }
    }
}
/// Only explicit native saves populate this store. A tombstone preserves revision checks
/// after Forget. This is separate from contacts, plans and the legacy Python memory store.
@MainActor public struct WritingPreferenceStore {
    private struct Ledger: Codable { let version: Int; let record: WritingPreferenceRecord }
    public let url: URL
    private let keys: any PlanKeyProvider
    private let isUnlocked: () -> Bool
    private let domain = Data("MessageAssistant.writing-preferences.v1".utf8)
    public init(url: URL? = nil, keys: any PlanKeyProvider = KeychainPlanKey(service: "local.messageassistant.prototype.writing-preferences"), isUnlocked: @escaping () -> Bool) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MessageAssistant/writing-preferences.encrypted")
        self.keys = keys; self.isUnlocked = isUnlocked
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        guard isUnlocked() else { throw WritingPreferenceError.locked }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw WritingPreferenceError.unavailable }
            defer { _ = Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw WritingPreferenceError.unavailable }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try operation()
        } catch let error as WritingPreferenceError { throw error }
        catch { throw WritingPreferenceError.unavailable }
    }
    private func read() throws -> WritingPreferenceRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16_384 else { throw WritingPreferenceError.unavailable }
        let encrypted = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let plain = try AES.GCM.open(encrypted, using: keys.key(createIfMissing: false), authenticating: domain)
        let ledger = try JSONDecoder().decode(Ledger.self, from: plain)
        guard ledger.version == 1 else { throw WritingPreferenceError.unavailable }
        return ledger.record
    }
    public func load() throws -> WritingPreferenceRecord? { try locked { try read() } }
    public func save(_ style: WritingStyle?, expected: WritingPreferenceRecord?) throws -> WritingPreferenceRecord {
        try locked {
            guard try read() == expected else { throw WritingPreferenceError.stale }
            let record = WritingPreferenceRecord(revision: UUID(), style: style, updatedAt: Date())
            let bytes = try JSONEncoder().encode(Ledger(version: 1, record: record))
            let key = try keys.key(createIfMissing: !FileManager.default.fileExists(atPath: url.path))
            guard let encrypted = try AES.GCM.seal(bytes, using: key, authenticating: domain).combined else { throw WritingPreferenceError.unavailable }
            try encrypted.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard try read() == record else { throw WritingPreferenceError.unavailable }
            return record
        }
    }
}
@MainActor public final class WritingPreferencesController: ObservableObject {
    @Published public var edited = WritingStyle()
    @Published public private(set) var record: WritingPreferenceRecord?
    @Published public private(set) var ready = false
    @Published public private(set) var status = ""
    @Published public private(set) var failed = false
    private let store: WritingPreferenceStore
    public init(store: WritingPreferenceStore) { self.store = store }
    public var dirty: Bool { record?.style != edited }
    public func refresh() {
        do {
            record = try store.load(); edited = record?.style ?? WritingStyle(); ready = true; status = ""; failed = false
        } catch { ready = false; status = error.localizedDescription; failed = true }
    }
    public func save() { persist(edited) }
    public func forget() { persist(nil) }
    private func persist(_ style: WritingStyle?) {
        guard ready else { return }
        do {
            record = try store.save(style, expected: record); edited = style ?? WritingStyle()
            failed = false; status = style == nil ? "Writing preferences forgotten. Future drafts will not use them." : "Writing preferences saved successfully. Choose whether to use them in each draft."
        } catch { failed = true; status = error.localizedDescription }
    }
    public func validate(_ expected: WritingPreferenceRecord) throws {
        guard try store.load() == expected else { throw WritingPreferenceError.stale }
    }
    public func clear() { record = nil; edited = WritingStyle(); ready = false; status = ""; failed = false }
}
