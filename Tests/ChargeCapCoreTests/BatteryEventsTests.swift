import Testing
@testable import ChargeCapCore

struct BatteryEventsTests {
    private func snap(_ percent: Int, charging: Bool = false, plugged: Bool = true, reason: Int64 = 0, temp: Double? = 30) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: charging, externalConnected: plugged, notChargingReason: reason, temperatureC: temp)
    }
    private let config = Config(enabled: true, limit: 80, gap: 5)

    @Test func healthIsNominalOverDesign() {
        #expect(BatteryHealth.percent(nominal: 7472, design: 8694) == 86)
        #expect(BatteryHealth.percent(nominal: 9000, design: 8694) == 100)
        #expect(BatteryHealth.percent(nominal: 0, design: 8694) == nil)
        #expect(BatteryHealth.percent(nominal: 7000, design: 0) == nil)
    }

    @Test func firstLookReportsNothing() {
        #expect(BatteryEvents.detect(previous: nil, current: snap(80, reason: 1), config: config).isEmpty)
    }

    @Test func chargingStoppingAtTheLimitIsReported() {
        let events = BatteryEvents.detect(previous: snap(79, charging: true), current: snap(80, reason: 36028797018963968), config: config)
        #expect(events == [.limitReached(percent: 80, limit: 80)])
    }

    @Test func stoppingFarBelowTheLimitIsNotTheLimit() {
        // Something else paused charging at 60%: not our limit.
        #expect(BatteryEvents.detect(previous: snap(60, charging: true), current: snap(60, reason: 8), config: config).isEmpty)
    }

    @Test func unpluggingIsNotTheLimit() {
        #expect(BatteryEvents.detect(previous: snap(80, charging: true), current: snap(80, plugged: false), config: config).isEmpty)
    }

    @Test func noEventWhenAlreadyHolding() {
        #expect(BatteryEvents.detect(previous: snap(80, reason: 1), current: snap(80, reason: 1), config: config).isEmpty)
    }

    @Test func noLimitEventWithTheLimitOffOrDuringTopUp() {
        let before = snap(99, charging: true), after = snap(100, reason: 1)
        #expect(BatteryEvents.detect(previous: before, current: after, config: Config(enabled: false)).isEmpty)
        #expect(BatteryEvents.detect(previous: before, current: after, config: Config(enabled: true, limit: 100)).isEmpty)
        #expect(BatteryEvents.detect(previous: snap(80, charging: true), current: snap(80, reason: 1),
                                     config: Config(enabled: true, limit: 80, topUp: true)).isEmpty)
    }

    @Test func heatThresholdCrossedIsReportedOnce() {
        let hot = Config(enabled: true, limit: 80, heatLimitC: 35)
        #expect(BatteryEvents.detect(previous: snap(60, temp: 34.5), current: snap(60, temp: 35.2), config: hot)
                == [.heatHold(temperatureC: 35.2, limitC: 35)])
        #expect(BatteryEvents.detect(previous: snap(60, temp: 36), current: snap(60, temp: 37), config: hot).isEmpty)
    }

    @Test func heatEventNeedsTheChargerAndTheSetting() {
        let hot = Config(enabled: true, limit: 80, heatLimitC: 35)
        #expect(BatteryEvents.detect(previous: snap(60, plugged: false, temp: 30), current: snap(60, plugged: false, temp: 40), config: hot).isEmpty)
        #expect(BatteryEvents.detect(previous: snap(60, temp: 30), current: snap(60, temp: 40), config: config).isEmpty)
    }
}
