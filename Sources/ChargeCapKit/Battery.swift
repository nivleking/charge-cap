import ChargeCapCore
import Foundation
import IOKit

public struct BatteryInfo: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    /// `NotChargingReason` from AppleSmartBattery's ChargerData; non-zero while the firmware holds charging back.
    public var notChargingReason: Int64
    /// Highest and lowest charge the gauge saw today (BatteryData), and lifetime cycles.
    public var dailyMaxSoc: Int?
    public var dailyMinSoc: Int?
    public var cycleCount: Int?
    /// Battery temperature in °C (the gauge reports hundredths of a degree).
    public var temperatureC: Double?
}

extension BatteryInfo {
    public var conditions: Conditions {
        Conditions(percent: percent, temperatureC: temperatureC, externalConnected: externalConnected)
    }
}

public enum Battery {
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let charger = dict["ChargerData"] as? [String: Any]
        let data = dict["BatteryData"] as? [String: Any]
        return BatteryInfo(
            percent: (dict["CurrentCapacity"] as? NSNumber)?.intValue ?? 0,
            isCharging: (dict["IsCharging"] as? NSNumber)?.boolValue ?? false,
            externalConnected: (dict["ExternalConnected"] as? NSNumber)?.boolValue ?? false,
            notChargingReason: (charger?["NotChargingReason"] as? NSNumber)?.int64Value ?? 0,
            dailyMaxSoc: (data?["DailyMaxSoc"] as? NSNumber)?.intValue,
            dailyMinSoc: (data?["DailyMinSoc"] as? NSNumber)?.intValue,
            cycleCount: (dict["CycleCount"] as? NSNumber)?.intValue,
            temperatureC: (dict["Temperature"] as? NSNumber).map { $0.doubleValue / 100 })
    }
}
