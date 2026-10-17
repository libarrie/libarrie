import LibarrieKit
import Observation
import SwiftUI

@MainActor @Observable final class NotebookModel {
    let app: AppModel
    let id: String
    var notebook: Notebook?
    var pages: [Page] = []
    var nextCursor: String?
    var loading = false
    var message: (Banner.Kind, String)?
    var editor: NotebookEditor?
    var renumber: RenumberForm?
    var confirmTrash = false
    var trashed = false

    init(app: AppModel, id: String) {
        self.app = app
        self.id = id
    }

    var api: APIClient? { app.services?.api }
    var processing: Bool { pages.contains { StatusBadge.isProcessing($0.processingStatus) } }

    func load() async {
        guard let api else { return }
        loading = true
        defer { loading = false }
        do {
            async let notebook = api.notebook(id)
            async let first = api.pages(notebookId: id)
            let (nb, list) = try await (notebook, first)
            self.notebook = nb
            pages = list.pages
            nextCursor = list.nextCursor
        } catch let error as APIError where error.status == 404 {
            message = (.warning, "This notebook is no longer available.")
        } catch {
            message = (.danger, describe(error))
        }
    }

    func loadMore() async {
        guard let api, let cursor = nextCursor else { return }
        nextCursor = nil
        if let more = try? await api.pages(notebookId: id, after: cursor) {
            pages += more.pages
            nextCursor = more.nextCursor
        }
    }

    /// Poll while pages are processing.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if processing { await load() }
        }
    }

    func openRenumber() async {
        guard let api, let numbering = try? await api.numbering(notebookId: id) else {
            message = (.danger, "Page numbers could not be loaded.")
            return
        }
        renumber = RenumberForm(numbering: numbering)
    }

    func applyRenumber(_ form: RenumberForm) async -> Bool {
        guard let api, let from = Int(form.from), let to = Int(form.to), let by = Int(form.by),
              from >= 1, to >= from, by != 0 else {
            form.error = "Enter a first page of at least 1, a last page no lower than the first, and a move other than 0."
            return false
        }
        do {
            try await api.shiftPages(notebookId: id, numberingRevision: form.numbering.numberingRevision, from: from, to: to, by: by)
            message = (.ok, "Pages renumbered.")
            await load()
            return true
        } catch let error as APIError where error.code == "page_number_conflict" {
            form.error = "That would give two pages the same number. Choose free numbers, or move a wider range."
        } catch let error as APIError where error.code == "version_conflict" {
            form.error = "Page numbers changed on another device. Close and try again."
        } catch {
            form.error = describe(error)
        }
        return false
    }

    func trash() async {
        guard let api, let notebook else { return }
        do {
            try await api.trashNotebook(notebook.id, version: notebook.version)
            trashed = true
        } catch {
            message = (.danger, describe(error))
        }
    }
}

@MainActor @Observable final class RenumberForm: Identifiable {
    let id = UUID()
    let numbering: Numbering
    var from = ""
    var to = ""
    var by = "1"
    var error: String?

    init(numbering: Numbering) { self.numbering = numbering }

    /// `1–3, 5, 7–8`.
    var ranges: String {
        var runs: [(Int, Int)] = []
        for n in numbering.pages.map(\.pageNumber).sorted() {
            if let last = runs.last, n == last.1 + 1 { runs[runs.count - 1].1 = n } else { runs.append((n, n)) }
        }
        return runs.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)–\($0.1)" }.joined(separator: ", ")
    }
}

struct NotebookView: View {
    let model: NotebookModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let (kind, text) = model.message { Banner(kind: kind, text: text) }
                if let notebook = model.notebook, !notebook.description.isEmpty {
                    Text(notebook.description).foregroundStyle(Brand.textMuted)
                }
                if model.pages.isEmpty && !model.loading {
                    ContentUnavailableView("No pages yet", systemImage: "doc.viewfinder",
                                           description: Text("Photograph this notebook's pages to add them."))
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.pages) { page in
                        NavigationLink(value: Route.page(page.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                PageImage(page: page, variant: .thumb, cache: model.app.services?.images)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("Page \(page.pageNumber)").font(.subheadline.weight(.semibold))
                                StatusBadge(status: page.processingStatus)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .task { if page == model.pages.last { await model.loadMore() } }
                    }
                }
            }
            .padding()
        }
        .background(Brand.background)
        .navigationTitle(model.notebook?.name ?? "Notebook")
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { await model.watch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { navigator.startCapture(notebook: model.notebook) } label: { Label("Add pages", systemImage: "camera") }
                    .disabled(model.notebook == nil)
            }
            ToolbarItem {
                Menu {
                    Button { model.editor = model.notebook.map { NotebookEditor(editing: $0) } } label: {
                        Label("Edit notebook", systemImage: "pencil")
                    }
                    Button { Task { await model.openRenumber() } } label: {
                        Label("Renumber pages", systemImage: "list.number")
                    }
                    Button(role: .destructive) { model.confirmTrash = true } label: {
                        Label("Move to trash", systemImage: "trash")
                    }
                } label: { Label("Notebook settings", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: Binding(get: { model.editor }, set: { model.editor = $0 })) { editor in
            NotebookEditorView(editor: editor) {
                let saved = await navigator.notebooks.save(editor)
                if saved { await model.load() }
                return saved
            }
        }
        .sheet(item: Binding(get: { model.renumber }, set: { model.renumber = $0 })) { form in
            RenumberView(form: form) { await model.applyRenumber(form) }
        }
        .confirmationDialog("Move this notebook to trash?", isPresented: Binding(get: { model.confirmTrash }, set: { model.confirmTrash = $0 }),
                            titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) {
                Task {
                    await model.trash()
                    if model.trashed {
                        await navigator.notebooks.load()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The notebook and its pages move to trash. You can restore them for 30 days.")
        }
    }
}

struct RenumberView: View {
    @Bindable var form: RenumberForm
    let apply: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Current page numbers") {
                    Text(form.ranges.isEmpty ? "No pages yet." : form.ranges).font(.body.monospaced())
                }
                Section {
                    TextField("First page", text: $form.from)
                    TextField("Last page", text: $form.to)
                    TextField("Move by (negative moves earlier)", text: $form.by)
                } header: {
                    Text("Shift a range")
                } footer: {
                    Text("Every page from the first to the last number moves by the same amount. All pages move together, or none do.")
                }
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                if let error = form.error { Banner(kind: .danger, text: error) }
            }
            .navigationTitle("Renumber pages")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Renumber") { Task { if await apply() { dismiss() } } }
                }
            }
        }
    }
}
