import Foundation

/// What the user wants. Lives in `config.json` next to the daemon (root-owned).
public struct Config: Codable, Equatable, Sendable {
    public static let minLimit = 20
    public static let gapRange = 1...15

    /// Off by default: installing the daemon changes nothing until `chargecap limit 80`.
    public var enabled: Bool = false
    /// Stop charging at this %.
    public var limit: Int = 80
    /// Start charging again at `limit - gap` (hysteresis, so it does not flip back and forth).
    public var gap: Int = 5

    public init(enabled: Bool = false, limit: Int = 80, gap: Int = 5) {
        self.enabled = enabled
        self.limit = limit
        self.gap = gap
    }

    // Missing keys fall back to the defaults, so an older or hand-edited file keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        gap = try c.decodeIfPresent(Int.self, forKey: .gap) ?? d.gap
    }

    /// Brings hand-edited values into a safe range: never below 20% (the Mac would not charge), never above 100.
    public func validated() -> Config {
        var v = self
        v.limit = min(max(limit, Self.minLimit), 100)
        v.gap = min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        return v
    }

    /// The key values to hold. A limit of 100 means "no limit".
    public var target: SMCState {
        let v = validated()
        guard v.enabled, v.limit < 100 else { return .off }
        return SMCState(mode: 2, stop: UInt8(v.limit), resume: UInt8(v.limit - v.gap))
    }
}

public enum ConfigStore {
    public static let defaultDirectory = "/Library/Application Support/ChargeCap"

    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["CHARGECAP_DIR"] ?? defaultDirectory, isDirectory: true)
    }

    /// A missing or unreadable file means "off": the safe state.
    public static func load(from directory: URL) -> Config {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config.validated()
    }

    public static func save(_ config: Config, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(config.validated()).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
    }
}
