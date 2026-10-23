import Foundation

/// A cheap acoustic trigger, not a speech recognizer. The existing Sound Analysis gate
/// still decides whether a captured candidate is worth transcribing.
struct AcousticActivityGate {
    enum Transition { case none, start, stop }

    private var recentLevels: [Double] = []
    private var triggerCredit = 0.0
    private var quietCredit = 0.0
    private var activeThreshold = 0.003

    mutating func observe(rms: Double, seconds: Double, recording: Bool) -> Transition {
        guard rms.isFinite, rms >= 0, seconds.isFinite, seconds > 0 else { return .none }
        defer { remember(rms) }
        if recording {
            if rms >= activeThreshold {
                quietCredit = max(0, quietCredit - seconds * 12)
            } else {
                quietCredit += seconds
            }
            if quietCredit >= 30 {
                quietCredit = 0
                triggerCredit = 0
                return .stop
            }
            return .none
        }
        let threshold = max(0.003, ambientFloor * 1.8)
        if rms >= threshold {
            triggerCredit += seconds
        } else {
            triggerCredit = max(0, triggerCredit - seconds * 2)
        }
        if triggerCredit >= 0.35 {
            activeThreshold = threshold
            triggerCredit = 0
            quietCredit = 0
            return .start
        }
        return .none
    }

    private var ambientFloor: Double {
        guard !recentLevels.isEmpty else { return 0.001 }
        let sorted = recentLevels.sorted()
        return sorted[(sorted.count - 1) / 4]
    }

    private mutating func remember(_ rms: Double) {
        recentLevels.append(rms)
        if recentLevels.count > 48 { recentLevels.removeFirst() }
    }
}
