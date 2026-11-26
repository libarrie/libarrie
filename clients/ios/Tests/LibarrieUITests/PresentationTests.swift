import Foundation
import Testing
@testable import LibarrieKit
@testable import LibarrieUI

@MainActor @Suite struct PresentationTests {
    func hit(_ snippet: String, _ ranges: [(Int, Int)]) throws -> SearchHit {
        let object: [String: Any] = [
            "page_id": "p", "notebook": ["id": "n", "name": "Work"], "page_number": 1, "snippet": snippet,
            "highlights": ranges.map { ["start": $0.0, "end": $0.1] }, "match_kind": "hybrid", "indexing_pending": false,
        ]
        return try JSON.decoder.decode(SearchHit.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func highlightsUseGraphemeOffsets() throws {
        // "é" as e + combining accent, and an emoji, are one grapheme each.
        let text = "Cafe\u{301} 👩‍💻 met Grace"
        let attributed = try #require(SearchModel.highlighted(try hit(text, [(7, 10), (11, 16)])))
        let marked = attributed.runs.filter { $0.backgroundColor != nil }.map { String(attributed[$0.range].characters) }
        #expect(marked == ["met", "Grace"])
        #expect(String(attributed.characters) == text)
    }

    @Test func invalidHighlightRangesAreIgnored() throws {
        let attributed = try #require(SearchModel.highlighted(try hit("short", [(3, 99), (2, 1)])))
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
        #expect(String(attributed.characters) == "short")
    }

    @Test func privateHitsShowNoSnippet() throws {
        let object: [String: Any] = [
            "search_mode": "hybrid", "index_migration_pending": false,
            "results": [
                ["page_id": "p1", "notebook": ["id": "n1", "name": "Work"], "page_number": 1, "snippet": "met Grace",
                 "highlights": [["start": 4, "end": 9]], "match_kind": "hybrid", "indexing_pending": false],
                ["page_id": "p2", "notebook": ["id": "n2", "name": "Diary"], "page_number": 4,
                 "match_kind": "lexical", "indexing_pending": false],
            ],
        ]
        let response = try JSON.decoder.decode(SearchResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(response.results.count == 2)
        let open = try #require(SearchModel.highlighted(response.results[0]))
        #expect(String(open.characters) == "met Grace")
        #expect(SearchModel.highlighted(response.results[1]) == nil)
    }

    func notebook(_ fields: [String: Any]) throws -> Notebook {
        var object: [String: Any] = [
            "id": "n", "name": "Diary", "description": "Blue cover", "color": "#2F6F9F", "version": 3,
            "numbering_revision": 1, "page_count": 2, "deleted_at": NSNull(),
        ]
        object.merge(fields) { $1 }
        return try JSON.decoder.decode(Notebook.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func editorSendsItsPrivacy() throws {
        let creating = NotebookEditor(editing: nil)
        #expect(!creating.isPrivate)
        #expect(creating.input.private == false)
        creating.isPrivate = true
        #expect(creating.input.private == true)
        // Opened on a private notebook, the toggle starts on, so a rename keeps it.
        let editing = NotebookEditor(editing: try notebook(["private": true]))
        #expect(editing.isPrivate)
        editing.name = "  Diary 2026 "
        let renamed = editing.input
        #expect(renamed.private == true)
        #expect(renamed.name == "Diary 2026")
        #expect(renamed.description == "Blue cover")
        #expect(renamed.color == "#2f6f9f")
        editing.isPrivate = false
        #expect(editing.input.private == false)
    }

    @Test func savesThatDidNotMakeANotebookPrivateSaySo() throws {
        let older = try notebook([:])
        let asked = APIClient.NotebookInput(name: "Diary", private: true)
        #expect(NotebookEditor.privacyNotice(sent: asked, saved: older)
            == "Saved, but this server doesn't support private notebooks yet, so \"Diary\" isn't private.")
        #expect(NotebookEditor.privacyNotice(sent: asked, saved: try notebook(["private": true])) == nil)
        // Turning privacy off, or leaving it off, needs no warning.
        #expect(NotebookEditor.privacyNotice(sent: APIClient.NotebookInput(name: "Diary", private: false), saved: older) == nil)
        #expect(NotebookEditor.privacyNotice(sent: APIClient.NotebookInput(name: "Diary", private: nil), saved: older) == nil)
    }

    @Test func pageRangesAreCompact() {
        let numbering = Numbering(notebookId: "n", numberingRevision: 1, pages: [1, 2, 3, 5, 7, 8].map {
            Numbering.Entry(pageId: "p\($0)", pageNumber: $0, version: 1)
        })
        #expect(RenumberForm(numbering: numbering).ranges == "1–3, 5, 7–8")
        #expect(numbering.nextFree == 9)
    }

    @Test func statusesHaveWordsNotJustColor() {
        for status in ["ready", "queued", "recognizing", "needs_user_action", "failed", "awaiting_processing", "something_new"] {
            let (label, symbol, _) = StatusBadge.describe(status)
            #expect(!label.isEmpty)
            #expect(!symbol.isEmpty)
        }
        #expect(StatusBadge.describe("something_new").0 == "something new")
    }
}
