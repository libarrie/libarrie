import LibarrieKit
import LibarrieUI
import SwiftUI
import UIKit

/// Receives background upload events after the system relaunches the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let uploads = BackgroundUploads()

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploads.identifier else { return completionHandler() }
        Self.uploads.setSystemCompletion(completionHandler)
    }
}

@main
struct LibarrieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app: AppModel?
    private let navigator: Navigator?
    private let failure: String?

    init() {
        do {
            let app = try AppModel(transfers: AppDelegate.uploads)
            self.app = app
            navigator = Navigator(app: app)
            failure = nil
        } catch {
            app = nil
            navigator = nil
            failure = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let app, let navigator {
                RootView(app: app, navigator: navigator)
            } else {
                Text("Libarrie could not open its storage on this device. \(failure ?? "")").padding()
            }
        }
    }
}
