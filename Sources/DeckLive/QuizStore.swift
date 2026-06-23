import Foundation
import SwiftUI

/// Drives the quiz overlay's lifecycle and navigation across the five
/// generated questions. The store is owned by `PresenterWindowController`
/// and shared with `PresenterView` so the toolbar button and the keyboard
/// monitor can both drive it.
@MainActor
final class QuizStore: ObservableObject {

    enum Phase {
        case idle
        case selectingOptions(throughPage: Int)
        case generating(throughPage: Int)
        case presented(QuizSet)
        case results(QuizSet)
        case error(String, throughPage: Int)
    }

    @Published private(set) var phase: Phase = .idle

    /// User-selected options shown in the pre-generation popup. Persisted
    /// across launches so the presenter doesn't have to re-pick the same
    /// settings every time.
    @Published var options: QuizOptions = QuizStore.loadOptions()

    /// Index into `presentedSet?.questions` of the question currently on
    /// screen. Defaults to 0 when a new set arrives.
    @Published var currentQuestionIndex: Int = 0

    /// Per-question interaction state — keyed by the question's array
    /// index so flipping back to an earlier question preserves what the
    /// audience already chose / saw.
    @Published private(set) var revealedQuestions: Set<Int> = []
    @Published private(set) var selectedOptions: [Int: Int] = [:]

    // MARK: - Convenience

    var isVisible: Bool {
        switch phase {
        case .idle: return false
        case .selectingOptions, .generating, .presented, .results, .error: return true
        }
    }

    var isSelectingOptions: Bool {
        if case .selectingOptions = phase { return true }
        return false
    }

    var presentedSet: QuizSet? {
        if case .presented(let set) = phase { return set }
        return nil
    }

    var activeSet: QuizSet? {
        switch phase {
        case .presented(let set): return set
        case .results(let set): return set
        default: return nil
        }
    }

    var currentQuestion: QuizQuestion? {
        guard let set = presentedSet,
              currentQuestionIndex >= 0,
              currentQuestionIndex < set.questions.count else { return nil }
        return set.questions[currentQuestionIndex]
    }

    var isCurrentRevealed: Bool {
        revealedQuestions.contains(currentQuestionIndex)
    }

    var selectedOptionForCurrent: Int? {
        selectedOptions[currentQuestionIndex]
    }

    var isOnLastQuestion: Bool {
        guard let set = presentedSet else { return false }
        return currentQuestionIndex >= set.questions.count - 1
    }

    var isOnFirstQuestion: Bool {
        currentQuestionIndex == 0
    }

    var isResultsPhase: Bool {
        if case .results = phase { return true }
        return false
    }

    /// Number of questions the audience answered correctly. An unanswered
    /// question counts as incorrect.
    var score: Int {
        guard let set = activeSet else { return 0 }
        var correct = 0
        for (i, q) in set.questions.enumerated() {
            if let chosen = selectedOptions[i], chosen == q.correctIndex {
                correct += 1
            }
        }
        return correct
    }

    /// Per-question outcome used by the results card's progress row.
    enum QuestionOutcome { case correct, incorrect, unanswered }

    func outcome(for index: Int) -> QuestionOutcome {
        guard let set = activeSet, index < set.questions.count else { return .unanswered }
        guard let chosen = selectedOptions[index] else { return .unanswered }
        return chosen == set.questions[index].correctIndex ? .correct : .incorrect
    }

    // MARK: - Lifecycle

    /// Single entry point used by the toolbar button and the Option+Q
    /// shortcut. On a cache hit, replays the previous quiz immediately.
    /// On a miss, opens the options popup so the presenter can tune
    /// question types / Bloom levels / language before generation runs.
    func triggerQuiz(using deckStore: DeckStore) {
        let throughPage = highestPDFPageCovered(in: deckStore)

        revealedQuestions = []
        selectedOptions = [:]
        currentQuestionIndex = 0

        if let cached = deckStore.cachedQuizSet(throughPage: throughPage) {
            phase = .presented(cached)
            return
        }

        phase = .selectingOptions(throughPage: throughPage)
    }

    /// Called from the options popup when the presenter clicks Generate.
    /// Persists their option choices, then kicks off the actual on-device
    /// generation and stores the result in the deck's cache.
    func confirmGeneration(using deckStore: DeckStore) {
        guard case .selectingOptions(let throughPage) = phase else { return }
        Self.saveOptions(options)
        let slides = deckStore.coveredSlidesText()
        phase = .generating(throughPage: throughPage)
        Task { [weak self, options] in
            guard let self else { return }
            do {
                let set = try await QuizGenerator.generateSet(
                    fromCoveredSlides: slides,
                    options: options
                )
                deckStore.cacheQuizSet(set, throughPage: throughPage)
                self.phase = .presented(set)
            } catch {
                self.phase = .error(error.localizedDescription, throughPage: throughPage)
            }
        }
    }

    /// The last PDF page in the unified slide order that the presenter
    /// has shown — used as the cache key and "coverage" indicator.
    private func highestPDFPageCovered(in deckStore: DeckStore) -> Int {
        let order = deckStore.slideOrder
        var lastPDF = 0
        let upTo = min(deckStore.currentPageIndex, order.count - 1)
        if upTo >= 0 {
            for i in 0...upTo {
                if case .pdf(let p) = order[i] {
                    lastPDF = max(lastPDF, p)
                }
            }
        }
        return lastPDF
    }

    func dismiss() {
        phase = .idle
        currentQuestionIndex = 0
        revealedQuestions = []
        selectedOptions = [:]
    }

    // MARK: - Per-question actions

    func select(option index: Int) {
        guard presentedSet != nil, !isCurrentRevealed else { return }
        selectedOptions[currentQuestionIndex] = index
    }

    func revealCurrent() {
        guard presentedSet != nil else { return }
        revealedQuestions.insert(currentQuestionIndex)
    }

    func nextQuestion() {
        guard let set = presentedSet else { return }
        guard currentQuestionIndex + 1 < set.questions.count else { return }
        currentQuestionIndex += 1
    }

    func previousQuestion() {
        guard presentedSet != nil else { return }
        guard currentQuestionIndex > 0 else { return }
        currentQuestionIndex -= 1
    }

    /// Moves from the active quiz into the score screen.
    func finish() {
        guard let set = presentedSet else { return }
        phase = .results(set)
    }

    /// From the results card, lets the user review answers — restores
    /// the `.presented` phase keeping all selections + reveals intact.
    func review() {
        guard case .results(let set) = phase else { return }
        phase = .presented(set)
        currentQuestionIndex = 0
    }

    // MARK: - Options persistence

    private static let optionsDefaultsKey = "DeckLive.QuizOptions"

    private static func loadOptions() -> QuizOptions {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: optionsDefaultsKey),
              let stored = try? JSONDecoder().decode(StoredOptions.self, from: data) else {
            return .default
        }
        return stored.asOptions
    }

    private static func saveOptions(_ options: QuizOptions) {
        let stored = StoredOptions(options)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: optionsDefaultsKey)
        }
    }

    private struct StoredOptions: Codable {
        let questionTypes: [String]
        let bloomLevels: [String]
        let language: String
        let numberOfQuestions: Int?

        init(_ options: QuizOptions) {
            questionTypes = options.questionTypes.map(\.rawValue).sorted()
            bloomLevels = options.bloomLevels.map(\.rawValue).sorted()
            language = options.language
            numberOfQuestions = options.numberOfQuestions
        }

        var asOptions: QuizOptions {
            let qts = Set(questionTypes.compactMap(QuizOptions.QuestionType.init(rawValue:)))
            let bls = Set(bloomLevels.compactMap(QuizOptions.BloomLevel.init(rawValue:)))
            let count = numberOfQuestions ?? 5
            let clamped = max(QuizOptions.numberRange.lowerBound,
                              min(QuizOptions.numberRange.upperBound, count))
            return QuizOptions(
                questionTypes: qts.isEmpty ? [.multipleChoice] : qts,
                bloomLevels: bls.isEmpty ? [.remember, .understand, .apply] : bls,
                language: language.isEmpty ? "English" : language,
                numberOfQuestions: clamped
            )
        }
    }
}
