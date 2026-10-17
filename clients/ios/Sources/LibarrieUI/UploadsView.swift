import LibarrieKit
import Observation
import SwiftUI

@MainActor @Observable final class UploadsModel {
    var renumbering: CaptureItem?
    var newNumber = ""
    var removing: CaptureItem?
}

/// The capture queue, with the three distinct states the design requires:
/// saved on this device, uploaded to Libarrie, independent backup verified.
struct UploadsView: View {
    let app: AppModel
    let navigator: Navigator
    @Bindable var model = UploadsModel()

    var body: some View {
        let items = app.accountQueue
        let attention = items.filter { $0.state == .needsUserAction }
        let unreviewed = Dictionary(grouping: items.filter { $0.state == .captured }, by: \.batchId)
        let moving = items.filter { [.ready, .reserving, .uploading, .confirming, .retryableError].contains($0.state) }
        let accepted = items.filter { $0.state == .serverAccepted && $0.backup != .verified }
        let verified = items.filter { $0.state == .serverAccepted && $0.backup == .verified }
        List {
            if app.uploadsNeedSignIn {
                Section {
                    Banner(kind: .warning, text: "Your sign-in expired. Sign in again to continue uploading; nothing is lost.")
                    Button("Sign in again") { Task { try? await app.reauthenticate(); await app.runQueue() } }
                }
            }
            if items.isEmpty && app.otherAccountsQueue.isEmpty {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle",
                                       description: Text("Photos you add appear here until Libarrie has them safely."))
            }
            if !attention.isEmpty {
                Section("Needs your attention") { ForEach(attention) { attentionRow($0) } }
            }
            if !unreviewed.isEmpty {
                Section("Not yet added to a notebook") {
                    ForEach(unreviewed.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { batch in
                        HStack {
                            Text("^[\(unreviewed[batch]!.count) photo](inflect: true) saved on this device")
                            Spacer()
                            Button("Review") { navigator.resumeCapture(batch: batch) }
                        }
                    }
                }
            }
            if !moving.isEmpty {
                Section("Uploading") { ForEach(moving) { movingRow($0) } }
            }
            if !accepted.isEmpty {
                Section {
                    ForEach(accepted) { acceptedRow($0) }
                } header: {
                    Text("Uploaded to Libarrie")
                } footer: {
                    Text("Photos stay on this device until Libarrie confirms an independent backup.")
                }
            }
            if !verified.isEmpty {
                Section("Independent backup verified") {
                    Text("^[\(verified.count) page](inflect: true) safely backed up; the device copies were removed.")
                    Button("Clear this list") { Task { for item in verified { await app.discard(item.id) } } }
                }
            }
            if !app.otherAccountsQueue.isEmpty {
                Section {
                    ForEach(app.otherAccountsQueue) { item in
                        HStack {
                            Text(item.notebookName.map { "\($0), page \(item.pageNumber ?? 0)" } ?? "Photo")
                            Spacer()
                            Button("Delete", role: .destructive) { Task { await app.discard(item.id) } }
                        }
                    }
                } header: {
                    Text("Saved for another account")
                } footer: {
                    Text("These photos belong to a different account and never upload to this one. Sign in to that account to upload them.")
                }
            }
        }
        .navigationTitle("Uploads")
        .refreshable { await app.runQueue() }
        .task {
            while !Task.isCancelled {
                await app.runQueue()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .alert("Choose a page number", isPresented: Binding(get: { model.renumbering != nil }, set: { if !$0 { model.renumbering = nil } })) {
            TextField("Page number", text: $model.newNumber)
            Button("Upload") {
                if let item = model.renumbering, let number = Int(model.newNumber), number >= 1 {
                    Task { await app.renumber(item.id, to: number) }
                }
                model.renumbering = nil
            }
            Button("Cancel", role: .cancel) { model.renumbering = nil }
        } message: {
            Text("Another page in this notebook already has that number.")
        }
        .confirmationDialog("Remove the photo from this device?", isPresented: Binding(get: { model.removing != nil }, set: { if !$0 { model.removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from this device", role: .destructive) {
                if let item = model.removing { Task { await app.removeLocalCopy(item.id) } }
                model.removing = nil
            }
        } message: {
            Text("Libarrie has the photo, but its independent backup is not confirmed yet. Until it is, a server failure could lose it and this device copy is the only other one.")
        }
    }

    func title(_ item: CaptureItem) -> String {
        let name = item.notebookName ?? "Photo"
        if item.isReplacement { return "\(name): new scan for page \(item.pageNumber ?? 0)" }
        return item.pageNumber.map { "\(name), page \($0)" } ?? name
    }

    @ViewBuilder func attentionRow(_ item: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title(item), systemImage: "exclamationmark.triangle").foregroundStyle(Brand.warning)
            Text(item.lastError ?? "This photo needs your attention.").font(.callout)
            HStack {
                switch item.attention {
                case .pageNumberConflict?:
                    Button("Choose number") { model.newNumber = ""; model.renumbering = item }
                case .processingLimit?:
                    Button("Upload now, process later") { Task { await app.decide(.uploadAndProcessLater, batch: item.batchId) } }
                    Button("Keep on device") { Task { await app.decide(.keepOnDevice, batch: item.batchId) } }
                case .captureMissing?:
                    EmptyView()
                default:
                    Button("Try again") { Task { await app.retry(item.id) } }
                }
                Spacer()
                Button("Remove", role: .destructive) { Task { try? await app.cancel(item.id) } }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder func movingRow(_ item: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(item))
            switch item.state {
            case .uploading: Label("Uploading", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(Brand.textMuted)
            case .retryableError:
                Label("Saved on this device. \(item.lastError ?? "Will retry automatically.")", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(Brand.textMuted)
                Button("Try now") { Task { await app.retry(item.id) } }.font(.caption)
            default: Label("Saved on this device, waiting to upload", systemImage: "iphone").font(.caption).foregroundStyle(Brand.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder func acceptedRow(_ item: CaptureItem) -> some View {
        let overdue = (item.acceptedAt.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? false)
        VStack(alignment: .leading, spacing: 4) {
            Text(title(item))
            Label(overdue ? "Backup is taking longer than usual" : "Waiting for independent backup",
                  systemImage: overdue ? "exclamationmark.triangle" : "icloud.and.arrow.up")
                .font(.caption)
                .foregroundStyle(overdue ? Brand.warning : Brand.textMuted)
            if !item.localFileRemoved {
                Button("Remove from this device") { model.removing = item }.font(.caption)
            }
        }
    }
}
