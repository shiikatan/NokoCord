import Foundation

struct AccountSnapshot: Codable, Sendable {
    let version: Int
    let account: DiscordUser
    let guilds: [DiscordGuild]
    let savedAt: Date
}

actor AccountCache {
    private let file: URL
    private let now: @Sendable () -> Date
    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.nokocord.NokoCord", isDirectory: true)
        file = directory.appendingPathComponent("account-v1.json")
    }
    func save(account: DiscordUser, guilds: [DiscordGuild]) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(AccountSnapshot(version: 1, account: account, guilds: Array(guilds.prefix(2000)), savedAt: now()))
        guard data.count <= 2_097_152 else { throw TransportError.responseTooLarge }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var resource = file
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
    func load() throws -> AccountSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_097_152 else { try clear(); return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { try clear(); return nil }
        let snapshot: AccountSnapshot
        do { snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: data) }
        catch { try clear(); return nil }
        let age = snapshot.savedAt.timeIntervalSince(now())
        guard snapshot.version == 1, age > -86400,
              age < 60, snapshot.guilds.count <= 2000 else { try clear(); return nil }
        return snapshot
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
