import Foundation
@testable import LibarrieKit

/// Answers requests with a closure; records what was sent.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (URLRequest) throws -> (Int, Data)
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) throws -> (Int, Data)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock { () -> (URLRequest) throws -> (Int, Data) in
            requests.append(request)
            return self.handler
        }
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var sent: [URLRequest] { lock.withLock { requests } }
}

struct StaticTokens: AccessTokenProvider {
    var token = "token"
    func accessToken() async throws -> String { token }
    func refreshAfterRejection(of token: String) async throws -> String { throw APIError.unauthenticated }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

func body(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

func errorBody(_ code: String, _ message: String = "refused") -> Data {
    json(["error": ["code": code, "message": message, "details": [:], "request_id": "test"]])
}

/// The repository's server-generated fixtures (contracts/fixtures/api).
func fixture(_ name: String) throws -> (status: Int, body: Data) {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "contracts/fixtures/api/\(name).json")
    let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return (document["status"] as! Int, Data((document["body"] as! String).utf8))
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "libarrie-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A controllable clock.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
