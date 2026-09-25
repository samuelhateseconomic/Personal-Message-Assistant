import Foundation
import Contacts

public struct ContactAccount: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct ContactFields: Equatable, Sendable {
    public var givenName = ""
    public var familyName = ""
    public var phones: [String] = []
    public var emails: [String] = []
    public var birthday: DateComponents?
    public init() {}
    public var name: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
}
public struct ContactSnapshot: Equatable, Sendable {
    public let id: String
    public let accountID: String
    public var fields: ContactFields
    public init(id: String, accountID: String, fields: ContactFields) {
        self.id = id; self.accountID = accountID; self.fields = fields
    }
}
public enum ContactSyncError: Error, LocalizedError {
    case locked, access, unavailable, account, invalid, changed, conflict([String]), uncertain, verifiedWritePendingLocal
    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock the workspace before saving."
        case .access: "Connect to Apple Contacts and grant access first."
        case .unavailable: "This contact is unavailable or has no single writable source. Refresh the list or use Apple Contacts."
        case .account: "Choose an available destination account. The account must allow contact creation."
        case .invalid: "Enter a first or last name."
        case .changed: "The contact changed after review. Review the latest details again."
        case .conflict(let fields): "Both apps changed: \(fields.joined(separator: ", ")). Reload the current contact, then reapply your edits. Your entries have been kept."
        case .uncertain: "The save result could not be confirmed. Refresh Apple Contacts before trying another save; this request will not be repeated."
        case .verifiedWritePendingLocal: "Apple Contacts was saved, but local notes could not be saved. Retry local notes only."
        }
    }
}
public struct ContactSaveReview: Identifiable, Sendable {
    public let id = UUID()
    public let base: ContactSnapshot?
    public let account: ContactAccount
    public let fields: ContactFields
    public let changedFields: [String]
}

/// Serializes this app's saves. External Contacts writers are not locked by this service.
@MainActor public protocol ContactSyncBackend {
    func accounts() throws -> [ContactAccount]
    func fetch(_ id: String) throws -> ContactSnapshot
    func create(_ fields: ContactFields, accountID: String) throws -> ContactSnapshot
    func update(_ snapshot: ContactSnapshot, fields: ContactFields) throws -> ContactSnapshot
}
@MainActor public final class ContactSyncService {
    private let backend: any ContactSyncBackend
    private let isUnlocked: () -> Bool
    private var attempted = Set<UUID>()
    public init(backend: any ContactSyncBackend = SystemContactSyncBackend(), isUnlocked: @escaping () -> Bool) {
        self.backend = backend; self.isUnlocked = isUnlocked
    }
    public func accounts() throws -> [ContactAccount] { try requireUnlocked(); return try backend.accounts() }
    public func fetch(_ id: String) throws -> ContactSnapshot { try requireUnlocked(); return try backend.fetch(id) }
    private func requireUnlocked() throws { guard isUnlocked() else { throw ContactSyncError.locked } }
    public static func differences(_ a: ContactFields, _ b: ContactFields) -> [String] {
        var result: [String] = []
        if a.givenName != b.givenName { result.append("First name") }
        if a.familyName != b.familyName { result.append("Last name") }
        if a.phones != b.phones { result.append("Phone numbers") }
        if a.emails != b.emails { result.append("Email addresses") }
        if a.birthday != b.birthday { result.append("Birthday") }
        return result
    }
    public static func merge(base: ContactFields, edited: ContactFields, current: ContactFields) throws -> ContactFields {
        var conflicts: [String] = []
        func field<T: Equatable>(_ b: T, _ e: T, _ c: T, _ label: String) -> T {
            if e == b { return c }
            if c == b || c == e { return e }
            conflicts.append(label); return e
        }
        var result = current
        result.givenName = field(base.givenName, edited.givenName, current.givenName, "First name")
        result.familyName = field(base.familyName, edited.familyName, current.familyName, "Last name")
        result.phones = field(base.phones, edited.phones, current.phones, "Phone numbers")
        result.emails = field(base.emails, edited.emails, current.emails, "Email addresses")
        result.birthday = field(base.birthday, edited.birthday, current.birthday, "Birthday")
        guard conflicts.isEmpty else { throw ContactSyncError.conflict(conflicts) }
        return result
    }
    public func review(base: ContactSnapshot?, edited: ContactFields, accountID: String) throws -> ContactSaveReview {
        try requireUnlocked()
        guard !edited.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContactSyncError.invalid }
        let accounts = try backend.accounts()
        guard let account = accounts.first(where: { $0.id == (base?.accountID ?? accountID) }) else { throw ContactSyncError.account }
        if let base {
            let fresh = try backend.fetch(base.id)
            guard fresh.accountID == base.accountID else { throw ContactSyncError.changed }
            let merged = try Self.merge(base: base.fields, edited: edited, current: fresh.fields)
            return ContactSaveReview(base: fresh, account: account, fields: merged, changedFields: Self.differences(fresh.fields, merged))
        }
        return ContactSaveReview(base: nil, account: account, fields: edited, changedFields: Self.differences(ContactFields(), edited))
    }
    public func commit(_ review: ContactSaveReview) throws -> ContactSnapshot {
        try requireUnlocked()
        guard !attempted.contains(review.id) else { throw ContactSyncError.uncertain }
        guard try backend.accounts().contains(where: { $0.id == review.account.id }) else { throw ContactSyncError.account }
        if let base = review.base {
            guard try backend.fetch(base.id) == base else { throw ContactSyncError.changed }
        }
        // Once dispatched, never replay this exact operation, even after an ambiguous OS failure.
        attempted.insert(review.id)
        do {
            let saved: ContactSnapshot
            if let base = review.base {
                saved = review.changedFields.isEmpty ? base : try backend.update(base, fields: review.fields)
            } else { saved = try backend.create(review.fields, accountID: review.account.id) }
            let verified = try backend.fetch(saved.id)
            guard verified.fields == review.fields, verified.accountID == review.account.id else { throw ContactSyncError.uncertain }
            return verified
        } catch {
            // A failure after dispatch may follow a successful native write. Never invite an automatic retry.
            throw ContactSyncError.uncertain
        }
    }
}

@MainActor public final class SystemContactSyncBackend: ContactSyncBackend {
    private let store = CNContactStore()
    private static let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey].map { $0 as CNKeyDescriptor }
    public init() {}
    private func checkAccess() throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status != .denied && status != .restricted && status != .notDetermined else { throw ContactSyncError.access }
    }
    public func accounts() throws -> [ContactAccount] {
        try checkAccess()
        return try store.containers(matching: nil).map { ContactAccount(id: $0.identifier, name: $0.name.isEmpty ? "Contacts account" : $0.name) }
    }
    private func raw(_ id: String) throws -> CNContact {
        try checkAccess()
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        request.unifyResults = false
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        var matches: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in if contact.identifier == id { matches.append(contact) } }
        guard matches.count == 1 else { throw ContactSyncError.unavailable }
        return matches[0]
    }
    private func snapshot(_ contact: CNContact) throws -> ContactSnapshot {
        let containers = try store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: contact.identifier))
        guard containers.count == 1 else { throw ContactSyncError.unavailable }
        var fields = ContactFields()
        fields.givenName = contact.givenName; fields.familyName = contact.familyName
        fields.phones = contact.phoneNumbers.map { $0.value.stringValue }
        fields.emails = contact.emailAddresses.map { $0.value as String }
        fields.birthday = contact.birthday
        return ContactSnapshot(id: contact.identifier, accountID: containers[0].identifier, fields: fields)
    }
    public func fetch(_ id: String) throws -> ContactSnapshot { try snapshot(raw(id)) }
    private func apply(_ fields: ContactFields, to contact: CNMutableContact, old: ContactFields?) {
        if old?.givenName != fields.givenName { contact.givenName = fields.givenName }
        if old?.familyName != fields.familyName { contact.familyName = fields.familyName }
        if old?.phones != fields.phones {
            // Preserve existing identifiers and labels by position; additional entries get a generic label.
            let previous = contact.phoneNumbers
            contact.phoneNumbers = fields.phones.enumerated().map { index, value in
                index < previous.count ? previous[index].settingValue(CNPhoneNumber(stringValue: value))
                    : CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: value))
            }
        }
        if old?.emails != fields.emails {
            let previous = contact.emailAddresses
            contact.emailAddresses = fields.emails.enumerated().map { index, value in
                index < previous.count ? previous[index].settingValue(value as NSString)
                    : CNLabeledValue(label: CNLabelOther, value: value as NSString)
            }
        }
        if old?.birthday != fields.birthday { contact.birthday = fields.birthday }
    }
    public func create(_ fields: ContactFields, accountID: String) throws -> ContactSnapshot {
        try checkAccess()
        let contact = CNMutableContact(); apply(fields, to: contact, old: nil)
        let request = CNSaveRequest(); request.add(contact, toContainerWithIdentifier: accountID)
        try store.execute(request)
        return try fetch(contact.identifier)
    }
    public func update(_ snapshot: ContactSnapshot, fields: ContactFields) throws -> ContactSnapshot {
        let current = try raw(snapshot.id)
        guard try self.snapshot(current) == snapshot else { throw ContactSyncError.changed }
        guard let mutable = current.mutableCopy() as? CNMutableContact else { throw ContactSyncError.unavailable }
        apply(fields, to: mutable, old: snapshot.fields)
        let request = CNSaveRequest(); request.update(mutable)
        try store.execute(request)
        return try fetch(snapshot.id)
    }
}
