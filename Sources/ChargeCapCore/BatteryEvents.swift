import Foundation

/// Maximum capacity as a percent of the design capacity (what System Settings calls Battery Health).
public enum BatteryHealth {
    public static func percent(nominal: Int, design: Int) -> Int? {
        guard design > 0, nominal > 0 else { return nil }
        return min(Int((Double(nominal) / Double(design) * 100).rounded()), 100)
    }
}

/// What the menu bar side remembers about the battery between two looks, to tell when something happened.
public struct BatterySnapshot: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var notChargingReason: Int64
    public var temperatureC: Double?

    public init(percent: Int, isCharging: Bool, externalConnected: Bool, notChargingReason: Int64, temperatureC: Double?) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.notChargingReason = notChargingReason
        self.temperatureC = temperatureC
    }
}

public enum BatteryEvent: Equatable, Sendable {
    /// Charging just stopped at the limit.
    case limitReached(percent: Int, limit: Int)
    /// The battery just got as hot as the heat protection threshold.
    case heatHold(temperatureC: Double, limitC: Int)
}

public enum BatteryEvents {
    /// Events between two snapshots. The first look (no `previous`) never reports anything, so opening the
    /// menu on a battery that already sits at the limit is not "news".
    public static func detect(previous: BatterySnapshot?, current: BatterySnapshot, config: Config) -> [BatteryEvent] {
        guard let previous else { return [] }
        let config = config.validated()
        var events: [BatteryEvent] = []

        // Charging stopped, charger still connected, the firmware is holding it, and we are at the limit.
        if config.enabled, config.limit < 100, !config.topUp,
           previous.isCharging, !current.isCharging, current.externalConnected,
           current.notChargingReason != 0, current.percent >= config.limit - 1 {
            events.append(.limitReached(percent: current.percent, limit: config.limit))
        }

        if config.heatLimitC > 0, current.externalConnected,
           let now = current.temperatureC, now >= Double(config.heatLimitC),
           (previous.temperatureC ?? 0) < Double(config.heatLimitC) {
            events.append(.heatHold(temperatureC: now, limitC: config.heatLimitC))
        }
        return events
    }
}
