import Foundation
import Testing
@testable import LibarrieKit

/// Every model decodes the server's real responses.
@Suite struct FixtureTests {
    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSON.decoder.decode(T.self, from: fixture(name).body)
    }

    @Test func clientConfiguration() throws {
        let config = try decode(ClientConfiguration.self, "client_configuration")
        #expect(config.oidc?.clientId == "libarrie-native")
        #expect(config.oidc?.redirectUri == "libarrie://oauth/callback")
        #expect(config.uploads.integrity == "sha256")
        #expect(config.uploads.maxBytes == 20_000_000)
    }

    @Test func accountAndUsage() throws {
        let me = try decode(Me.self, "me")
        #expect(me.account.status == "active")
        let usage = try decode(Usage.self, "usage")
        #expect(usage.limits.storedPages == .limited(30))
        #expect(usage.lifetimeAllowance?.used == 1)
        let deletion = try decode(AccountDeletionStatus.self, "account_deletion_status")
        #expect(deletion.milestone == "active")
    }

    @Test func notebooksAndPages() throws {
        let list = try decode(NotebookList.self, "notebook_list")
        #expect(list.notebooks.first?.name == "Blue work notebook")
        #expect(list.notebooks.first?.private == false)
        #expect(try decode(Notebook.self, "notebook").private == false)
        let pages = try decode(PageList.self, "page_list")
        #expect(pages.pages.first?.pageNumber == 1)
        let detail = try decode(PageDetail.self, "page_detail")
        #expect(detail.page.processingStatus == "ready")
        #expect(detail.transcript?.text == "Met Grace Hopper about the compiler budget")
        #expect(detail.page.backupStatus == "pending")
        let trash = try decode(TrashList.self, "trash")
        #expect(trash.pages.first?.visibility == "trashed")
    }

    @Test func uploads() throws {
        let created = try decode(UploadSession.self, "upload_session_created")
        #expect(created.upload?.method == "PUT")
        #expect(created.upload?.headers["x-amz-checksum-sha256"] != nil)
        #expect(created.operation.status == "awaiting_upload")
        let accepted = try decode(AcceptedUpload.self, "upload_completed")
        #expect(accepted.operation.uploadAcceptedAt != nil)
        let operation = try decode(Operation.self, "operation")
        #expect(operation.kind == "upload")
    }

    @Test func searchAndExports() throws {
        let search = try decode(SearchResponse.self, "search")
        #expect(search.results.first?.highlights?.first?.start == 10)
        // A hit from a private notebook says where, without the text.
        let hidden = try #require(try decode(SearchResponse.self, "search_private").results.first)
        #expect(hidden.snippet == nil)
        #expect(hidden.highlights == nil)
        #expect(hidden.notebook.name == "Blue work notebook")
        #expect(hidden.pageNumber == 1)
        let exports = try decode(ExportList.self, "export_list")
        #expect(exports.exports.first?.state == "completed")
        let detail = try decode(ExportDetail.self, "export_detail")
        #expect(detail.parts.first?.downloadable == true)
        _ = try decode(ExportCreated.self, "export_created")
    }

    @Test func notebooksFromOlderServers() throws {
        // A server older than private notebooks sends no `private`.
        let object: [String: Any] = [
            "id": "n", "name": "Work", "description": "", "color": NSNull(), "version": 1,
            "numbering_revision": 1, "page_count": 0, "deleted_at": NSNull(),
        ]
        let notebook = try JSON.decoder.decode(Notebook.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(notebook.private == nil)
    }

    @Test func notebookInputKeys() throws {
        // The server reads `private`; a key such as `is_private` would be ignored.
        let set = try JSON.encoder.encode(APIClient.NotebookInput(private: true))
        #expect(String(decoding: set, as: UTF8.self) == #"{"private":true}"#)
        let unset = try JSON.encoder.encode(APIClient.NotebookInput(name: "x", private: nil))
        #expect(String(decoding: unset, as: UTF8.self) == #"{"name":"x"}"#)
    }

    @Test func errors() throws {
        let conflict = try fixture("error_page_number_conflict")
        let error = APIError.decode(status: conflict.status, data: conflict.body, retryAfter: nil)
        #expect(error.code == "page_number_conflict")
        #expect(error.details["page_number"] == "1")
        let stale = try fixture("error_version_conflict")
        #expect(APIError.decode(status: stale.status, data: stale.body, retryAfter: nil).code == "version_conflict")
    }
}

@Suite struct SettingsFixtureTests {
    @Test func serverSettings() throws {
        let settings = try JSON.decoder.decode(ServerSettings.self, from: fixture("settings").body)
        #expect(settings.autoProcessDeferred == false)
    }
}
