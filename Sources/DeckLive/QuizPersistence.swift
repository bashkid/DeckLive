import Foundation
import CryptoKit

/// The on-disk shape of a deck's sidecar file. Holds every cached quiz set
/// and every saved Google Form for that deck, so reopening the file later
/// restores everything the presenter set up before.
///
/// v1 sidecars stored a single `formURL` string. v2 stores a list of
/// `SavedForm` entries (each with a label + page index). The decoder
/// migrates v1 files transparently when they're loaded.
struct DeckSidecar: Codable {
    var version: Int
    var sourceFileName: String?
    /// Legacy v1 single form URL. Read for back-compat; never written by
    /// new versions of the app.
    var formURL: String?
    /// v2 list of forms attached to specific slides.
    var forms: [SavedForm]?
    /// v3 list of whiteboard slides inserted into the deck's slide order.
    var whiteboards: [WhiteboardSlide]?
    var quizzes: [QuizEntry]

    struct QuizEntry: Codable {
        let throughPage: Int
        let set: QuizSet
    }

    init(
        sourceFileName: String?,
        forms: [SavedForm],
        whiteboards: [WhiteboardSlide],
        quizzes: [Int: QuizSet]
    ) {
        self.version = 3
        self.sourceFileName = sourceFileName
        self.formURL = nil
        self.forms = forms
        self.whiteboards = whiteboards
        self.quizzes = quizzes
            .sorted { $0.key < $1.key }
            .map { QuizEntry(throughPage: $0.key, set: $0.value) }
    }

    var quizzesByPage: [Int: QuizSet] {
        Dictionary(uniqueKeysWithValues: quizzes.map { ($0.throughPage, $0.set) })
    }

    /// Normalizes any sidecar (v1 or v2) into a list of `SavedForm`. A v1
    /// sidecar's single URL is migrated to a form on page 0 with a
    /// generic label.
    var normalizedForms: [SavedForm] {
        if let forms, !forms.isEmpty { return forms }
        if let legacy = formURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            return [SavedForm(label: "Form", url: legacy, pageIndex: 0)]
        }
        return []
    }
}

/// Reads and writes deck sidecars. Tries to put the file next to the
/// original deck first (matching the user's intent of "where the ppt is
/// stored"), then falls back to Application Support if that directory
/// isn't writable.
enum QuizPersistence {

    static func load(for sourceURL: URL) -> DeckSidecar? {
        if let data = try? Data(contentsOf: sidecarURL(for: sourceURL)),
           let decoded = try? JSONDecoder().decode(DeckSidecar.self, from: data) {
            return decoded
        }
        if let fallback = try? fallbackURL(for: sourceURL),
           let data = try? Data(contentsOf: fallback),
           let decoded = try? JSONDecoder().decode(DeckSidecar.self, from: data) {
            return decoded
        }
        return nil
    }

    @discardableResult
    static func save(_ sidecar: DeckSidecar, for sourceURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return false }

        let primary = sidecarURL(for: sourceURL)
        if writeAtomically(data, to: primary) { return true }

        if let fallback = try? fallbackURL(for: sourceURL) {
            return writeAtomically(data, to: fallback)
        }
        return false
    }

    // MARK: - URL helpers

    private static func sidecarURL(for sourceURL: URL) -> URL {
        let dir = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base).decklive.json")
    }

    private static func fallbackURL(for sourceURL: URL) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".decklive", isDirectory: true)
            .appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let hashedKey = sha256(sourceURL.standardizedFileURL.path)
        return dir.appendingPathComponent("\(hashedKey).json")
    }

    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
