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
        let attributed = SearchModel.highlighted(try hit(text, [(7, 10), (11, 16)]))
        let marked = attributed.runs.filter { $0.backgroundColor != nil }.map { String(attributed[$0.range].characters) }
        #expect(marked == ["met", "Grace"])
        #expect(String(attributed.characters) == text)
    }

    @Test func invalidHighlightRangesAreIgnored() throws {
        let attributed = SearchModel.highlighted(try hit("short", [(3, 99), (2, 1)]))
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
        #expect(String(attributed.characters) == "short")
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
