import Foundation

/// What the daemon knows about the battery right now.
public struct Conditions: Equatable, Sendable {
    public var percent: Int
    public var temperatureC: Double?
    public var externalConnected: Bool

    public init(percent: Int, temperatureC: Double?, externalConnected: Bool) {
        self.percent = percent
        self.temperatureC = temperatureC
        self.externalConnected = externalConnected
    }
}

/// Memory the policy needs between ticks.
public struct PolicyState: Equatable, Sendable {
    /// While heat protection holds charging, the percent it froze at; nil when not holding.
    public var heatHold: Int?
    public init(heatHold: Int? = nil) { self.heatHold = heatHold }
}

/// Turns the config plus the battery's condition into the SMC state to hold.
///
///  - the config's limit is the base;
///  - top up (one time) lifts the limit until the battery is full;
///  - heat protection wins over both: while the battery is hot it freezes the stop level at the percent
///    where it got hot, and lets go 3 °C below the threshold.
public enum Policy {
    public static let heatRelease = 3.0

    public struct Decision: Equatable, Sendable {
        public var target: SMCState
        public var state: PolicyState
        /// The top-up is finished: the daemon clears the flag in config.json.
        public var topUpDone: Bool
        public var heatHolding: Bool { state.heatHold != nil }
    }

    public static func decide(config: Config, conditions: Conditions?, previous: PolicyState) -> Decision {
        let config = config.validated()
        let topUpDone = config.topUp && (conditions?.percent ?? 0) >= 100
        let topUpActive = config.topUp && !topUpDone

        var base = (config.enabled && config.limit < 100)
            ? SMCState(mode: 2, stop: UInt8(config.limit), resume: UInt8(config.limit - config.gap))
            : SMCState.off
        if topUpActive { base = .off }

        // Heat protection.
        var state = PolicyState()
        if config.heatLimitC > 0, let conditions, let temperature = conditions.temperatureC {
            let hot = temperature >= Double(config.heatLimitC)
            let stillHot = previous.heatHold != nil && temperature > Double(config.heatLimitC) - heatRelease
            if hot || stillHot {
                // Freeze at the percent where it got hot (never below the 20% floor); keep it while it stays hot.
                state.heatHold = previous.heatHold ?? max(conditions.percent, Config.minLimit)
            }
        }
        guard let hold = state.heatHold else {
            return Decision(target: base, state: state, topUpDone: topUpDone)
        }
        let baseStop = base.mode == 0 ? 100 : Int(base.stop)
        let stop = min(baseStop, min(hold, 100))
        let gap = base.mode == 0 ? config.gap : Int(base.stop) - Int(base.resume)
        let target = SMCState(mode: 2, stop: UInt8(stop), resume: UInt8(max(stop - max(gap, 1), 1)))
        return Decision(target: target, state: state, topUpDone: topUpDone)
    }
}
