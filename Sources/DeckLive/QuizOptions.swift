import Foundation

/// User-selectable parameters that shape how the AI generates the quiz —
/// surfaced in the options popup before generation starts (mirrors the
/// design shown in the user's reference screenshot).
struct QuizOptions: Equatable {
    var questionTypes: Set<QuestionType>
    var bloomLevels: Set<BloomLevel>
    var language: String
    /// Number of questions the model should generate per quiz. The UI
    /// constrains this to `numberRange`.
    var numberOfQuestions: Int

    static let numberRange: ClosedRange<Int> = 3...10

    enum QuestionType: String, CaseIterable, Identifiable, Equatable {
        case multipleChoice
        case fillInTheBlanks
        case shortAnswer
        var id: String { rawValue }

        var label: String {
            switch self {
            case .multipleChoice:   return "Multiple Choice"
            case .fillInTheBlanks:  return "Fill in the Blanks"
            case .shortAnswer:      return "Short Answer"
            }
        }

        var systemImage: String {
            switch self {
            case .multipleChoice:   return "chart.bar.fill"
            case .fillInTheBlanks:  return "rectangle.and.text.magnifyingglass"
            case .shortAnswer:      return "ellipsis.bubble.fill"
            }
        }
    }

    enum BloomLevel: String, CaseIterable, Identifiable, Equatable {
        case remember
        case understand
        case apply
        case analyze
        case evaluate
        case create
        var id: String { rawValue }

        var label: String {
            switch self {
            case .remember:   return "Remember"
            case .understand: return "Understand"
            case .apply:      return "Apply"
            case .analyze:    return "Analyze"
            case .evaluate:   return "Evaluate"
            case .create:     return "Create"
            }
        }
    }

    static let supportedLanguages: [String] = [
        "English", "Spanish", "French", "German", "Hindi", "Japanese", "Chinese (Simplified)", "Portuguese"
    ]

    static let `default` = QuizOptions(
        questionTypes: [.multipleChoice],
        bloomLevels: [.remember, .understand, .apply],
        language: "English",
        numberOfQuestions: 5
    )

    /// Compact phrase used inside the model prompt to describe the user's
    /// selected question types — e.g. "multiple choice or fill-in-the-blank".
    var questionTypeDescription: String {
        let labels = questionTypes.sorted { $0.rawValue < $1.rawValue }.map { qt -> String in
            switch qt {
            case .multipleChoice:  return "multiple choice"
            case .fillInTheBlanks: return "fill-in-the-blank"
            case .shortAnswer:     return "short-answer-style"
            }
        }
        if labels.isEmpty { return "multiple choice" }
        if labels.count == 1 { return labels[0] }
        let head = labels.dropLast().joined(separator: ", ")
        let tail = labels.last ?? ""
        return "\(head), or \(tail)"
    }

    /// Bloom levels combined into one prompt line.
    var bloomLevelDescription: String {
        let labels = bloomLevels.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        if labels.isEmpty { return "Understand" }
        return labels.joined(separator: ", ")
    }
}
