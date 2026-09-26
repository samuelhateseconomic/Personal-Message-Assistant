import Foundation

public struct ContactProfile: Codable, Equatable, Sendable {
    public var name: String
    public var connection: String
    public var birthday: Date?
    public var note: String
    public var phone: String
    public var email: String
    public init(name: String, connection: String = "", birthday: Date? = nil, note: String = "", phone: String = "", email: String = "") {
        self.name = name; self.connection = connection; self.birthday = birthday; self.note = note
        self.phone = phone; self.email = email
    }
    private enum CodingKeys: String, CodingKey { case name, connection, birthday, note, phone, email }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        connection = try values.decode(String.self, forKey: .connection)
        birthday = try values.decodeIfPresent(Date.self, forKey: .birthday)
        note = try values.decode(String.self, forKey: .note)
        phone = try values.decodeIfPresent(String.self, forKey: .phone) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
    }

}

/// App-only annotations. Never writes to Apple's Contacts database or the repository.
public struct ContactProfileStore {
    public enum ValidationError: Error { case emptyName }
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MessageAssistant/contact-profiles.json")
    }
    public func load() throws -> [String: ContactProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ContactProfile].self, from: Data(contentsOf: url))
    }
    public func save(_ profile: ContactProfile, for id: String) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyName
        }
        // Read before writing so unreadable data cannot silently be replaced.
        var profiles = try load()
        profiles[id] = profile
        try write(profiles)
    }
    public func saveLinked(_ profile: ContactProfile, nativeID: String, replacing localID: String?) throws {
        var profiles = try load()
        profiles["mac:" + nativeID] = profile
        if let localID, localID.hasPrefix("local:") { profiles.removeValue(forKey: localID) }
        try write(profiles)
    }
    private func write(_ profiles: [String: ContactProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: .contactProfilesChanged, object: nil)
    }
    public func create(_ profile: ContactProfile) throws -> String {
        let id = "local:" + UUID().uuidString
        var value = profile
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(value, for: id)
        return id
    }
}
