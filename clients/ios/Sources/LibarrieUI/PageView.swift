import LibarrieKit
import Observation
import PhotosUI
import SwiftUI

@MainActor @Observable final class PageModel {
    let app: AppModel
    let id: String
    var detail: PageDetail?
    var text = ""
    /// The text the user had typed when a save was refused, kept so nothing is lost.
    var unsavedText: String?
    var message: (Banner.Kind, String)?
    var saving = false
    var gone = false
    var move: MoveForm?
    var confirmTrash = false
    var confirmRescan = false
    var rescanOperationId = UUID().uuidString.lowercased()
    var replacementPhoto: PhotosPickerItem?
    var showCamera = false
    var notebooks: [Notebook] = []

    init(app: AppModel, id: String) {
        self.app = app
        self.id = id
    }

    var api: APIClient? { app.services?.api }
    var page: Page? { detail?.page }
    var processing: Bool { page.map { StatusBadge.isProcessing($0.processingStatus) } ?? false }
    var dirty: Bool { text != (detail?.transcript?.text ?? "") }

    func load(keepText: Bool = false) async {
        guard let api else { return }
        do {
            let detail = try await api.page(id)
            self.detail = detail
            if !keepText || !dirty { text = detail.transcript?.text ?? "" }
        } catch let error as APIError where error.status == 404 {
            gone = true
        } catch {
            message = (.danger, describe(error))
        }
    }

    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if processing { await load(keepText: true) }
        }
    }

    func save(action: APIClient.TranscriptAction = .save) async {
        guard let api, let detail, let revision = detail.page.revisionId else { return }
        saving = true
        defer { saving = false }
        let typed = text
        do {
            try await api.saveTranscript(
                pageId: id, contentVersion: detail.page.contentVersion, sourceRevisionId: revision,
                baseTranscriptRevisionId: detail.page.transcriptRevisionId, action: action,
                text: action == .save ? typed : nil, ocrResultId: action == .acceptCandidate ? detail.ocrCandidate?.ocrResultId : nil)
            unsavedText = nil
            message = (.ok, action == .confirmBlank ? "Marked as a blank page." : "Transcript saved.")
            await load()
        } catch let error as APIError {
            // Keep the user's text; show the current version.
            unsavedText = typed
            let explanation: String = switch error.code {
            case "version_conflict": "This page changed since you opened it (perhaps on another device). The current text is shown; your text is kept below."
            case "processing_conflict": "The page is being processed. Wait for it to finish, then save again; your text is kept below."
            default: error.message
            }
            message = (.warning, explanation)
            await load()
        } catch {
            message = (.danger, describe(error))
        }
    }

    func openMove() async {
        guard let page, let api else { return }
        if notebooks.isEmpty { notebooks = (try? await api.notebooks().notebooks) ?? [] }
        move = MoveForm(page: page)
    }

    func applyMove(_ form: MoveForm) async -> Bool {
        guard let api, let page, let number = Int(form.pageNumber), number >= 1 else {
            form.error = "Enter a page number of at least 1."
            return false
        }
        do {
            _ = try await api.movePage(
                id, version: page.version,
                pageNumber: number == page.pageNumber ? nil : number,
                notebookId: form.notebookId == page.notebook.id ? nil : form.notebookId)
            message = (.ok, "Page updated.")
            await load(keepText: true)
            return true
        } catch let error as APIError where error.code == "page_number_conflict" {
            form.error = "Another page already has that number. Choose a free number."
        } catch let error as APIError where error.code == "version_conflict" {
            form.error = "This page changed on another device. Close and try again."
        } catch {
            form.error = describe(error)
        }
        return false
    }

    func rescan() async {
        guard let api, let page, let revision = page.revisionId else { return }
        do {
            _ = try await api.rescan(pageId: id, contentVersion: page.contentVersion, sourceRevisionId: revision,
                                     operationId: rescanOperationId)
            rescanOperationId = UUID().uuidString.lowercased()
            message = (.ok, "Rescanning. The transcript updates when it finishes.")
            await load()
        } catch {
            message = (.danger, describe(error))
        }
    }

    func replace(with data: Data) async {
        guard let page else { return }
        do {
            try await app.replace(page: page, with: data)
            message = (.ok, "Replacement saved. It uploads and is processed automatically; see Uploads for progress.")
        } catch {
            message = (.danger, describe(error))
        }
    }

    func trash() async -> Bool {
        guard let api, let page else { return false }
        do {
            try await api.trashPage(id, version: page.version)
            return true
        } catch {
            message = (.danger, describe(error))
            return false
        }
    }

    func originalURL() async -> URL? {
        guard let api else { return nil }
        do { return try await api.originalImageURL(pageId: id).url } catch {
            message = (.danger, describe(error))
            return nil
        }
    }
}

@MainActor @Observable final class MoveForm: Identifiable {
    let id = UUID()
    var pageNumber: String
    var notebookId: String
    var error: String?
    init(page: Page) {
        pageNumber = String(page.pageNumber)
        notebookId = page.notebook.id
    }
}

struct PageView: View {
    @Bindable var model: PageModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.gone {
                    ContentUnavailableView("Page unavailable", systemImage: "doc.questionmark",
                                           description: Text("This page was moved to trash or deleted."))
                }
                if let (kind, text) = model.message { Banner(kind: kind, text: text) }
                if let page = model.page {
                    PageImage(page: page, variant: .preview, cache: model.app.services?.images)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
                    status(page)
                    transcript(page)
                    actions(page)
                }
            }
            .padding()
        }
        .background(Brand.background)
        .navigationTitle(model.page.map { "Page \($0.pageNumber)" } ?? "Page")
        .inlineTitle()
        .task { await model.load() }
        .task { await model.watch() }
        .refreshable { await model.load(keepText: true) }
        .sheet(item: $model.move) { form in
            MoveView(form: form, notebooks: model.notebooks) { await model.applyMove(form) }
        }
        .confirmationDialog("Rescan this photo?", isPresented: $model.confirmRescan, titleVisibility: .visible) {
            Button("Rescan") { Task { await model.rescan() } }
        } message: {
            Text("The handwriting is read again. This uses one page of processing allowance; your edits stay in the page history.")
        }
        .confirmationDialog("Move this page to trash?", isPresented: $model.confirmTrash, titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) {
                Task { if await model.trash() { dismiss() } }
            }
        } message: {
            Text("You can restore it from Trash for 30 days.")
        }
        .onChange(of: model.replacementPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await model.replace(with: data) }
                model.replacementPhoto = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $model.showCamera) {
            CameraPicker { data in Task { await model.replace(with: data) } }.ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder func status(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(page.notebook.name).font(.subheadline).foregroundStyle(Brand.textMuted)
                Spacer()
                StatusBadge(status: page.processingStatus)
            }
            switch (page.processingStatus, model.detail?.latestOperation?.errorCode) {
            case ("needs_user_action", "unreadable"):
                Text("The handwriting could not be read reliably. You can type the text below or rescan the page.")
            case ("needs_user_action", "no_text_detected"):
                Text("No text was detected. If the page is blank, mark it blank below; otherwise type the text.")
            case ("needs_user_action", _):
                Text("This page needs your attention: its content could not be recognized.")
            case ("failed", _):
                Text("Processing failed for a temporary reason. Your allowance for this page is held for a retry.")
            case ("awaiting_processing", _):
                Text("Stored but not yet searchable. Process it from the Account tab, or type the text yourself.")
            default:
                EmptyView()
            }
            if page.indexingPending && page.processingStatus == "ready" {
                Text("Search is catching up with your latest edit.").font(.footnote).foregroundStyle(Brand.textMuted)
            }
        }
        .font(.callout)
    }

    @ViewBuilder func transcript(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.title3.bold())
            if let transcript = model.detail?.transcript {
                Text(transcript.blank ? "Confirmed blank page." :
                        transcript.origin == "user" ? "Edited by you." :
                        "Recognized text. Recognition can make mistakes; correct anything that looks wrong.")
                    .font(.footnote).foregroundStyle(Brand.textMuted)
            }
            if let candidate = model.detail?.ocrCandidate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A newer recognition of this photo is available:").font(.footnote.weight(.semibold))
                    Text(candidate.text).font(.footnote).lineLimit(4)
                    Button("Use the new recognition") { Task { await model.save(action: .acceptCandidate) } }
                        .font(.footnote)
                }
                .padding(10)
                .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            }
            TextEditor(text: $model.text)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.border))
                .disabled(page.revisionId == nil)
                .accessibilityLabel("Transcript text")
            if let unsaved = model.unsavedText {
                DisclosureGroup("Your unsaved text") {
                    Text(unsaved).font(.footnote.monospaced()).textSelection(.enabled)
                    Button("Use my text") { model.text = unsaved }.font(.footnote)
                }
            }
            HStack {
                Button(model.saving ? "Saving…" : "Save transcript") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).tint(Brand.primary)
                    .disabled(!model.dirty || model.saving || page.revisionId == nil)
                Button("Mark as blank page") { Task { await model.save(action: .confirmBlank) } }
                    .buttonStyle(.bordered)
                    .disabled(model.saving || page.revisionId == nil)
            }
        }
    }

    @ViewBuilder func actions(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Page").font(.title3.bold())
            Button { Task { await model.openMove() } } label: { Label("Change page number or notebook", systemImage: "arrow.left.arrow.right") }
            Button {
                Task { if let url = await model.originalURL() { openURL(url) } }
            } label: { Label("Open original photo", systemImage: "photo") }
            if model.processing {
                Text("Rescanning and replacing are available when processing finishes.").font(.footnote).foregroundStyle(Brand.textMuted)
            } else if page.revisionId != nil {
                Button { model.confirmRescan = true } label: { Label("Rescan this photo", systemImage: "text.viewfinder") }
                PhotosPicker(selection: $model.replacementPhoto, matching: .images) {
                    Label("Replace with a photo from the library", systemImage: "photo.on.rectangle")
                }
                #if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { model.showCamera = true } label: { Label("Replace with a new photo", systemImage: "camera") }
                }
                #endif
            }
            Button(role: .destructive) { model.confirmTrash = true } label: { Label("Move page to trash", systemImage: "trash") }
        }
        .buttonStyle(.borderless)
    }
}

struct MoveView: View {
    @Bindable var form: MoveForm
    let notebooks: [Notebook]
    let apply: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Page number") {
                    TextField("Page number", text: $form.pageNumber)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section("Notebook") {
                    Picker("Notebook", selection: $form.notebookId) {
                        ForEach(notebooks) { Text($0.name).tag($0.id) }
                    }
                }
                if let error = form.error { Banner(kind: .danger, text: error) }
            }
            .navigationTitle("Move page")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { if await apply() { dismiss() } } } }
            }
        }
    }
}
