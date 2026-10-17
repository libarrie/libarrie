import Foundation

/// Moves bytes to the presigned staging URL. On iOS this is a background
/// URLSession, so the system finishes uploads after the app is suspended
/// or terminated; tests substitute a scripted implementation.
public protocol UploadTransferring: Sendable {
    func start(itemID: UUID, request: URLRequest, fileURL: URL) async
    func activeItemIDs() async -> Set<UUID>
}

/// Delivered when a transfer ends: the HTTP status, or the error if no
/// response arrived.
public struct TransferResult: Sendable, Equatable {
    public var itemID: UUID
    public var statusCode: Int?
    public var failed: Bool
    public init(itemID: UUID, statusCode: Int?, failed: Bool) {
        self.itemID = itemID; self.statusCode = statusCode; self.failed = failed
    }
}

/// Background URLSession uploads (section 13: "system-supported background
/// transfer integration"). Uploads run from the immutable capture file,
/// send no cookies or credentials (the URL is presigned), and report
/// results through `onFinish`, also after the system relaunches the app.
public final class BackgroundUploads: NSObject, UploadTransferring, URLSessionTaskDelegate, @unchecked Sendable {
    public static let identifier = "app.libarrie.uploads"
    private let lock = NSLock()
    private var handler: (@Sendable (TransferResult) -> Void)?
    private var systemCompletion: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    /// Where finished transfers are reported (the upload engine).
    public func setHandler(_ handler: @escaping @Sendable (TransferResult) -> Void) {
        lock.withLock { self.handler = handler }
        _ = session  // Reconnect to transfers that finished while not running.
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setSystemCompletion(_ completion: @escaping () -> Void) {
        lock.withLock { systemCompletion = completion }
        _ = session
    }

    public func start(itemID: UUID, request: URLRequest, fileURL: URL) async {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = itemID.uuidString
        task.resume()
    }

    public func activeItemIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let result = TransferResult(itemID: id, statusCode: status, failed: error != nil && status == nil)
        let handler = lock.withLock { self.handler }
        handler?(result)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { systemCompletion = nil }
            return systemCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}
