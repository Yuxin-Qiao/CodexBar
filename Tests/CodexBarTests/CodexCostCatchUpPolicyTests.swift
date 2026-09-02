import Foundation
import Testing
@testable import CodexBar

struct CodexCostCatchUpPolicyTests {
    @Test
    func `only accelerated mode uses the longer dashboard scan burst`() {
        #expect(CodexCostCatchUpMode.automatic.scanDurationPerRefresh == 2)
        #expect(CodexCostCatchUpMode.accelerated.scanDurationPerRefresh == 10)
    }

    @Test
    func `automatic mode targets one half percent duty cycle on AC power`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .ac,
            lowPowerModeEnabled: false,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(398), targetDutyCycle: 0.005))
    }

    @Test
    func `automatic mode targets one quarter percent duty cycle for unknown power`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .unknown,
            lowPowerModeEnabled: false,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(798), targetDutyCycle: 0.0025))
    }

    @Test
    func `automatic mode targets one tenth percent duty cycle on battery`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: false,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(1998), targetDutyCycle: 0.001))
    }

    @Test
    func `automatic mode throttles instead of pausing for low power mode on battery`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: true,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(19998), targetDutyCycle: 0.0001))
    }

    @Test
    func `automatic mode throttles instead of pausing for low power mode on AC power`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .ac,
            lowPowerModeEnabled: true,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(3998), targetDutyCycle: 0.0005))
    }

    @Test
    func `automatic mode throttles instead of pausing for low power mode for unknown power`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .unknown,
            lowPowerModeEnabled: true,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(7998), targetDutyCycle: 0.00025))
    }

    @Test
    func `automatic mode pauses for serious thermal pressure even when low power mode is enabled`() {
        for powerSource in [CodexCostCatchUpPowerSource.ac, .battery, .unknown] {
            let decision = CodexCostCatchUpPolicy().decision(for: .init(
                mode: .automatic,
                previousActiveDuration: 2,
                powerSource: powerSource,
                lowPowerModeEnabled: true,
                thermalState: .serious))

            #expect(decision == .init(
                action: .pause(CodexCostCatchUpPolicy.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil))
        }
    }

    @Test
    func `automatic mode pauses for critical thermal pressure even when low power mode is enabled`() {
        for powerSource in [CodexCostCatchUpPowerSource.ac, .battery, .unknown] {
            let decision = CodexCostCatchUpPolicy().decision(for: .init(
                mode: .automatic,
                previousActiveDuration: 2,
                powerSource: powerSource,
                lowPowerModeEnabled: true,
                thermalState: .critical))

            #expect(decision == .init(
                action: .pause(CodexCostCatchUpPolicy.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil))
        }
    }

    @Test
    func `accelerated mode ignores low power but not critical thermal pressure`() {
        let lowPowerDecision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .accelerated,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: true,
            thermalState: .serious))
        let criticalDecision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .accelerated,
            previousActiveDuration: 2,
            powerSource: .ac,
            lowPowerModeEnabled: false,
            thermalState: .critical))

        #expect(lowPowerDecision == .init(action: .runAfter(0), targetDutyCycle: 1))
        #expect(criticalDecision == .init(
            action: .pause(CodexCostCatchUpPolicy.constrainedRetryDelay, .thermal),
            targetDutyCycle: nil))
    }
}
