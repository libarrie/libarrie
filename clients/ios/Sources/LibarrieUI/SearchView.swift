import LibarrieKit
import Observation
import SwiftUI

@MainActor @Observable final class SearchModel {
    let app: AppModel
    var query = ""
    var notebookId: String?
    var notebooks: [Notebook] = []
    var response: SearchResponse?
    var searching = false
    var error: String?

    init(app: AppModel) { self.app = app }

    func loadNotebooks() async {
        if notebooks.isEmpty, let list = try? await app.services?.api.notebooks() { notebooks = list.notebooks }
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let api = app.services?.api else { return }
        searching = true
        defer { searching = false }
        do {
            response = try await api.search(text, notebookId: notebookId)
            error = nil
        } catch let error as APIError where error.code == "rate_limited" {
            self.error = "Too many searches in a short time. Wait a moment and try again."
        } catch {
            self.error = describe(error)
        }
    }

    /// The snippet with matches highlighted (offsets are in graphemes).
    static func highlighted(_ hit: SearchHit) -> AttributedString {
        let characters = Array(hit.snippet)
        var result = AttributedString()
        var position = 0
        for range in hit.highlights.sorted(by: { $0.start < $1.start })
        where range.start >= position && range.end <= characters.count && range.end > range.start {
            result += AttributedString(String(characters[position..<range.start]))
            var match = AttributedString(String(characters[range.start..<range.end]))
            match.backgroundColor = Brand.highlight
            match.foregroundColor = Brand.onHighlight
            match.inlinePresentationIntent = .stronglyEmphasized
            result += match
            position = range.end
        }
        result += AttributedString(String(characters[position...]))
        return result
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    let navigator: Navigator

    var body: some View {
        List {
            if let error = model.error { Banner(kind: .warning, text: error) }
            if let response = model.response {
                if response.searchMode == "lexical_only" {
                    Banner(kind: .info, text: "Showing exact-word matches only; meaning-based search is temporarily unavailable.")
                } else if response.indexMigrationPending {
                    Banner(kind: .info, text: "Search is being upgraded; some pages match by exact words only for now.")
                }
                if response.results.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
                ForEach(response.results) { hit in
                    NavigationLink(value: Route.page(hit.pageId)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(hit.notebook.name) · Page \(hit.pageNumber)").font(.headline)
                            Text(SearchModel.highlighted(hit)).font(.callout)
                            if hit.indexingPending {
                                Text("This page was edited since it was indexed.").font(.caption).foregroundStyle(Brand.textMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if !model.searching {
                ContentUnavailableView("Search your notes", systemImage: "magnifyingglass",
                                       description: Text("Search for a name, an ID, or what a note was about."))
            }
        }
        .overlay { if model.searching { ProgressView() } }
        .navigationTitle("Search")
        .searchable(text: $model.query, prompt: "A name, an ID, or what the note was about")
        .onSubmit(of: .search) { Task { await model.search() } }
        .task { await model.loadNotebooks() }
        .toolbar {
            ToolbarItem {
                Picker(selection: $model.notebookId) {
                    Text("All notebooks").tag(String?.none)
                    ForEach(model.notebooks) { Text($0.name).tag(String?.some($0.id)) }
                } label: {
                    Label("Notebook", systemImage: "line.3.horizontal.decrease.circle")
                }
                .onChange(of: model.notebookId) { Task { await model.search() } }
            }
        }
    }
}
