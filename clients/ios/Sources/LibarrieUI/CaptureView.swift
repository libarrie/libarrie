import LibarrieKit
import Observation
import PhotosUI
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Capture or import several photos, choose the notebook once, set the
/// starting page number, review the order, then queue them (section 2,
/// journey 2). Photos are saved on the device as soon as they are taken.
@MainActor @Observable public final class CaptureModel: Identifiable {
    public nonisolated let id: UUID
    let app: AppModel
    let batch: UUID
    var notebooks: [Notebook] = []
    var notebookId: String?
    var startPage = "1"
    var order: [UUID] = []
    var library: [PhotosPickerItem] = []
    var showCamera = false
    var showScanner = false
    var importing = false
    var problems: [String] = []
    var error: String?

    init(app: AppModel, batch: UUID, notebook: Notebook?) {
        self.app = app
        self.batch = batch
        id = batch
        notebookId = notebook?.id
        if let notebook { notebooks = [notebook] }
        syncOrder()
    }

    var items: [CaptureItem] {
        let byId = Dictionary(uniqueKeysWithValues: app.queue.filter { $0.batchId == batch && $0.state == .captured }.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }

    var notebook: Notebook? { notebooks.first { $0.id == notebookId } }

    var canQueue: Bool { !items.isEmpty && notebook != nil && (Int(startPage) ?? 0) >= 1 && !importing }

    func syncOrder() {
        let captured = app.queue.filter { $0.batchId == batch && $0.state == .captured }.sorted { $0.sequence < $1.sequence }
        let known = Set(order)
        order = order.filter { id in captured.contains { $0.id == id } } + captured.map(\.id).filter { !known.contains($0) }
    }

    func load() async {
        guard let api = app.services?.api else { return }
        if let list = try? await api.notebooks() { notebooks = list.notebooks }
        if notebookId == nil { notebookId = notebooks.first?.id }
        await suggestStartPage()
    }

    func suggestStartPage() async {
        guard let api = app.services?.api, let notebookId,
              let numbering = try? await api.numbering(notebookId: notebookId) else { return }
        startPage = String(numbering.nextFree)
    }

    func add(_ photos: [Data]) async {
        importing = true
        defer { importing = false }
        problems += await app.capture(photos, batch: batch)
        syncOrder()
    }

    func importLibrary() async {
        let picked = library
        library = []
        var data: [Data] = []
        for item in picked {
            if let bytes = try? await item.loadTransferable(type: Data.self) { data.append(bytes) }
            else { problems.append("A photo from the library could not be read.") }
        }
        await add(data)
    }

    func move(from source: IndexSet, to destination: Int) { order.move(fromOffsets: source, toOffset: destination) }

    func remove(_ id: UUID) async {
        await app.discard(id)
        syncOrder()
    }

    func queue() async -> Bool {
        guard let notebook, let start = Int(startPage), start >= 1 else { return false }
        await app.commit(batch: batch, order: order, notebook: notebook, startPage: start)
        return true
    }
}

struct CaptureView: View {
    @Bindable var model: CaptureModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Notebook", selection: $model.notebookId) {
                        Text("Choose a notebook").tag(String?.none)
                        ForEach(model.notebooks) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    TextField("Starting page number", text: $model.startPage)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                } footer: {
                    Text("Each photo becomes one page, numbered in the order below. Crop a two-page spread into two photos first.")
                }
                Section {
                    #if os(iOS)
                    if VNDocumentCameraViewController.isSupported {
                        Button { model.showScanner = true } label: { Label("Scan pages", systemImage: "doc.viewfinder") }
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { model.showCamera = true } label: { Label("Take a photo", systemImage: "camera") }
                    }
                    #endif
                    PhotosPicker(selection: $model.library, maxSelectionCount: 100, matching: .images) {
                        Label("Choose from library", systemImage: "photo.on.rectangle")
                    }
                }
                if model.importing { ProgressView("Saving photos…") }
                ForEach(model.problems, id: \.self) { Banner(kind: .warning, text: $0) }
                if !model.items.isEmpty {
                    Section {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 12) {
                                LocalCaptureImage(item: item, app: model.app).frame(width: 56, height: 72)
                                VStack(alignment: .leading) {
                                    Text("Page \((Int(model.startPage) ?? 1) + index)").font(.headline)
                                    Text("Saved on this device").font(.caption).foregroundStyle(Brand.textMuted)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .onMove { model.move(from: $0, to: $1) }
                        .onDelete { offsets in
                            let ids = offsets.map { model.items[$0].id }
                            Task { for id in ids { await model.remove(id) } }
                        }
                    } header: {
                        Text("Review order (drag to reorder)")
                    }
                }
            }
            .navigationTitle("Add pages")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                        .accessibilityHint("Keeps these photos on this device; finish them from Uploads.")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload \(model.items.count)") {
                        Task { if await model.queue() { dismiss() } }
                    }
                    .disabled(!model.canQueue)
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) { EditButton() }
                #endif
            }
            .task { await model.load() }
            .onChange(of: model.notebookId) { Task { await model.suggestStartPage() } }
            .onChange(of: model.library) { _, picked in if !picked.isEmpty { Task { await model.importLibrary() } } }
            #if os(iOS)
            .fullScreenCover(isPresented: $model.showCamera) {
                CameraPicker { data in Task { await model.add([data]) } }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $model.showScanner) {
                DocumentScanner { pages in Task { await model.add(pages) } }.ignoresSafeArea()
            }
            #endif
        }
    }
}

@MainActor @Observable final class LocalImageModel {
    var image: Image?
    func load(_ item: CaptureItem, app: AppModel) async {
        guard image == nil, let url = await app.imageURL(for: item), let data = try? Data(contentsOf: url) else { return }
        image = platformImage(data)
    }
}

struct LocalCaptureImage: View {
    let item: CaptureItem
    let app: AppModel
    let model = LocalImageModel()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Brand.surface)
            if let image = model.image { image.resizable().scaledToFill() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: item.id) { await model.load(item, app: app) }
    }
}
