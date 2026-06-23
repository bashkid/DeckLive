import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wraps the on-device FoundationModels session that turns slide text into
/// a `QuizSet` of five multiple-choice questions. All entry points are
/// availability-gated to macOS 26+ since FoundationModels only ships there;
/// on older systems the generator throws `.unavailable` so the UI can show
/// a friendly message.
struct QuizGenerator {

    enum GeneratorError: LocalizedError {
        case unavailable(reason: String)
        case emptySlideText
        case noQuestionsGenerated
        case generationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return reason
            case .emptySlideText:
                return "Not enough slide content to generate a quiz yet — show a few slides first."
            case .noQuestionsGenerated:
                return "The model didn't return any usable questions. Try again."
            case .generationFailed(let underlying):
                return "Quiz generation failed: \(underlying.localizedDescription)"
            }
        }
    }

    /// Generates a five-question quiz drawn from the slides that have been
    /// covered so far in the presentation, shaped by the user-selected
    /// `QuizOptions`. The last entry's page number becomes the `throughPage`
    /// of the returned set so the UI can label what was covered.
    @MainActor
    static func generateSet(
        fromCoveredSlides slides: [(pageNumber: Int, text: String)],
        options: QuizOptions
    ) async throws -> QuizSet {
        guard !slides.isEmpty else { throw GeneratorError.emptySlideText }

        let combinedLength = slides.reduce(0) { $0 + $1.text.count }
        guard combinedLength >= 24 else { throw GeneratorError.emptySlideText }

        let throughPageZeroBased = (slides.last?.pageNumber ?? 1) - 1

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generateOnDevice(
                slides: slides,
                options: options,
                throughPage: throughPageZeroBased
            )
        } else {
            throw GeneratorError.unavailable(
                reason: "AI quiz generation requires macOS 26 (Apple Intelligence) or later."
            )
        }
        #else
        throw GeneratorError.unavailable(
            reason: "AI quiz generation isn't available in this build."
        )
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @MainActor
    private static func generateOnDevice(
        slides: [(pageNumber: Int, text: String)],
        options: QuizOptions,
        throughPage: Int
    ) async throws -> QuizSet {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw GeneratorError.unavailable(reason: "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw GeneratorError.unavailable(reason: "Turn on Apple Intelligence in System Settings to generate quizzes.")
        case .unavailable(.modelNotReady):
            throw GeneratorError.unavailable(reason: "The on-device model is still downloading — try again in a minute.")
        case .unavailable:
            throw GeneratorError.unavailable(reason: "The on-device model is unavailable right now.")
        }

        let count = max(QuizOptions.numberRange.lowerBound,
                        min(QuizOptions.numberRange.upperBound, options.numberOfQuestions))

        // Stricter, more correctness-focused instructions. Each rule is
        // numbered and the per-question Bloom-level tag is mandatory, so
        // the model has to commit to which level it satisfied.
        let instructions = """
        You are a careful teacher writing a \(count)-question quiz to check student understanding \
        of a sequence of slides.

        Strict rules — follow every single one:
        1. Generate EXACTLY \(count) questions — no more, no fewer.
        2. Every question MUST be answerable from the slide text alone. Do not introduce facts \
           that aren't in the slides.
        3. Each question has exactly four short options (under 12 words). Exactly one option is \
           the correct answer; the other three are plausible but clearly wrong.
        4. The `correctIndex` field MUST be the zero-based index in `options` of the option that \
           is unambiguously the correct answer. Double-check this against the slide content \
           before committing.
        5. Spread questions across different slides. Do not write all of them from a single slide \
           when multiple slides have content.
        6. Avoid trick questions, double negatives, "all of the above"/"none of the above", and \
           anything ambiguous.
        7. Distribute the questions across these Bloom's taxonomy levels as evenly as possible: \
           \(options.bloomLevelDescription). Each question's `bloomLevel` field MUST be set to \
           exactly one of these requested levels — never invent a level outside this list, never \
           leave it blank.
              - Remember: recall facts and basic concepts.
              - Understand: explain ideas or concepts.
              - Apply: use information in new situations.
              - Analyze: draw connections among ideas.
              - Evaluate: justify a decision or stand.
              - Create: produce new or original work.
        8. Style the questions as \(options.questionTypeDescription). For fill-in-the-blank items, \
           include "___" in the question text and have the four options be candidate fills. For \
           short-answer items, write the question naturally and supply four candidate answers.
        9. Write everything in \(options.language).
        """

        let session = LanguageModelSession(instructions: instructions)

        let slidesBlock = slides
            .map { "--- Slide \($0.pageNumber) ---\n\($0.text)" }
            .joined(separator: "\n\n")

        let prompt = """
        Slide content the audience has seen so far:

        \(slidesBlock)

        Write EXACTLY \(count) distinct \(options.questionTypeDescription) questions that together \
        test understanding across these slides. Each question's `bloomLevel` MUST be one of: \
        \(options.bloomLevelDescription). Make sure each question's `correctIndex` matches the \
        option that's actually correct based on the slide text.
        """

        // Low temperature keeps the model from hallucinating wrong answers
        // or picking the wrong correctIndex creatively.
        let generationOptions = GenerationOptions(temperature: 0.2)

        do {
            let response = try await session.respond(
                to: prompt,
                generating: GenerableQuizSet.self,
                options: generationOptions
            )
            let normalized = normalize(
                response.content.questions.map(\.asQuizQuestion),
                throughPage: throughPage,
                requestedCount: count,
                allowedBloomLevels: options.bloomLevels
            )
            guard !normalized.questions.isEmpty else {
                throw GeneratorError.noQuestionsGenerated
            }
            return normalized
        } catch let error as GeneratorError {
            throw error
        } catch {
            throw GeneratorError.generationFailed(underlying: error)
        }
    }
    #endif

    /// Drops malformed questions (need at least 2 options, non-empty
    /// text), clamps each `correctIndex` into range, normalizes the
    /// Bloom level to one of the requested labels, and trims the list
    /// to the requested question count.
    private static func normalize(
        _ questions: [QuizQuestion],
        throughPage: Int,
        requestedCount: Int,
        allowedBloomLevels: Set<QuizOptions.BloomLevel>
    ) -> QuizSet {
        let allowedLabels = Set(allowedBloomLevels.map(\.label))
        let cleaned: [QuizQuestion] = questions.compactMap { q in
            let trimmedQ = q.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let opts = q.options
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !trimmedQ.isEmpty, opts.count >= 2 else { return nil }
            let correct = max(0, min(q.correctIndex, opts.count - 1))
            let level = normalizeBloomLevel(q.bloomLevel, allowed: allowedLabels)
            return QuizQuestion(
                question: trimmedQ,
                options: opts,
                correctIndex: correct,
                explanation: q.explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                bloomLevel: level
            )
        }
        return QuizSet(
            questions: Array(cleaned.prefix(requestedCount)),
            throughPage: throughPage
        )
    }

    /// Coerces the model's `bloomLevel` string to one of the labels the
    /// presenter actually requested. If the model named something else
    /// (capitalization, plural, etc.) we fuzz-match it; if no requested
    /// level matches at all, we fall back to the first allowed one so
    /// the chip always renders a meaningful value.
    private static func normalizeBloomLevel(
        _ raw: String,
        allowed: Set<String>
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowed.contains(trimmed) { return trimmed }
        let lowered = trimmed.lowercased()
        if let match = allowed.first(where: { $0.lowercased() == lowered }) {
            return match
        }
        if let prefixMatch = allowed.first(where: {
            lowered.hasPrefix($0.lowercased()) || $0.lowercased().hasPrefix(lowered)
        }) {
            return prefixMatch
        }
        return allowed.sorted().first ?? "Understand"
    }
}
