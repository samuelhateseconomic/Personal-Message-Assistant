import AppKit
import Combine
import Contacts
import LocalAuthentication
import SwiftUI

@MainActor
public protocol Authenticator: AnyObject {
    func available() -> Bool
    func authenticate() async throws -> Bool
    func invalidate()
}

@MainActor
public final class SystemAuthenticator: Authenticator {
    private let context = LAContext()
    public init() {}
    public func available() -> Bool { context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }
    public func authenticate() async throws -> Bool {
        try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Unlock the Message Assistant workspace.")
    }
    public func invalidate() { context.invalidate() }
}

/// OS authentication for this feasibility build, not the final production broker.
@MainActor
public final class NativeSession: ObservableObject {
    @Published public private(set) var unlocked = false
    @Published public private(set) var authenticating = false
    @Published public private(set) var status = "Unlock with macOS to continue."
    private var context: (any Authenticator)?
    private let makeAuthenticator: @MainActor () -> any Authenticator
    private var generation = 0
    private var expiry: Task<Void, Never>?
    private var observers: [AnyCancellable] = []

    public init(makeAuthenticator: @escaping @MainActor () -> any Authenticator = { SystemAuthenticator() }) {
        self.makeAuthenticator = makeAuthenticator
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.lock() } }
                .store(in: &observers)
        }
    }
    public func lock() {
        generation += 1
        context?.invalidate(); context = nil
        expiry?.cancel(); expiry = nil
        unlocked = false; authenticating = false
        status = "Workspace locked."
    }
    public func unlock() async {
        guard !authenticating else { return }
        generation += 1
        let attempt = generation
        let candidate = makeAuthenticator()
        guard candidate.available() else {
            status = "System authentication is unavailable. Check your Mac login settings."
            return
        }
        context = candidate; authenticating = true
        do {
            let accepted = try await candidate.authenticate()
            guard generation == attempt else { return }
            authenticating = false; context = nil
            unlocked = accepted
            status = accepted ? "Authenticated by macOS." : "Authentication was not completed."
            if accepted {
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) }
                    catch { return }
                    self?.lock()
                }
            }
        } catch {
            guard generation == attempt else { return }
            authenticating = false; context = nil; unlocked = false
            status = "Authentication cancelled or unsuccessful. Try again when ready."
        }
    }
}

public struct NativeContactRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let phones: [String]
    public let emails: [String]
}

@MainActor
public final class NativeContacts: ObservableObject {
    @Published public private(set) var rows: [NativeContactRow] = []
    @Published public private(set) var status = "Not connected. Access is requested only when you choose Connect."
    @Published public private(set) var loading = false
    @Published public private(set) var isConnected = false
    private var generation = 0
    private var enabled = false
    private var observer: AnyCancellable?

    public init() {
        observer = NotificationCenter.default.publisher(for: .CNContactStoreDidChange)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.enabled else { return }
                    await self.load(requestPermission: false)
                }
            }
    }
    public func clear() {
        generation += 1; enabled = false; rows = []; loading = false; isConnected = false
        status = "Not connected. Access is requested only when you choose Connect."
    }
    public func load(requestPermission: Bool) async {
        generation += 1
        let attempt = generation
        loading = true; isConnected = false
        rows = []
        do {
            if requestPermission && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                let granted = try await CNContactStore().requestAccess(for: .contacts)
                guard generation == attempt else { return }
                guard granted else {
                    loading = false; enabled = false
                    status = "Contacts access was not granted. Enable it in Privacy & Security if desired."
                    return
                }
            }
            let authorization = CNContactStore.authorizationStatus(for: .contacts)
            guard authorization != .denied && authorization != .restricted && authorization != .notDetermined else {
                enabled = false; loading = false
                status = "Contacts access is unavailable. Check System Settings → Privacy & Security → Contacts."
                return
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let store = CNContactStore()
                let request = CNContactFetchRequest(keysToFetch: [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor
                ])
                request.unifyResults = false
                var result: [NativeContactRow] = []
                try store.enumerateContacts(with: request) { contact, _ in
                    let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    result.append(NativeContactRow(id: contact.identifier,
                        name: name.isEmpty ? (contact.organizationName.isEmpty ? "Unnamed contact" : contact.organizationName) : name,
                        phones: contact.phoneNumbers.map { $0.value.stringValue },
                        emails: contact.emailAddresses.map { $0.value as String }))
                }
                return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value
            guard generation == attempt else { return }
            rows = result; loading = false; enabled = true; isConnected = true
            status = "Contacts connection active. Names, phone numbers, and email addresses refresh when Mac Contacts changes."
        } catch {
            guard generation == attempt else { return }
            rows = []; loading = false; enabled = false
            status = "Could not read Contacts. Check permission and try again."
        }
    }
}
