import Foundation
import Testing
@testable import ChargeCapCore

struct PolicyTests {
    private func conditions(_ percent: Int, _ temp: Double?, plugged: Bool = true) -> Conditions {
        Conditions(percent: percent, temperatureC: temp, externalConnected: plugged)
    }

    @Test func withoutExtrasItIsTheConfigTarget() {
        let config = Config(enabled: true, limit: 80, gap: 5)
        let decision = Policy.decide(config: config, conditions: conditions(70, 30), previous: PolicyState())
        #expect(decision.target == config.target)
        #expect(!decision.topUpDone && !decision.heatHolding)
    }

    @Test func unreadableBatteryFallsBackToTheConfig() {
        let config = Config(enabled: true, limit: 80, gap: 5, heatLimitC: 35)
        #expect(Policy.decide(config: config, conditions: nil, previous: PolicyState()).target == config.target)
    }

    // MARK: heat protection

    @Test func heatFreezesTheStopLevelAtThePercentWhereItGotHot() {
        let config = Config(enabled: true, limit: 80, gap: 5, heatLimitC: 35)
        let decision = Policy.decide(config: config, conditions: conditions(62, 36), previous: PolicyState())
        #expect(decision.target == SMCState(mode: 2, stop: 62, resume: 57))
        #expect(decision.state.heatHold == 62)
    }

    @Test func theFrozenLevelStaysWhileItStaysHot() {
        let config = Config(enabled: true, limit: 80, gap: 5, heatLimitC: 35)
        var state = PolicyState(heatHold: 62)
        // Battery fell to 60% and is still at 34 °C (within the 3 °C release band): still frozen at 62.
        let decision = Policy.decide(config: config, conditions: conditions(60, 34), previous: state)
        #expect(decision.state.heatHold == 62)
        state = decision.state
        #expect(Policy.decide(config: config, conditions: conditions(60, 31.9), previous: state).heatHolding == false)
    }

    @Test func heatBelowTheThresholdDoesNothing() {
        let config = Config(enabled: true, limit: 80, gap: 5, heatLimitC: 35)
        #expect(Policy.decide(config: config, conditions: conditions(62, 34.9), previous: PolicyState()).heatHolding == false)
    }

    @Test func heatProtectionOffByDefault() {
        let config = Config(enabled: true, limit: 80, gap: 5)
        #expect(Policy.decide(config: config, conditions: conditions(62, 45), previous: PolicyState()).heatHolding == false)
    }

    @Test func heatNeverRaisesTheLimit() {
        // Already above the config limit: the lower limit stays.
        let config = Config(enabled: true, limit: 60, gap: 5, heatLimitC: 35)
        let decision = Policy.decide(config: config, conditions: conditions(75, 40), previous: PolicyState())
        #expect(decision.target.stop == 60)
    }

    @Test func heatWorksEvenWithNoLimit() {
        let config = Config(enabled: false, heatLimitC: 35)
        let decision = Policy.decide(config: config, conditions: conditions(70, 38), previous: PolicyState())
        #expect(decision.target == SMCState(mode: 2, stop: 70, resume: 65))
    }

    @Test func frozenLevelHasAFloor() {
        let config = Config(enabled: false, heatLimitC: 35)
        #expect(Policy.decide(config: config, conditions: conditions(8, 40), previous: PolicyState()).target.stop == 20)
    }

    // MARK: top up

    @Test func topUpLiftsTheLimit() {
        let config = Config(enabled: true, limit: 80, gap: 5, topUp: true)
        let decision = Policy.decide(config: config, conditions: conditions(85, 30), previous: PolicyState())
        #expect(decision.target == .off)
        #expect(!decision.topUpDone)
    }

    @Test func topUpIsDoneAtFullAndTheLimitComesBack() {
        let config = Config(enabled: true, limit: 80, gap: 5, topUp: true)
        let decision = Policy.decide(config: config, conditions: conditions(100, 30), previous: PolicyState())
        #expect(decision.topUpDone)
        #expect(decision.target == SMCState(mode: 2, stop: 80, resume: 75))
    }

    @Test func heatBeatsTopUp() {
        let config = Config(enabled: true, limit: 80, gap: 5, heatLimitC: 35, topUp: true)
        let decision = Policy.decide(config: config, conditions: conditions(90, 40), previous: PolicyState())
        #expect(decision.target == SMCState(mode: 2, stop: 90, resume: 85))
    }

    @Test func configValuesAreClamped() {
        #expect(Config(heatLimitC: 5).validated().heatLimitC == 30)
        #expect(Config(heatLimitC: 99).validated().heatLimitC == 50)
        #expect(Config(heatLimitC: -4).validated().heatLimitC == 0)
        let old = try? JSONDecoder().decode(Config.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(old?.heatLimitC == 0 && old?.topUp == false)
    }
}
