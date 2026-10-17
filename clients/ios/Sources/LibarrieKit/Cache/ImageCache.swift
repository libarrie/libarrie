import Foundation

/// Thumbnails and previews on disk, keyed by account and immutable object
/// ID (never by URL), so they survive restarts and can be shown offline.
/// Stored in Caches (excluded from backups); cleared on sign-out or account
/// switch (section 6).
public actor ImageCache {
    public enum Variant: String, Sendable { case thumb, preview }

    private let root: URL
    private let api: APIClient
    private let accountId: String
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(api: APIClient, accountId: String, root: URL? = nil) {
        self.api = api
        self.accountId = accountId
        self.root = root ?? Self.defaultRoot()
    }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Images", directoryHint: .isDirectory)
    }

    /// Remove every account's cached images.
    public static func clearAll(root: URL = defaultRoot()) {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(objectId: String, variant: Variant) -> URL? {
        guard objectId.allSatisfy({ $0.isHexDigit || $0 == "-" }), accountId.allSatisfy({ $0.isHexDigit || $0 == "-" || $0.isLetter }) else {
            return nil
        }
        return root.appending(path: accountId).appending(path: "\(objectId)-\(variant.rawValue).jpg")
    }

    /// Bytes for a page image: from disk, or fetched once and stored.
    public func data(for page: Page, variant: Variant) async throws -> Data? {
        guard let objectId = page.imageObjectId,
              let path = variant == .thumb ? page.thumbnailUrl : page.previewUrl,
              let file = file(objectId: objectId, variant: variant)
        else { return nil }
        if let cached = try? Data(contentsOf: file) { return cached }
        let key = file.path
        if let running = inFlight[key] { return try await running.value }
        let api = self.api
        let task = Task { try await api.imageData(path: path) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
