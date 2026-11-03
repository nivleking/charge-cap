import Foundation

/// Phase 3 helpers: did the battery stay under the limit while nobody was watching?
public enum Soak {
    public enum Verdict: Equatable, Sendable {
        case withinLimit
        case exceeded(by: Int)
        case notApplicable
    }

    /// The gauge's highest charge of the day against the limit; one percent of slack for gauge rounding.
    public static func verdict(dailyMax: Int?, limit: Int, enabled: Bool) -> Verdict {
        guard enabled, limit < 100, let dailyMax else { return .notApplicable }
        return dailyMax <= limit + 1 ? .withinLimit : .exceeded(by: dailyMax - limit)
    }

    /// Counts what the daemon log says: real writes, failures and wakes, for lines newer than `since`.
    public struct LogSummary: Equatable, Sendable {
        public var applied = 0
        public var failed = 0
        public var wakes = 0
        public var starts = 0
    }

    public static func summarize(log: String, since: Date) -> LogSummary {
        var summary = LogSummary()
        let formatter = ISO8601DateFormatter()
        for line in log.split(separator: "\n") {
            guard let space = line.firstIndex(of: " "),
                  let when = formatter.date(from: String(line[..<space])), when >= since else { continue }
            let rest = line[line.index(after: space)...]
            if rest.contains("FAILED") { summary.failed += 1 }
            if rest.contains("] applied [") { summary.applied += 1 }
            if rest.hasPrefix("[wake]") { summary.wakes += 1 }
            if rest.hasPrefix("chargecapd started") { summary.starts += 1 }
        }
        return summary
    }
}
