import LibarrieKit
import Observation
import SwiftUI

public enum Route: Hashable, Sendable {
    case notebook(String)
    case page(String)
    case trash
    case exports
    case usage
    case settings
    case deleteAccount
}

public enum Tab: Hashable, Sendable { case notebooks, search, uploads, account }

/// Tab selection, navigation paths and the screen models behind them.
/// Models are cached per route so they keep their state across re-renders.
@MainActor @Observable public final class Navigator {
    public var tab: Tab = .notebooks
    public var notebooksPath: [Route] = []
    public var searchPath: [Route] = []
    public var accountPath: [Route] = []
    /// The capture flow in progress (sheet).
    public var capture: CaptureModel?

    @ObservationIgnored private var models: [Route: AnyObject] = [:]
    @ObservationIgnored let app: AppModel
    @ObservationIgnored lazy var notebooks = NotebooksModel(app: app)
    @ObservationIgnored lazy var search = SearchModel(app: app)
    @ObservationIgnored lazy var account = AccountModel(app: app)

    public init(app: AppModel) { self.app = app }

    func model<M: AnyObject>(_ route: Route, make: () -> M) -> M {
        if let existing = models[route] as? M { return existing }
        let model = make()
        models[route] = model
        return model
    }

    /// Drop models for screens no longer on any stack.
    func prune() {
        let live = Set(notebooksPath + searchPath + accountPath)
        models = models.filter { live.contains($0.key) }
    }

    func startCapture(notebook: Notebook?) {
        capture = CaptureModel(app: app, batch: UUID(), notebook: notebook)
    }

    func resumeCapture(batch: UUID) {
        capture = CaptureModel(app: app, batch: batch, notebook: nil)
    }

    @ViewBuilder func destination(_ route: Route) -> some View {
        switch route {
        case .notebook(let id): NotebookView(model: model(route) { NotebookModel(app: app, id: id) }, navigator: self)
        case .page(let id): PageView(model: model(route) { PageModel(app: app, id: id) }, navigator: self)
        case .trash: TrashView(model: model(route) { TrashModel(app: app) })
        case .exports: ExportsView(model: model(route) { ExportsModel(app: app) })
        case .usage: UsageView(model: model(route) { UsageModel(app: app) })
        case .settings: SettingsView(app: app, account: account)
        case .deleteAccount: DeleteAccountView(model: account)
        }
    }
}

/// Runs an action that needs a sign-in within the last five minutes,
/// asking for a fresh sign-in first when needed.
@MainActor func withRecentSignIn(_ app: AppModel, _ action: () async throws -> Void) async throws {
    if !(await app.hasRecentSignIn()) { try await app.reauthenticate() }
    do {
        try await action()
    } catch let error as APIError where error.code == "reauthentication_required" {
        try await app.reauthenticate()
        try await action()
    }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
}
