import LibarrieKit
import SwiftUI

/// The app's root: sign-in, the signed-in tabs, or account status.
public struct RootView: View {
    let app: AppModel
    let navigator: Navigator
    @Environment(\.scenePhase) private var scenePhase

    public init(app: AppModel, navigator: Navigator) {
        self.app = app
        self.navigator = navigator
    }

    public var body: some View {
        Group {
            switch app.phase {
            case .starting:
                ProgressView("Opening Libarrie…")
            case .signedOut:
                SignInView(app: app)
            case .signedIn:
                MainView(app: app, navigator: navigator)
            case .accountClosing:
                ClosingAccountView(app: app, model: navigator.account)
            case .accountPurged:
                PurgedAccountView(app: app)
            }
        }
        .tint(Brand.link)
        .preferredColorScheme(app.settings.theme.colorScheme)
        .task { if app.phase == .starting { await app.start() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.runQueue() } }
        }
    }
}

struct SignInView: View {
    @Bindable var app: AppModel
    @Bindable var settings: AppSettings

    init(app: AppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "book.closed")
                    .font(.system(size: 56))
                    .foregroundStyle(Brand.primary)
                    .accessibilityHidden(true)
                Text("Find what you wrote.").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("Photograph your handwritten notebooks, then search them to find the notebook and page you need.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.textMuted)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server").font(.headline)
                    TextField("libarrie.example.com", text: $settings.serverAddress)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .accessibilityHint("The address of your Libarrie server")
                }
                if let error = app.signInError { Banner(kind: .danger, text: error) }
                Button {
                    Task { await app.signIn() }
                } label: {
                    Text(app.isWorking ? "Signing in…" : "Sign in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primary)
                .controlSize(.large)
                .disabled(app.isWorking)
                if !app.queue.isEmpty {
                    Text("\(app.queue.count) photos are saved on this device. They upload after their account signs in again.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
    }
}

struct MainView: View {
    let app: AppModel
    @Bindable var navigator: Navigator

    var body: some View {
        TabView(selection: $navigator.tab) {
            NavigationStack(path: $navigator.notebooksPath) {
                NotebooksView(model: navigator.notebooks, navigator: navigator)
                    .navigationDestination(for: Route.self) { navigator.destination($0) }
            }
            .tabItem { Label("Notebooks", systemImage: "books.vertical") }
            .tag(Tab.notebooks)

            NavigationStack(path: $navigator.searchPath) {
                SearchView(model: navigator.search, navigator: navigator)
                    .navigationDestination(for: Route.self) { navigator.destination($0) }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack {
                UploadsView(app: app, navigator: navigator)
            }
            .tabItem { Label("Uploads", systemImage: "arrow.up.circle") }
            .badge(app.accountQueue.filter { $0.state == .needsUserAction }.count)
            .tag(Tab.uploads)

            NavigationStack(path: $navigator.accountPath) {
                AccountView(model: navigator.account, navigator: navigator)
                    .navigationDestination(for: Route.self) { navigator.destination($0) }
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
            .tag(Tab.account)
        }
        .sheet(item: $navigator.capture) { model in
            CaptureView(model: model, navigator: navigator)
        }
        .onChange(of: navigator.notebooksPath) { navigator.prune() }
        .onChange(of: navigator.searchPath) { navigator.prune() }
        .onChange(of: navigator.accountPath) { navigator.prune() }
    }
}
