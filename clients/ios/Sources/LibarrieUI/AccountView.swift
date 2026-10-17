import LibarrieKit
import Observation
import SwiftUI

@MainActor @Observable final class AccountModel {
    let app: AppModel
    var deletion: AccountDeletionStatus?
    var confirmed = false
    var acknowledgement: String?
    var acknowledged = false
    var message: (Banner.Kind, String)?
    var working = false
    var confirmSignOut = false
    /// Server-side preference; nil until loaded.
    var autoProcessDeferred: Bool?

    init(app: AppModel) { self.app = app }

    func load() async {
        deletion = try? await app.services?.api.accountDeletionStatus()
    }

    func loadSettings() async {
        autoProcessDeferred = (try? await app.services?.api.settings())?.autoProcessDeferred
    }

    func setAutoProcessDeferred(_ value: Bool) async {
        let previous = autoProcessDeferred
        autoProcessDeferred = value
        do {
            autoProcessDeferred = try await app.services?.api.updateSettings(autoProcessDeferred: value).autoProcessDeferred
        } catch {
            autoProcessDeferred = previous
            message = (.danger, describe(error))
        }
    }

    func scheduleDeletion() async {
        guard let api = app.services?.api else { return }
        working = true
        defer { working = false }
        do {
            try await withRecentSignIn(app) {
                deletion = try await api.scheduleAccountDeletion(acknowledgeCoverageEnd: acknowledged)
            }
            message = (.warning, "Account deletion scheduled.")
            await load()
        } catch let error as APIError where error.code == "acknowledgement_required" {
            acknowledgement = error.message
        } catch {
            message = (.danger, describe(error))
        }
    }

    func cancelDeletion() async {
        guard let api = app.services?.api, let revision = deletion?.lifecycleRevision else { return }
        working = true
        defer { working = false }
        do {
            try await withRecentSignIn(app) { deletion = try await api.cancelAccountDeletion(lifecycleRevision: revision) }
            message = (.ok, "Account deletion cancelled. Your account is fully active again.")
            await load()
        } catch {
            message = (.danger, describe(error))
        }
    }
}

struct AccountView: View {
    let model: AccountModel
    let navigator: Navigator

    var body: some View {
        List {
            if let (kind, text) = model.message { Banner(kind: kind, text: text) }
            Section {
                Label(model.app.me?.user.displayName ?? "Signed in", systemImage: "person.crop.circle")
                if let server = model.app.services?.serverURL.host() {
                    Text(server).font(.footnote).foregroundStyle(Brand.textMuted)
                }
            }
            if model.deletion?.status == "closure_scheduled" {
                Section {
                    Banner(kind: .warning, text: "Your account will be deleted \(model.deletion?.effectiveAt.map { "on \(formatDate($0))" } ?? "soon"). Until then you can read, search and export, but not add or change notes.")
                    Button("Keep my account") { Task { await model.cancelDeletion() } }.disabled(model.working)
                }
            }
            Section {
                NavigationLink(value: Route.usage) { Label("Usage", systemImage: "chart.bar") }
                NavigationLink(value: Route.trash) { Label("Trash", systemImage: "trash") }
                NavigationLink(value: Route.exports) { Label("Export your notes", systemImage: "square.and.arrow.up") }
                NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gear") }
            }
            Section {
                Button("Sign out") { model.confirmSignOut = true }
                if model.deletion?.status != "closure_scheduled" {
                    NavigationLink(value: Route.deleteAccount) { Text("Delete account").foregroundStyle(Brand.danger) }
                }
            }
        }
        .navigationTitle("Account")
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Sign out?", isPresented: Binding(get: { model.confirmSignOut }, set: { model.confirmSignOut = $0 }),
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.app.signOut() } }
        } message: {
            let pending = model.app.accountQueue.filter { $0.state != .serverAccepted }.count
            Text(pending == 0 ? "Cached images are removed from this device."
                 : "\(pending) photos are not uploaded yet. They stay on this device and upload when you sign in to this account again.")
        }
    }
}

struct DeleteAccountView: View {
    @Bindable var model: AccountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let (kind, text) = model.message { Banner(kind: kind, text: text) }
            Section("What happens") {
                Text("Right away, you can no longer add or change notes. Uploads and processing in progress stop.")
                Text("During a grace period you can still read, search and export your notes, and cancel the deletion.")
                Text("After that, all notebooks, photos, transcripts and exports are deleted permanently.")
                NavigationLink(value: Route.exports) { Text("Export your notes first") }
            }
            if let acknowledgement = model.acknowledgement {
                Section {
                    Banner(kind: .warning, text: acknowledgement)
                    Toggle("I understand", isOn: $model.acknowledged)
                }
            }
            Section {
                Toggle("I want to delete my account and all of my notes", isOn: $model.confirmed)
                Button("Delete account", role: .destructive) {
                    Task {
                        await model.scheduleDeletion()
                        if model.deletion?.status == "closure_scheduled" { dismiss() }
                    }
                }
                .disabled(!model.confirmed || model.working || (model.acknowledgement != nil && !model.acknowledged))
            } footer: {
                Text("You will be asked to sign in again to confirm.")
            }
        }
        .navigationTitle("Delete account")
    }
}

/// Closing accounts keep a status-only session.
struct ClosingAccountView: View {
    let app: AppModel
    let model: AccountModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock").font(.largeTitle).accessibilityHidden(true)
            Text("Account closing").font(.title.bold())
            Text("This account is being closed. Notes can no longer be viewed, and uploads have stopped.")
                .multilineTextAlignment(.center)
            Button("Sign out") { Task { await app.signOut() } }.buttonStyle(.bordered)
        }
        .padding(32)
    }
}

/// After purge only a keyed hash of the identity survives.
struct PurgedAccountView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Account closed").font(.title.bold())
            Text("The account for this sign-in was closed and its notes were deleted. You can start a new, empty account; it continues from your earlier processing allowance.")
                .multilineTextAlignment(.center)
            if let error = app.signInError { Banner(kind: .danger, text: error) }
            Button("Start a new account") { Task { await app.startNewAccount() } }.buttonStyle(.borderedProminent)
            Button("Sign out") { Task { await app.signOut() } }
        }
        .padding(32)
    }
}

/// Photos not yet stored by Libarrie, as files the user can save elsewhere
/// (section 13: a portable export when device backup is not available).
@MainActor @Observable final class PendingPhotosModel {
    var files: [URL] = []
    func load(_ app: AppModel) async {
        var urls: [URL] = []
        for item in app.queue where item.state != .serverAccepted && !item.localFileRemoved {
            if let url = await app.imageURL(for: item) { urls.append(url) }
        }
        files = urls
    }
}

struct SettingsView: View {
    let app: AppModel
    let account: AccountModel
    @Bindable var settings: AppSettings
    let pending = PendingPhotosModel()

    init(app: AppModel, account: AccountModel) {
        self.app = app
        self.account = account
        settings = app.settings
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ThemePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let automatic = account.autoProcessDeferred {
                Section {
                    Toggle("Process pages uploaded for later automatically", isOn: Binding(
                        get: { automatic },
                        set: { value in Task { await account.setAutoProcessDeferred(value) } }))
                } footer: {
                    Text("When processing allowance becomes available, pages you uploaded to process later start on their own. Off: they wait until you choose Process now under Usage.")
                }
            }
            Section {
                Toggle("Keep location in photos", isOn: $settings.keepLocation)
            } footer: {
                Text("Off by default: GPS location is removed from photos before they are saved or uploaded.")
            }
            Section {
                Toggle("Include photos waiting to upload in device backups", isOn: Binding(
                    get: { settings.backUpPendingCaptures },
                    set: { value in Task { await app.setBackUpPendingCaptures(value) } }))
            } footer: {
                Text(settings.backUpPendingCaptures
                     ? "Photos not yet backed up by Libarrie are included in your encrypted device backup, if you have one enabled."
                     : "Photos not yet backed up by Libarrie exist only on this device until they upload. Losing the device loses them.")
            }
            if !pending.files.isEmpty {
                Section {
                    ShareLink(items: pending.files) {
                        Label("Save \(pending.files.count) photos waiting to upload", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Copies the original photos, for example to Files, so they are not only on this device.")
                }
            }
        }
        .navigationTitle("Settings")
        .task { await pending.load(app) }
        .task { await account.loadSettings() }
    }
}

// MARK: Usage

@MainActor @Observable final class UsageModel {
    let app: AppModel
    var usage: Usage?
    var awaiting: [Page] = []
    var message: (Banner.Kind, String)?
    var processing = false

    init(app: AppModel) { self.app = app }

    func load() async {
        guard let api = app.services?.api else { return }
        do {
            usage = try await api.usage()
            awaiting = try await api.awaitingProcessing()
        } catch {
            message = (.danger, describe(error))
        }
    }

    func processNow() async {
        guard let api = app.services?.api else { return }
        processing = true
        defer { processing = false }
        let items = awaiting.compactMap { page in
            page.revisionId.map { (pageId: page.id, sourceRevisionId: $0, operationId: UUID().uuidString.lowercased()) }
        }
        guard !items.isEmpty else { return }
        do {
            let results = try await api.processDeferred(items)
            let started = results.filter { $0.result == "admitted" || $0.result == "already_admitted" }.count
            let limited = results.filter { $0.result == "limit" }.count
            message = limited == 0
                ? (.ok, "^[\(started) page](inflect: true) started processing.")
                : (.warning, "\(started) started; \(limited) still wait because your processing allowance is used up.")
            await load()
        } catch {
            message = (.danger, describe(error))
        }
    }
}

struct UsageView: View {
    let model: UsageModel

    var body: some View {
        List {
            if let (kind, text) = model.message { Banner(kind: kind, text: text) }
            if let usage = model.usage {
                switch usage.capacityWarning {
                case "at_capacity": Banner(kind: .warning, text: "You have reached your page limit. Existing notes stay readable and searchable; new pages cannot be added.")
                case "above_90_percent": Banner(kind: .warning, text: "You have used more than 90% of your page limit.")
                case "above_80_percent": Banner(kind: .info, text: "You have used more than 80% of your page limit.")
                default: EmptyView()
                }
                Section {
                    LabeledContent("Stored pages", value: "\(usage.storedPages) of \(limit(usage.limits.storedPages))")
                    LabeledContent("Uploads in progress", value: "\(usage.reservedPageSlots)")
                    LabeledContent("Notebooks", value: "\(usage.notebooks) of \(limit(usage.limits.notebooks))")
                    if let allowance = usage.lifetimeAllowance {
                        LabeledContent("Pages processed", value: "\(allowance.used) of \(limit(allowance.limit))"
                                       + (allowance.reserved > 0 ? " (\(allowance.reserved) in progress)" : ""))
                    }
                }
            }
            if !model.awaiting.isEmpty {
                Section {
                    Text("^[\(model.awaiting.count) page](inflect: true) uploaded to be processed later. They are stored and viewable, but not yet searchable.")
                    Button(model.processing ? "Starting…" : "Process now") { Task { await model.processNow() } }
                        .disabled(model.processing)
                } header: {
                    Text("Waiting for processing")
                }
            }
        }
        .navigationTitle("Usage")
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    func limit(_ limit: Limit) -> String { limit.value.map(String.init) ?? "unlimited" }
}

// MARK: Trash

@MainActor @Observable final class TrashModel {
    let app: AppModel
    var trash: TrashList?
    var message: (Banner.Kind, String)?
    var purgeTarget: PurgeTarget?

    enum PurgeTarget: Identifiable {
        case page(Page), notebook(Notebook), everything
        var id: String {
            switch self { case .page(let p): "p" + p.id; case .notebook(let n): "n" + n.id; case .everything: "all" }
        }
    }

    init(app: AppModel) { self.app = app }

    func load() async {
        do { trash = try await app.services?.api.trash() } catch { message = (.danger, describe(error)) }
    }

    func restore(page: Page) async {
        do {
            try await app.services?.api.restorePage(page.id)
            message = (.ok, "Restoring. It will reappear shortly.")
            await load()
        } catch { message = (.danger, describe(error)) }
    }

    func restore(notebook: Notebook) async {
        do {
            try await app.services?.api.restoreNotebook(notebook.id)
            message = (.ok, "Restoring. It will appear in your notebooks shortly.")
            await load()
        } catch { message = (.danger, describe(error)) }
    }

    func purge(_ target: PurgeTarget) async {
        guard let api = app.services?.api else { return }
        do {
            try await withRecentSignIn(app) {
                switch target {
                case .page(let page): try await api.purge(pageIds: [page.id])
                case .notebook(let notebook): try await api.purge(notebookIds: [notebook.id])
                case .everything: try await api.purge(all: true)
                }
            }
            message = (.ok, "Deleting permanently. This can take a few minutes to finish.")
            await load()
        } catch let error as APIError where error.code == "recovery_pending" {
            message = (.warning, "Your previous change to this item is still being recorded safely. Try again in a minute.")
        } catch {
            message = (.danger, describe(error))
        }
    }
}

struct TrashView: View {
    @Bindable var model: TrashModel

    var body: some View {
        List {
            if let (kind, text) = model.message { Banner(kind: kind, text: text) }
            Text("Items in trash are deleted permanently after \(model.trash?.retentionDays ?? 30) days.")
                .font(.footnote).foregroundStyle(Brand.textMuted)
            if let trash = model.trash {
                if trash.pages.isEmpty && trash.notebooks.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash")
                }
                if !trash.notebooks.isEmpty {
                    Section("Notebooks") {
                        ForEach(trash.notebooks) { notebook in
                            row(notebook.name, restore: { await model.restore(notebook: notebook) },
                                purge: { model.purgeTarget = .notebook(notebook) })
                        }
                    }
                }
                if !trash.pages.isEmpty {
                    Section("Pages") {
                        ForEach(trash.pages) { page in
                            row("\(page.notebook.name) · Page \(page.pageNumber)", restore: { await model.restore(page: page) },
                                purge: { model.purgeTarget = .page(page) })
                        }
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .task { await model.load() }
        .refreshable { await model.load() }
        .toolbar {
            if let trash = model.trash, !(trash.pages.isEmpty && trash.notebooks.isEmpty) {
                ToolbarItem { Button("Empty trash", role: .destructive) { model.purgeTarget = .everything } }
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: Binding(get: { model.purgeTarget != nil }, set: { if !$0 { model.purgeTarget = nil } }),
                            titleVisibility: .visible, presenting: model.purgeTarget) { target in
            Button("Delete permanently", role: .destructive) { Task { await model.purge(target) } }
        } message: { _ in
            Text("This removes the photos, transcripts and search data and cannot be undone. You will be asked to sign in again to confirm.")
        }
    }

    func row(_ title: String, restore: @escaping () async -> Void, purge: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Restore") { Task { await restore() } }.buttonStyle(.bordered)
            Button(role: .destructive) { purge() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(title) permanently")
        }
    }
}

// MARK: Exports

@MainActor @Observable final class ExportsModel {
    let app: AppModel
    var exports: [Export] = []
    var parts: [String: [ExportPart]] = [:]
    var includeTrash = false
    var message: (Banner.Kind, String)?
    var working = false

    init(app: AppModel) { self.app = app }

    var preparing: Bool { exports.contains { $0.state == "assembling" } }

    func load() async {
        guard let api = app.services?.api else { return }
        do {
            exports = try await api.exports()
            for export in exports where export.state == "completed" && parts[export.id] == nil {
                parts[export.id] = try? await api.export(export.id).parts
            }
        } catch { message = (.danger, describe(error)) }
    }

    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if preparing { await load() }
        }
    }

    func start() async {
        guard let api = app.services?.api else { return }
        working = true
        defer { working = false }
        do {
            _ = try await api.createExport(notebookIds: nil, includeTrash: includeTrash)
            message = (.ok, "Export started. This screen updates when your files are ready.")
            await load()
        } catch { message = (.danger, describe(error)) }
    }

    func url(export: Export, part: ExportPart) async -> URL? {
        do { return try await app.services?.api.exportPartURL(exportId: export.id, part: part.partNumber).url } catch {
            message = (.danger, describe(error))
            return nil
        }
    }
}

struct ExportsView: View {
    @Bindable var model: ExportsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let (kind, text) = model.message { Banner(kind: kind, text: text) }
            Section {
                Toggle("Include pages in trash", isOn: $model.includeTrash)
                Button(model.working ? "Starting…" : "Export everything") { Task { await model.start() } }.disabled(model.working)
            } footer: {
                Text("Every original photo with its transcript, in ZIP files. Downloads stay available for 7 days.")
            }
            Section("Your exports") {
                if model.exports.isEmpty { Text("No exports yet.").foregroundStyle(Brand.textMuted) }
                ForEach(model.exports) { export in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(formatDate(export.createdAt)).font(.headline)
                            Spacer()
                            Text(stateLabel(export.state)).font(.caption.weight(.semibold))
                        }
                        Text("^[\(export.itemCount) page](inflect: true)" + (export.totalBytes > 0 ? " · \(formatBytes(export.totalBytes))" : "")
                             + (export.state == "completed" ? " · until \(formatDate(export.expiresAt))" : ""))
                            .font(.caption).foregroundStyle(Brand.textMuted)
                        ForEach(model.parts[export.id] ?? []) { part in
                            Button("Download part \(part.partNumber)" + (part.bytes.map { " (\(formatBytes($0)))" } ?? "")) {
                                Task { if let url = await model.url(export: export, part: part) { openURL(url) } }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .navigationTitle("Exports")
        .task { await model.load() }
        .task { await model.watch() }
        .refreshable { await model.load() }
    }

    func stateLabel(_ state: String) -> String {
        switch state {
        case "assembling": "Preparing"
        case "completed": "Ready"
        case "expired": "Expired"
        case "failed": "Failed"
        default: state.capitalized
        }
    }
}
