import Foundation

/// Durable storage for captures: immutable image files plus a manifest
/// written atomically after every change, so a crash, relaunch or device
/// restore always sees a consistent state. Lives in Application Support
/// (included in device backups unless the user opts out); never stores
/// tokens or signed URLs' secrets beyond their short validity.
public actor CaptureStore {
    public let directory: URL
    private var manifest: Manifest
    private let now: @Sendable () -> Date

    private var manifestURL: URL { directory.appending(path: "manifest.json") }
    private var imagesURL: URL { directory.appending(path: "images", directoryHint: .isDirectory) }

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.directory = directory
        self.now = now
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appending(path: "images", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let url = directory.appending(path: "manifest.json")
        if let data = try? Data(contentsOf: url) {
            manifest = (try? JSONDecoder.manifest.decode(Manifest.self, from: data)) ?? Manifest()
        } else {
            manifest = Manifest()
        }
    }

    /// The default location in the app container.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Captures", directoryHint: .isDirectory)
    }

    // MARK: Reading

    public var items: [CaptureItem] {
        manifest.items.sorted { ($0.createdAt, $0.sequence) < ($1.createdAt, $1.sequence) }
    }

    public func item(_ id: UUID) -> CaptureItem? { manifest.items.first { $0.id == id } }

    public func decision(for batch: UUID) -> DeferredDecision? { manifest.decisions[batch] }

    /// The file for an item. Paths are relative to the capture directory, so
    /// they stay valid after restore into a new container; names are
    /// validated so a tampered manifest cannot point outside it.
    public func fileURL(for item: CaptureItem) -> URL? {
        let name = item.fileName
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else { return nil }
        return imagesURL.appending(path: name)
    }

    /// The file exists and still has the recorded size and checksum.
    public func verifyFile(of item: CaptureItem) -> Bool {
        guard let url = fileURL(for: item), let data = try? Data(contentsOf: url) else { return false }
        return data.count == item.byteCount && ImagePreparer.sha256Hex(data) == item.sha256
    }

    // MARK: Writing

    /// Save a prepared photo immediately ("saved on this device").
    @discardableResult
    public func capture(
        _ image: PreparedImage, batchId: UUID, sequence: Int, accountId: String, serverURL: URL
    ) throws -> CaptureItem {
        let id = UUID()
        let ext = image.contentType == "image/png" ? "png" : "jpg"
        let fileName = "\(id.uuidString.lowercased()).\(ext)"
        let temporary = imagesURL.appending(path: ".\(fileName).tmp")
        try image.data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.moveItem(at: temporary, to: imagesURL.appending(path: fileName))
        let item = CaptureItem(
            id: id, batchId: batchId, sequence: sequence,
            operationId: UUID().uuidString.lowercased(), retryOfOperationId: nil,
            accountId: accountId, serverURL: serverURL,
            notebookId: nil, notebookName: nil, pageNumber: nil, replacesPageId: nil, replacesContentVersion: nil,
            processingMode: "immediate",
            fileName: fileName, byteCount: image.data.count, contentType: image.contentType,
            sha256: image.sha256, md5: image.md5,
            state: .captured, resumePoint: nil, attention: nil, lastError: nil, attempts: 0, nextAttemptAt: nil,
            uploadSessionId: nil, uploadURL: nil, uploadHeaders: nil, uploadURLExpiresAt: nil,
            pageId: nil, acceptedAt: nil, backup: nil, backupCheckedAt: nil, localFileRemoved: false,
            createdAt: now(), updatedAt: now())
        manifest.items.append(item)
        try persist()
        return item
    }

    /// Apply a change to one item and persist it.
    @discardableResult
    public func update(_ id: UUID, _ change: @Sendable (inout CaptureItem) -> Void) throws -> CaptureItem? {
        guard let index = manifest.items.firstIndex(where: { $0.id == id }) else { return nil }
        change(&manifest.items[index])
        manifest.items[index].updatedAt = now()
        try persist()
        return manifest.items[index]
    }

    public func setDecision(_ decision: DeferredDecision, for batch: UUID) throws {
        manifest.decisions[batch] = decision
        try persist()
    }

    /// Delete the local photo (keeps the queue record).
    public func removeFile(of id: UUID) throws {
        guard let item = item(id), let url = fileURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
        try update(id) { $0.localFileRemoved = true }
    }

    /// Forget an item and its photo entirely.
    public func remove(_ id: UUID) throws {
        if let item = item(id), let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        manifest.items.removeAll { $0.id == id }
        let batches = Set(manifest.items.map(\.batchId))
        manifest.decisions = manifest.decisions.filter { batches.contains($0.key) }
        try persist()
    }

    /// Privacy setting: keep pending captures out of device backups. The
    /// user is told this leaves them device-only.
    public func setIncludedInBackups(_ included: Bool) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try url.setResourceValues(values)
    }

    private func persist() throws {
        let data = try JSONEncoder.manifest.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension JSONEncoder {
    static let manifest: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let manifest: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
