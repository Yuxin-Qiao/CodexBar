import Foundation
import IOKit.ps

enum CodexCostCatchUpMode: String, Sendable {
    case automatic
    case accelerated

    var scanDurationPerRefresh: TimeInterval {
        switch self {
        case .automatic: CodexCostCatchUpPolicy.automaticBurstDuration
        case .accelerated: 10
        }
    }
}

enum CodexCostCatchUpPowerSource: String, Sendable {
    case ac
    case battery
    case unknown

    static func current() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return .unknown
        }
        if source == kIOPSACPowerValue as String {
            return .ac
        }
        if source == kIOPSBatteryPowerValue as String {
            return .battery
        }
        return .unknown
    }
}

struct CodexCostCatchUpResourceState: Sendable, Equatable {
    let powerSource: CodexCostCatchUpPowerSource
    let lowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState

    var isConstrained: Bool {
        self.lowPowerModeEnabled
            || self.thermalState == .serious
            || self.thermalState == .critical
    }
}

enum CodexCostCatchUpPauseReason: Sendable, Equatable {
    case lowPower
    case thermal
    case user
    case noProgress
    case error(String)
}

struct CodexCostCatchUpActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case indexing
        case paused
        case complete
    }

    let phase: Phase
    let mode: CodexCostCatchUpMode
    let processedBytes: Int64
    let totalBytes: Int64
    let completedFiles: Int
    let totalFiles: Int
    let pauseReason: CodexCostCatchUpPauseReason?
    let staleSnapshotUpdatedAt: Date?

    var fractionCompleted: Double? {
        guard self.totalBytes > 0 else {
            guard self.totalFiles > 0 else { return nil }
            return min(1, max(0, Double(self.completedFiles) / Double(self.totalFiles)))
        }
        return min(1, max(0, Double(self.processedBytes) / Double(self.totalBytes)))
    }
}

struct CodexCostCatchUpPolicy: Sendable {
    struct Input: Sendable {
        let mode: CodexCostCatchUpMode
        let previousActiveDuration: TimeInterval?
        let powerSource: CodexCostCatchUpPowerSource
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    struct Decision: Sendable, Equatable {
        enum Action: Sendable, Equatable {
            case runAfter(TimeInterval)
            case pause(TimeInterval, CodexCostCatchUpPauseReason)
        }

        let action: Action
        let targetDutyCycle: Double?
    }

    static let automaticBurstDuration: TimeInterval = 2
    static let constrainedRetryDelay: TimeInterval = 60

    func decision(for input: Input) -> Decision {
        if input.thermalState == .critical {
            return Decision(
                action: .pause(Self.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil)
        }
        if input.mode == .automatic, input.thermalState == .serious {
            return Decision(
                action: .pause(Self.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil)
        }
        if input.mode == .accelerated {
            return Decision(action: .runAfter(0), targetDutyCycle: 1)
        }

        let dutyCycle = switch (input.lowPowerModeEnabled, input.powerSource) {
        case (true, .ac): 0.0005
        case (true, .unknown): 0.00025
        case (true, .battery): 0.0001
        case (false, .ac): 0.001
        case (false, .unknown): 0.0005
        case (false, .battery): 0.0002
        }
        let activeDuration = max(0, input.previousActiveDuration ?? Self.automaticBurstDuration)
        let delay = activeDuration * (1 - dutyCycle) / dutyCycle
        return Decision(action: .runAfter(delay), targetDutyCycle: dutyCycle)
    }
}
