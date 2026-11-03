import Foundation
import Testing
@testable import ChargeCapCore

struct SoakTests {
    @Test func withinLimitAllowsOnePercentOfRounding() {
        #expect(Soak.verdict(dailyMax: 81, limit: 80, enabled: true) == .withinLimit)
        #expect(Soak.verdict(dailyMax: 80, limit: 80, enabled: true) == .withinLimit)
    }

    @Test func exceededReportsByHowMuch() {
        #expect(Soak.verdict(dailyMax: 98, limit: 80, enabled: true) == .exceeded(by: 18))
    }

    @Test func noLimitMeansNothingToJudge() {
        #expect(Soak.verdict(dailyMax: 100, limit: 80, enabled: false) == .notApplicable)
        #expect(Soak.verdict(dailyMax: 100, limit: 100, enabled: true) == .notApplicable)
        #expect(Soak.verdict(dailyMax: nil, limit: 80, enabled: true) == .notApplicable)
    }

    @Test func logSummaryCountsRecentEventsOnly() {
        let log = """
        2026-11-03T01:00:00Z chargecapd started, config dir /x
        2026-11-03T01:00:01Z [start] applied [bfE0=75 bfF0=2] -> bfF0=02 bfD0=80% bfE0=75% | battery 80%
        2026-11-03T03:00:00Z [wake] applied [bfF0=2] -> bfF0=02 bfD0=80% bfE0=75% | battery 80%
        2026-11-03T03:10:00Z [timer] FAILED write bfF0=2 failed
        2026-11-03T03:11:00Z [wake] ok bfF0=02 bfD0=80% bfE0=75% | battery 79%
        """
        let since = ISO8601DateFormatter().date(from: "2026-11-03T02:00:00Z")!
        #expect(Soak.summarize(log: log, since: since) == Soak.LogSummary(applied: 1, failed: 1, wakes: 2, starts: 0))
    }
}
