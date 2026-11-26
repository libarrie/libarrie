import Foundation

// Local models for the /v1 JSON API (contracts/openapi.yaml). Keys are
// decoded from snake_case. Unknown additive fields are ignored, so newer
// servers never break older apps.

public struct ClientConfiguration: Codable, Sendable, Equatable {
    public var oidc: OIDCConfiguration?
    public var uploads: UploadPolicy
}

public struct OIDCConfiguration: Codable, Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientId: String
    public var redirectUri: String
    public var scopes: [String]
}

public struct UploadPolicy: Codable, Sendable, Equatable {
    /// `sha256` or `md5` (Cloudflare R2 verifies only Content-MD5).
    public var integrity: String
    public var maxBytes: Int
    public var contentTypes: [String]

    public init(integrity: String, maxBytes: Int, contentTypes: [String]) {
        self.integrity = integrity
        self.maxBytes = maxBytes
        self.contentTypes = contentTypes
    }
}

public struct Me: Codable, Sendable, Equatable {
    public struct User: Codable, Sendable, Equatable { public var id: String; public var displayName: String }
    public struct Account: Codable, Sendable, Equatable { public var id: String; public var status: String }
    public struct Capabilities: Codable, Sendable, Equatable {
        public var deferredProcessing: Bool
        public var backgroundUploadUrls: Bool
    }
    public var user: User
    public var account: Account
    public var capabilities: Capabilities
}

public enum Limit: Codable, Sendable, Equatable {
    case limited(Int)
    case unlimited

    private enum Keys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "limited": self = .limited(try c.decode(Int.self, forKey: .value))
        default: self = .unlimited
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .limited(let n): try c.encode("limited", forKey: .kind); try c.encode(n, forKey: .value)
        case .unlimited: try c.encode("unlimited", forKey: .kind)
        }
    }

    public var value: Int? { if case .limited(let n) = self { n } else { nil } }
}

public struct Usage: Codable, Sendable, Equatable {
    public struct Limits: Codable, Sendable, Equatable {
        public var storedPages: Limit
        public var notebooks: Limit
    }
    public struct Allowance: Codable, Sendable, Equatable {
        public var limit: Limit
        public var used: Int
        public var reserved: Int
    }
    public var limits: Limits
    public var storedPages: Int
    public var reservedPageSlots: Int
    public var notebooks: Int
    /// `none`, `above_80_percent`, `above_90_percent` or `at_capacity`.
    public var capacityWarning: String
    /// Present for lifetime allowances.
    public var lifetimeAllowance: Allowance?
}

/// Account preferences stored by the server.
public struct ServerSettings: Codable, Sendable, Equatable {
    /// Admit pages uploaded for later processing automatically as allowance allows.
    public var autoProcessDeferred: Bool
}

public struct NotebookRef: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
}

public struct Notebook: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var description: String
    public var color: String?
    /// Searches show where its pages match, never the text (ADR 0017). A
    /// server older than private notebooks sends none, and nil reads as not
    /// private.
    public var `private`: Bool?
    public var version: Int
    public var numberingRevision: Int
    public var pageCount: Int
    public var deletedAt: String?
}

public struct NotebookList: Codable, Sendable {
    public var notebooks: [Notebook]
    public var nextCursor: String?
}

public struct Page: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var notebook: NotebookRef
    public var pageNumber: Int
    public var visibility: String
    public var version: Int
    public var contentVersion: Int
    public var revisionId: String?
    public var pendingRevisionId: String?
    public var transcriptRevisionId: String?
    public var processingStatus: String
    public var indexingPending: Bool
    public var liveOperationId: String?
    /// `pending`, `verified` or `missing`: independent backup of the source.
    public var backupStatus: String?
    public var deletedAt: String?
    /// Same-origin, cacheable `/img/{object}/{variant}` paths; null until derived.
    public var thumbnailUrl: String?
    public var previewUrl: String?

    /// The immutable source object ID in the image paths, used as the
    /// local image cache key.
    public var imageObjectId: String? {
        guard let path = thumbnailUrl ?? previewUrl else { return nil }
        let parts = path.split(separator: "/")
        return parts.count >= 3 ? String(parts[1]) : nil
    }
}

public struct PageList: Codable, Sendable {
    public var notebookId: String
    public var numberingRevision: Int
    public var pages: [Page]
    public var nextCursor: String?
}

public struct Numbering: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var pageId: String
        public var pageNumber: Int
        public var version: Int
        public init(pageId: String, pageNumber: Int, version: Int) { self.pageId = pageId; self.pageNumber = pageNumber; self.version = version }
    }
    public var notebookId: String
    public var numberingRevision: Int
    public var pages: [Entry]

    public init(notebookId: String, numberingRevision: Int, pages: [Entry]) {
        self.notebookId = notebookId; self.numberingRevision = numberingRevision; self.pages = pages
    }

    /// The next number after the highest page.
    public var nextFree: Int { (pages.map(\.pageNumber).max() ?? 0) + 1 }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var transcriptRevisionId: String?
    public var text: String
    /// `ocr` or `user`.
    public var origin: String
    public var blank: Bool
}

public struct OCRCandidate: Codable, Sendable, Equatable {
    public var ocrResultId: String
    public var text: String
}

public struct Operation: Codable, Sendable, Equatable {
    public var operationId: String
    public var kind: String
    public var status: String
    public var failureFault: String?
    public var errorCode: String?
    public var notebookId: String?
    public var pageId: String?
    public var revisionId: String?
    public var processingMode: String
    public var uploadAcceptedAt: String?
    public var parentOperationId: String?

    /// Terminal outcomes after which the operation never accepts bytes again.
    public var isTerminalWithoutUpload: Bool {
        uploadAcceptedAt == nil && ["expired", "cancelled", "failed"].contains(status)
    }
}

public struct PageDetail: Codable, Sendable, Equatable {
    public var page: Page
    public var transcript: Transcript?
    public var ocrCandidate: OCRCandidate?
    public var latestOperation: Operation?
}

public struct UploadTarget: Codable, Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var expiresInSeconds: Int
}

public struct UploadSession: Codable, Sendable, Equatable {
    public var uploadSessionId: String
    public var status: String
    public var expiresAt: String
    /// Present while the reservation accepts bytes.
    public var upload: UploadTarget?
    public var operation: Operation
}

public struct AcceptedUpload: Codable, Sendable, Equatable {
    public var operation: Operation
    public var pageVisibility: String?
}

public struct SearchHit: Codable, Sendable, Equatable, Identifiable {
    public struct Highlight: Codable, Sendable, Equatable { public var start: Int; public var end: Int }
    public var pageId: String
    public var notebook: NotebookRef
    public var pageNumber: Int
    /// Absent, with `highlights`, for a page in a private notebook.
    public var snippet: String?
    public var highlights: [Highlight]?
    public var matchKind: String
    public var indexingPending: Bool
    public var id: String { pageId }
}

public struct SearchResponse: Codable, Sendable, Equatable {
    /// `hybrid` or `lexical_only`.
    public var searchMode: String
    public var indexMigrationPending: Bool
    public var results: [SearchHit]
}

public struct TrashList: Codable, Sendable {
    public var retentionDays: Int
    public var notebooks: [Notebook]
    public var pages: [Page]
    public var nextCursor: String?
}

public struct Export: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// assembling, completed, failed, expired, cancelled or invalidated.
    public var state: String
    public var includeTrash: Bool
    public var itemCount: Int
    public var totalBytes: Int
    public var createdAt: String
    public var expiresAt: String?
    public var errorCode: String?
}

public struct ExportPart: Codable, Sendable, Equatable, Identifiable {
    public var partNumber: Int
    public var itemCount: Int
    public var bytes: Int?
    public var checksumSha256: String?
    public var downloadable: Bool
    public var id: Int { partNumber }
}

public struct ExportList: Codable, Sendable { public var exports: [Export] }
public struct ExportCreated: Codable, Sendable { public var export: Export }

public struct ExportDetail: Codable, Sendable, Equatable {
    public var export: Export
    public var parts: [ExportPart]
}

public struct SignedURL: Codable, Sendable, Equatable {
    public var url: URL
    public var expiresInSeconds: Int
}

public struct AccountDeletionStatus: Codable, Sendable, Equatable {
    public var status: String
    public var milestone: String
    public var lifecycleRevision: Int?
    public var effectiveAt: String?
    public var notice: String?
}

public struct DeferredResult: Codable, Sendable, Equatable {
    public var pageId: String
    public var operationId: String?
    /// admitted, already_admitted, conflict or limit.
    public var result: String
}

public struct DeferredResults: Codable, Sendable { public var results: [DeferredResult] }

public enum JSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
