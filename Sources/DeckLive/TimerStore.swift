import Foundation
import AppKit

/// Drives the floating countdown timer shown in the corner of the
/// presenter window. Counts down once per second on the main actor;
/// finishing plays a system beep.
@MainActor
final class TimerStore: ObservableObject {

    @Published private(set) var totalSeconds: Int = 0
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isRunning: Bool = false
    @Published var isVisible: Bool = false

    /// Seconds remaining at which the visible alert (blink + audible
    /// beep) kicks in. Anything <= this threshold and > 0 is "alert".
    static let alertThreshold: Int = 5

    private var task: Task<Void, Never>?
    private var hasBeepedFinish: Bool = false

    var formatted: String {
        let mins = max(0, remainingSeconds) / 60
        let secs = max(0, remainingSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var isFinished: Bool { totalSeconds > 0 && remainingSeconds == 0 }

    /// True during the final-five-seconds warning window, so the badge
    /// can pulse and turn red to signal the audience.
    var isInAlertWindow: Bool {
        remainingSeconds > 0 && remainingSeconds <= Self.alertThreshold
    }

    func start(minutes: Int) {
        start(seconds: max(1, minutes) * 60)
    }

    func start(seconds: Int) {
        let clamped = max(1, seconds)
        totalSeconds = clamped
        remainingSeconds = clamped
        isVisible = true
        hasBeepedFinish = false
        resume()
    }

    func resume() {
        guard remainingSeconds > 0 else { return }
        cancelTask()
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if self.remainingSeconds > 0 {
                        self.remainingSeconds -= 1
                    }
                    // Continuous warning: beep on every tick while we're
                    // in the final-five window (including the final 0)
                    // so the audience hears a steady countdown.
                    if self.remainingSeconds <= Self.alertThreshold,
                       self.remainingSeconds >= 1 {
                        NSSound.beep()
                    }
                    if self.remainingSeconds == 0 {
                        self.isRunning = false
                        if !self.hasBeepedFinish {
                            self.hasBeepedFinish = true
                            NSSound.beep()
                        }
                    }
                }
            }
        }
    }

    func pause() {
        cancelTask()
        isRunning = false
    }

    func toggle() {
        if isRunning { pause() } else { resume() }
    }

    func reset() {
        cancelTask()
        isRunning = false
        remainingSeconds = totalSeconds
        hasBeepedFinish = false
    }

    func dismiss() {
        cancelTask()
        isRunning = false
        isVisible = false
        totalSeconds = 0
        remainingSeconds = 0
        hasBeepedFinish = false
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
