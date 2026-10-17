import LibarrieKit
import Observation
import SwiftUI

/// Create or edit a notebook's name, description and color.
@MainActor @Observable final class NotebookEditor: Identifiable {
    let id = UUID()
    let editing: Notebook?
    var name: String
    var description: String
    var color: String
    var error: String?
    var saving = false

    init(editing: Notebook?) {
        self.editing = editing
        name = editing?.name ?? ""
        description = editing?.description ?? ""
        color = editing?.color?.lowercased() ?? ""
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 200 && !saving }
}

@MainActor @Observable final class NotebooksModel {
    let app: AppModel
    var notebooks: [Notebook] = []
    var loading = false
    var error: String?
    var editor: NotebookEditor?

    init(app: AppModel) { self.app = app }

    func load() async {
        guard let api = app.services?.api else { return }
        loading = true
        defer { loading = false }
        do {
            var all: [Notebook] = []
            var cursor: String?
            repeat {
                let page = try await api.notebooks(cursor: cursor)
                all += page.notebooks
                cursor = page.nextCursor
            } while cursor != nil
            notebooks = all
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    func save(_ editor: NotebookEditor) async -> Bool {
        guard let api = app.services?.api else { return false }
        editor.saving = true
        defer { editor.saving = false }
        let input = APIClient.NotebookInput(
            name: editor.name.trimmingCharacters(in: .whitespaces), description: editor.description, color: editor.color)
        do {
            if let existing = editor.editing {
                _ = try await api.updateNotebook(existing.id, version: existing.version, input)
            } else {
                _ = try await api.createNotebook(input)
            }
            await load()
            return true
        } catch let error as APIError where error.code == "version_conflict" {
            editor.error = "This notebook changed on another device. Close and try again."
        } catch let error as APIError where error.code == "notebook_limit_reached" {
            editor.error = "You have reached your notebook limit."
        } catch {
            editor.error = describe(error)
        }
        return false
    }
}

struct NotebooksView: View {
    let model: NotebooksModel
    let navigator: Navigator

    var body: some View {
        List {
            if let error = model.error { Banner(kind: .danger, text: error).listRowSeparator(.hidden) }
            if model.notebooks.isEmpty && !model.loading {
                ContentUnavailableView("No notebooks yet", systemImage: "book.closed",
                                       description: Text("Create a notebook, then photograph its pages."))
            }
            ForEach(model.notebooks) { notebook in
                NavigationLink(value: Route.notebook(notebook.id)) {
                    HStack(spacing: 12) {
                        NotebookDot(hex: notebook.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notebook.name).font(.headline)
                            if !notebook.description.isEmpty {
                                Text(notebook.description).font(.subheadline).foregroundStyle(Brand.textMuted).lineLimit(2)
                            }
                            Text("^[\(notebook.pageCount) page](inflect: true)").font(.caption).foregroundStyle(Brand.textMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Notebooks")
        .refreshable { await model.load() }
        .task { if model.notebooks.isEmpty { await model.load() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.editor = NotebookEditor(editing: nil) } label: { Label("New notebook", systemImage: "plus") }
            }
            ToolbarItem {
                Button { navigator.startCapture(notebook: nil) } label: { Label("Add pages", systemImage: "camera") }
            }
        }
        .sheet(item: Binding(get: { model.editor }, set: { model.editor = $0 })) { editor in
            NotebookEditorView(editor: editor) { await model.save(editor) }
        }
    }
}

struct NotebookEditorView: View {
    @Bindable var editor: NotebookEditor
    let save: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let error = editor.error { Banner(kind: .danger, text: error) }
                Section("Name") {
                    TextField("For example, Blue work notebook", text: $editor.name)
                }
                Section("Description (optional)") {
                    TextField("Something that helps you recognize it", text: $editor.description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Color (optional)") {
                    Picker("Color", selection: $editor.color) {
                        Text("None").tag("")
                        ForEach(Brand.notebookColors, id: \.hex) { entry in
                            Label { Text(entry.name) } icon: { NotebookDot(hex: entry.hex) }.tag(entry.hex)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(editor.editing == nil ? "New notebook" : "Edit notebook")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.editing == nil ? "Create" : "Save") {
                        Task { if await save() { dismiss() } }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
    }
}
