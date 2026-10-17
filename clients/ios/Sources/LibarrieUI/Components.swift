import LibarrieKit
import SwiftUI

/// Status with words and a symbol, never color alone (section 13).
struct StatusBadge: View {
    let status: String

    var body: some View {
        let (label, symbol, color) = Self.describe(status)
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Status: \(label)")
    }

    static func describe(_ status: String) -> (String, String, Color) {
        switch status {
        case "ready": ("Searchable", "checkmark.circle", Brand.success)
        case "ready_empty": ("Blank page", "doc", Brand.success)
        case "awaiting_processing": ("Waiting for processing", "clock", Brand.textMuted)
        case "queued", "accepted", "validating": ("Queued", "hourglass", Brand.textMuted)
        case "recognizing": ("Reading handwriting", "text.viewfinder", Brand.textMuted)
        case "indexing": ("Indexing", "magnifyingglass", Brand.textMuted)
        case "awaiting_upload": ("Uploading", "arrow.up.circle", Brand.textMuted)
        case "needs_user_action": ("Needs your attention", "exclamationmark.triangle", Brand.warning)
        case "failed": ("Processing failed", "xmark.octagon", Brand.danger)
        case "cancelled": ("Cancelled", "minus.circle", Brand.textMuted)
        default: (status.replacingOccurrences(of: "_", with: " "), "circle", Brand.textMuted)
        }
    }

    static func isProcessing(_ status: String) -> Bool {
        ["queued", "accepted", "validating", "recognizing", "indexing", "awaiting_upload"].contains(status)
    }
}

/// An inline message; announced to VoiceOver when it appears.
struct Banner: View {
    enum Kind { case info, ok, warning, danger }
    let kind: Kind
    let text: String

    var body: some View {
        let (symbol, color): (String, Color) = switch kind {
        case .info: ("info.circle", Brand.textMuted)
        case .ok: ("checkmark.circle", Brand.success)
        case .warning: ("exclamationmark.triangle", Brand.warning)
        case .danger: ("xmark.octagon", Brand.danger)
        }
        Label { Text(text).foregroundStyle(Brand.text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 1.5))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}

struct NotebookDot: View {
    let hex: String?
    var body: some View {
        if let color = Color(notebookHex: hex) {
            Circle().fill(color).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Brand.border, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

/// A page thumbnail or preview from the account's image cache.
@MainActor @Observable final class RemoteImageModel {
    var image: Image?
    var failed = false
    private var loadedKey: String?

    func load(page: Page, variant: ImageCache.Variant, cache: ImageCache?) async {
        let key = "\(page.imageObjectId ?? "")-\(variant.rawValue)"
        guard loadedKey != key, let cache else { return }
        loadedKey = key
        do {
            guard let data = try await cache.data(for: page, variant: variant) else { return }
            image = platformImage(data)
        } catch {
            failed = true
        }
    }
}

func platformImage(_ data: Data) -> Image? {
    #if canImport(UIKit)
    UIImage(data: data).map { Image(uiImage: $0) }
    #else
    NSImage(data: data).map { Image(nsImage: $0) }
    #endif
}

struct PageImage: View {
    let page: Page
    let variant: ImageCache.Variant
    let cache: ImageCache?
    let model = RemoteImageModel()

    var body: some View {
        Group {
            if let image = model.image {
                image.resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Brand.surface)
                    Text("\(page.pageNumber)").font(.title2).foregroundStyle(Brand.textMuted)
                }
                .aspectRatio(3 / 4, contentMode: .fit)
            }
        }
        .accessibilityLabel(variant == .thumb ? "Page \(page.pageNumber)" : "Scan of page \(page.pageNumber)")
        .task(id: page.imageObjectId) { await model.load(page: page, variant: variant, cache: cache) }
    }
}

extension View {
    /// Inline title on iOS; no-op elsewhere.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// `2026-10-13T09:30:00.000000Z` → localized date and time.
func formatDate(_ timestamp: String?) -> String {
    guard let timestamp else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? timestamp
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
