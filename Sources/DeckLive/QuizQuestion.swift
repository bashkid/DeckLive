import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One multiple-choice quiz question generated from slide content. Plain
/// Swift struct so it's available on every OS version DeckLive supports —
/// the FoundationModels-specific guided-generation type lives separately
/// and is converted into this one before reaching the UI.
struct QuizQuestion: Identifiable, Equatable, Codable {
    var id = UUID()
    let question: String
    let options: [String]
    let correctIndex: Int
    let explanation: String
    /// The Bloom's taxonomy level the model assigned this question to —
    /// one of "Remember" / "Understand" / "Apply" / "Analyze" /
    /// "Evaluate" / "Create". Shown as a chip in the question card so
    /// the presenter can see the model honored their selection.
    var bloomLevel: String = ""

    init(
        id: UUID = UUID(),
        question: String,
        options: [String],
        correctIndex: Int,
        explanation: String,
        bloomLevel: String = ""
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.bloomLevel = bloomLevel
    }

    // Decode tolerates older sidecars that don't carry bloomLevel.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try c.decode(String.self, forKey: .question)
        options = try c.decode([String].self, forKey: .options)
        correctIndex = try c.decode(Int.self, forKey: .correctIndex)
        explanation = try c.decode(String.self, forKey: .explanation)
        bloomLevel = try c.decodeIfPresent(String.self, forKey: .bloomLevel) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, question, options, correctIndex, explanation, bloomLevel
    }
}

/// A batch of questions generated together from the slides covered so far.
struct QuizSet: Equatable, Codable {
    let questions: [QuizQuestion]
    /// Inclusive last page index (0-based) the questions were drawn from.
    let throughPage: Int

    var count: Int { questions.count }
}

#if canImport(FoundationModels)

/// Internal mirror of `QuizQuestion` used purely as the model's output
/// schema via the `@Generable` macro. Kept separate so the public
/// `QuizQuestion` doesn't inherit FoundationModels' macOS 26 availability.
@available(macOS 26.0, *)
@Generable
struct GenerableQuizQuestion {
    @Guide(description: "A clear, self-contained question testing one important concept covered in the slides.")
    let question: String

    @Guide(description: "Exactly four short answer options. Exactly one is correct; the others are plausible distractors.")
    let options: [String]

    @Guide(description: "The zero-based index (0, 1, 2, or 3) of the correct option in the options array.")
    let correctIndex: Int

    @Guide(description: "A one-sentence explanation of why the correct answer is right.")
    let explanation: String

    @Guide(description: "Bloom's taxonomy level this question targets. Must be one of exactly: Remember, Understand, Apply, Analyze, Evaluate, Create — and must match one of the levels requested by the presenter.")
    let bloomLevel: String
}

/// Container the model fills with the user-requested number of questions
/// covering the slides presented so far. The count constraint lives in
/// the prompt (and is enforced in `normalize`) rather than as a static
/// guide here, so the presenter can ask for 3–10 questions per run.
@available(macOS 26.0, *)
@Generable
struct GenerableQuizSet {
    @Guide(description: "A list of distinct questions covering different key concepts from the provided slides. Spread coverage so multiple slides are tested, not just one. The exact count is specified in the prompt.")
    let questions: [GenerableQuizQuestion]
}

@available(macOS 26.0, *)
extension GenerableQuizQuestion {
    var asQuizQuestion: QuizQuestion {
        QuizQuestion(
            question: question,
            options: options,
            correctIndex: correctIndex,
            explanation: explanation,
            bloomLevel: bloomLevel
        )
    }
}

#endif
