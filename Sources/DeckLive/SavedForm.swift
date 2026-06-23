import Foundation

/// One Google Form attached to a specific slide in a deck. Each slide can
/// own any number of these, and the sidecar persists them next to the
/// deck file so the same forms come back next session.
struct SavedForm: Identifiable, Equatable, Codable {
    let id: UUID
    var label: String
    var url: String
    /// 0-based index of the slide this form belongs to.
    var pageIndex: Int

    init(id: UUID = UUID(), label: String, url: String, pageIndex: Int) {
        self.id = id
        self.label = label
        self.url = url
        self.pageIndex = pageIndex
    }
}
