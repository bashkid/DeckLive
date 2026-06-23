import Foundation

/// Drives the Google Form overlay's visibility during presentation. The
/// list of forms lives on `DeckStore` (deck-scoped, persisted via the
/// sidecar) — this store only tracks "which form, if any, is on screen
/// right now?", which is presentation-session state.
@MainActor
final class GoogleFormStore: ObservableObject {
    @Published var showingForm: SavedForm?

    var isShowing: Bool { showingForm != nil }

    func show(_ form: SavedForm) { showingForm = form }
    func hide() { showingForm = nil }

    /// Rewrites a Google Forms URL so it loads in embedded mode (no
    /// Google chrome around the form). Falls through for non-Google URLs.
    static func embedded(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }

        if components.host?.contains("docs.google.com") == true,
           components.path.contains("/forms/") {
            var query = components.queryItems ?? []
            if !query.contains(where: { $0.name == "embedded" }) {
                query.append(URLQueryItem(name: "embedded", value: "true"))
            }
            components.queryItems = query
        }

        return components.url
    }
}
