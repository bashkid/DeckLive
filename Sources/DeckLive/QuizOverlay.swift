import SwiftUI

/// Full-screen quiz card that drops over the slide between pages, Slido-
/// style. Shows the five generated questions one at a time, then a score
/// summary at the end. Captures all gestures while visible so an
/// accidental click doesn't advance the slide behind it.
struct QuizOverlay: View {

    @ObservedObject var store: QuizStore
    /// Provided by the presenter so the options card can fire generation
    /// against the deck store on confirm.
    var onConfirmGeneration: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* swallow */ }

            card
                .frame(maxWidth: 760)
                .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var card: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .selectingOptions(let throughPage):
            optionsCard(throughPage: throughPage)
        case .generating(let throughPage):
            generatingCard(throughPage: throughPage)
        case .presented(let set):
            questionCard(set: set)
        case .results(let set):
            resultsCard(set: set)
        case .error(let message, _):
            errorCard(message: message)
        }
    }

    // MARK: - Options card (matches the reference design)

    private func optionsCard(throughPage: Int) -> some View {
        VStack(spacing: 18) {
            Text("Options")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.10))
                )

            optionsSection(title: "Question type") {
                HStack(spacing: 12) {
                    ForEach(QuizOptions.QuestionType.allCases) { kind in
                        questionTypeCard(kind: kind)
                    }
                }
            }

            optionsSection(title: "Bloom's Taxonomy Levels", trailingEmoji: "🌈") {
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(QuizOptions.BloomLevel.allCases) { level in
                        bloomLevelChip(level: level)
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                optionsSection(title: "Question Language") {
                    Menu {
                        ForEach(QuizOptions.supportedLanguages, id: \.self) { lang in
                            Button(lang) { store.options.language = lang }
                        }
                    } label: {
                        HStack {
                            Text(store.options.language)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                optionsSection(title: "Number of Questions") {
                    HStack(spacing: 10) {
                        Button {
                            store.options.numberOfQuestions = max(
                                QuizOptions.numberRange.lowerBound,
                                store.options.numberOfQuestions - 1
                            )
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.options.numberOfQuestions <= QuizOptions.numberRange.lowerBound)

                        Text("\(store.options.numberOfQuestions)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .frame(minWidth: 40)

                        Button {
                            store.options.numberOfQuestions = min(
                                QuizOptions.numberRange.upperBound,
                                store.options.numberOfQuestions + 1
                            )
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.options.numberOfQuestions >= QuizOptions.numberRange.upperBound)

                        Text("(\(QuizOptions.numberRange.lowerBound)–\(QuizOptions.numberRange.upperBound))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
                }
            }

            HStack {
                Button("Cancel") { store.dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Text("From slides 1–\(throughPage + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onConfirmGeneration()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    store.options.questionTypes.isEmpty
                    || store.options.bloomLevels.isEmpty
                )
            }
        }
        .padding(28)
        .frame(maxWidth: 720)
        .background(cardBackground)
    }

    private func optionsSection<Content: View>(
        title: String,
        trailingEmoji: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                if let trailingEmoji {
                    Text(trailingEmoji)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionTypeCard(kind: QuizOptions.QuestionType) -> some View {
        let isSelected = store.options.questionTypes.contains(kind)
        return Button {
            if isSelected {
                if store.options.questionTypes.count > 1 {
                    store.options.questionTypes.remove(kind)
                }
            } else {
                store.options.questionTypes.insert(kind)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 26))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .padding(8)
                    }
                }
                Text(kind.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func bloomLevelChip(level: QuizOptions.BloomLevel) -> some View {
        let isSelected = store.options.bloomLevels.contains(level)
        return Button {
            if isSelected {
                if store.options.bloomLevels.count > 1 {
                    store.options.bloomLevels.remove(level)
                }
            } else {
                store.options.bloomLevels.insert(level)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(level.label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - States

    private func generatingCard(throughPage: Int) -> some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Generating \(store.options.numberOfQuestions) quiz questions…")
                .font(.title3)
            Text("From slides 1–\(throughPage + 1)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .background(cardBackground)
    }

    private func questionCard(set: QuizSet) -> some View {
        guard let question = store.currentQuestion else {
            return AnyView(errorCard(message: "Couldn't show this question."))
        }

        let revealed = store.isCurrentRevealed
        let selected = store.selectedOptionForCurrent

        return AnyView(
            VStack(alignment: .leading, spacing: 20) {
                header(set: set)

                if !question.bloomLevel.isEmpty {
                    bloomChip(question.bloomLevel)
                }

                Text(question.question)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(question.options.indices, id: \.self) { i in
                        optionRow(
                            index: i,
                            text: question.options[i],
                            correctIndex: question.correctIndex,
                            isSelected: selected == i,
                            revealed: revealed
                        )
                    }
                }

                if revealed {
                    explanationView(question.explanation)
                }

                questionFooter(set: set, revealed: revealed)
            }
            .padding(36)
            .background(cardBackground)
        )
    }

    private func resultsCard(set: QuizSet) -> some View {
        let score = store.score
        let total = set.count
        let percent = total == 0 ? 0 : Int(round(Double(score) / Double(total) * 100))

        return VStack(spacing: 22) {
            Image(systemName: scoreIcon(score: score, total: total))
                .font(.system(size: 44))
                .foregroundStyle(scoreColor(score: score, total: total))

            Text("Quiz complete")
                .font(.title2.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(score)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(score: score, total: total))
                Text("/ \(total)")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("\(percent)% correct · \(scoreBlurb(score: score, total: total))")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                ForEach(0..<total, id: \.self) { i in
                    outcomeDot(for: i)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button {
                    store.review()
                } label: {
                    Label("Review answers", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    store.dismiss()
                } label: {
                    Label("Close", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .background(cardBackground)
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't generate the quiz")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { store.dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(36)
        .frame(maxWidth: 480)
        .background(cardBackground)
    }

    // MARK: - Pieces

    private func header(set: QuizSet) -> some View {
        HStack(spacing: 10) {
            Label("Quiz · Slides 1–\(set.throughPage + 1)", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Question \(store.currentQuestionIndex + 1) of \(set.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

            Button {
                store.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close quiz (Esc)")
        }
    }

    private func questionFooter(set: QuizSet, revealed: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<set.count, id: \.self) { i in
                    Circle()
                        .fill(progressDotColor(i))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            Button {
                store.previousQuestion()
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.isOnFirstQuestion)

            if !revealed {
                Button {
                    store.revealCurrent()
                } label: {
                    Label("Reveal", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if store.isOnLastQuestion {
                Button {
                    store.finish()
                } label: {
                    Label("Finish", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    store.nextQuestion()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func progressDotColor(_ index: Int) -> Color {
        if index == store.currentQuestionIndex { return .accentColor }
        if store.revealedQuestions.contains(index) { return .accentColor.opacity(0.5) }
        return Color.primary.opacity(0.15)
    }

    private func outcomeDot(for index: Int) -> some View {
        let outcome = store.outcome(for: index)
        let color: Color = {
            switch outcome {
            case .correct: return .green
            case .incorrect: return .red
            case .unanswered: return Color.primary.opacity(0.2)
            }
        }()
        let systemName: String = {
            switch outcome {
            case .correct: return "checkmark"
            case .incorrect: return "xmark"
            case .unanswered: return "minus"
            }
        }()
        return ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 36, height: 36)
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 36, height: 36)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
        }
        .overlay(alignment: .bottom) {
            Text("\(index + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(y: 16)
        }
    }

    private func optionRow(
        index: Int,
        text: String,
        correctIndex: Int,
        isSelected: Bool,
        revealed: Bool
    ) -> some View {
        let isCorrect = index == correctIndex

        let stateBackground: Color = {
            if revealed && isCorrect { return Color.green.opacity(0.22) }
            if revealed && isSelected && !isCorrect { return Color.red.opacity(0.22) }
            if isSelected { return Color.accentColor.opacity(0.18) }
            return Color.primary.opacity(0.06)
        }()

        let stateBorder: Color = {
            if revealed && isCorrect { return .green }
            if revealed && isSelected && !isCorrect { return .red }
            if isSelected { return .accentColor }
            return .clear
        }()

        return Button {
            store.select(option: index)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(stateBorder == .clear ? Color.primary.opacity(0.25) : stateBorder, lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                    Text(letter(for: index))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if revealed && isCorrect {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if revealed && isSelected && !isCorrect {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(stateBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(stateBorder, lineWidth: stateBorder == .clear ? 0 : 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Small pill that shows which Bloom's taxonomy level the model
    /// tagged the current question with, color-coded for quick scanning.
    private func bloomChip(_ level: String) -> some View {
        let color = bloomColor(level)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("Bloom: \(level)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func bloomColor(_ level: String) -> Color {
        switch level {
        case "Remember":   return .blue
        case "Understand": return .teal
        case "Apply":      return .green
        case "Analyze":    return .orange
        case "Evaluate":   return .pink
        case "Create":     return .purple
        default:           return .secondary
        }
    }

    private func explanationView(_ explanation: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
    }

    private func letter(for index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    // MARK: - Score helpers

    private func scoreIcon(score: Int, total: Int) -> String {
        guard total > 0 else { return "questionmark.circle" }
        let ratio = Double(score) / Double(total)
        switch ratio {
        case 1.0:           return "trophy.fill"
        case 0.6...:        return "checkmark.seal.fill"
        case 0.4..<0.6:     return "hand.thumbsup.fill"
        default:            return "book.fill"
        }
    }

    private func scoreColor(score: Int, total: Int) -> Color {
        guard total > 0 else { return .secondary }
        let ratio = Double(score) / Double(total)
        switch ratio {
        case 0.8...: return .green
        case 0.5...: return .accentColor
        case 0.3...: return .orange
        default:     return .red
        }
    }

    private func scoreBlurb(score: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        let ratio = Double(score) / Double(total)
        switch ratio {
        case 1.0:    return "Perfect run."
        case 0.8...: return "Excellent."
        case 0.6...: return "Solid understanding."
        case 0.4...: return "Worth another look."
        default:     return "Time for a review."
        }
    }
}
