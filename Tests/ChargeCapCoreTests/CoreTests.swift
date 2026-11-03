import Foundation
import Testing
@testable import ChargeCapCore

/// A fake SMC that behaves like the Mac firmware did in Phase 0: a write that leaves stop < resume is
/// answered with error 0x89 and switches the mode key off.
final class FakeSMC: SMCAccess {
    struct Failure: Error, CustomStringConvertible { var description: String }

    var state: SMCState
    var writes: [Write] = []
    var rejections = 0
    var failNextWrite = false

    init(_ state: SMCState) { self.state = state }

    func readState() throws -> SMCState { state }

    func write(_ write: Write) throws {
        if failNextWrite {
            failNextWrite = false
            throw Failure(description: "disk on fire")
        }
        writes.append(write)
        var next = state
        switch write.key {
        case .mode: next.mode = write.value
        case .stop: next.stop = write.value
        case .resume: next.resume = write.value
        }
        state = next
        if next.stop < next.resume {
            state.mode = 0
            rejections += 1
            throw Failure(description: "SMC error 0x89")
        }
    }
}

struct ConfigTests {
    @Test func disabledByDefault() {
        #expect(Config().target == .off)
        #expect(Config(enabled: false, limit: 70).target == .off)
    }

    @Test func enabledLimitMakesModeOnWithGap() {
        #expect(Config(enabled: true, limit: 80, gap: 5).target == SMCState(mode: 2, stop: 80, resume: 75))
    }

    @Test func limit100MeansNoLimit() {
        #expect(Config(enabled: true, limit: 100).target == .off)
    }

    @Test func outOfRangeValuesAreClamped() {
        let low = Config(enabled: true, limit: 3, gap: 99).validated()
        #expect(low.limit == 20 && low.gap == 15)
        #expect(Config(enabled: true, limit: 500, gap: 0).validated().limit == 100)
        #expect(Config(enabled: true, limit: 500, gap: 0).validated().gap == 1)
        // Even the lowest limit keeps a valid resume value.
        #expect(Config(enabled: true, limit: 20, gap: 15).target == SMCState(mode: 2, stop: 20, resume: 5))
    }

    @Test func missingKeysUseDefaultsAndGarbageMeansOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ConfigStore.load(from: dir) == Config())

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"enabled": true}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(ConfigStore.load(from: dir) == Config(enabled: true, limit: 80, gap: 5))

        try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(ConfigStore.load(from: dir).enabled == false)
    }

    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = Config(enabled: true, limit: 85, gap: 7)
        try ConfigStore.save(config, to: dir)
        #expect(ConfigStore.load(from: dir) == config)
    }
}

struct WritePlannerTests {
    @Test func switchingOnWritesValuesThenMode() {
        let steps = WritePlanner.steps(from: SMCState(mode: 0, stop: 100, resume: 99), to: SMCState(mode: 2, stop: 80, resume: 75))
        #expect(steps == [Write(.resume, 75), Write(.stop, 80), Write(.mode, 2)])
    }

    @Test func switchingOffOnlyWritesTheMode() {
        let steps = WritePlanner.steps(from: SMCState(mode: 2, stop: 80, resume: 75), to: .off)
        #expect(steps == [Write(.mode, 0)])
    }

    @Test func staleValuesWithTheModeOffAreLeftAlone() {
        // After AlDente or a test the values can be 80/79 with the mode off: that is already "off".
        #expect(WritePlanner.steps(from: SMCState(mode: 0, stop: 80, resume: 79), to: .off).isEmpty)
    }

    @Test func raisingTheLimitWritesStopFirst() {
        let steps = WritePlanner.steps(from: SMCState(mode: 2, stop: 70, resume: 65), to: SMCState(mode: 2, stop: 90, resume: 85))
        #expect(steps == [Write(.stop, 90), Write(.resume, 85)])
    }

    @Test func loweringTheLimitWritesResumeFirst() {
        let steps = WritePlanner.steps(from: SMCState(mode: 2, stop: 90, resume: 85), to: SMCState(mode: 2, stop: 70, resume: 65))
        #expect(steps == [Write(.resume, 65), Write(.stop, 70)])
    }

    @Test func nothingToDoWhenEqual() {
        let state = SMCState(mode: 2, stop: 80, resume: 75)
        #expect(WritePlanner.steps(from: state, to: state).isEmpty)
    }

    @Test func onlyTheDifferenceIsWritten() {
        // The firmware cleared the mode (e.g. after sleep); values are still right.
        let steps = WritePlanner.steps(from: SMCState(mode: 0, stop: 80, resume: 75), to: SMCState(mode: 2, stop: 80, resume: 75))
        #expect(steps == [Write(.mode, 2)])
    }

    /// Every transition between valid limits, through the fake firmware: never a rejection.
    @Test func noTransitionEverTriggersTheFirmwareRejection() {
        var states: [SMCState] = [.off, SMCState(mode: 0, stop: 80, resume: 79)]
        for limit in stride(from: 20, to: 100, by: 7) {
            for gap in [1, 5, 15] where limit - gap >= 1 {
                states.append(SMCState(mode: 2, stop: UInt8(limit), resume: UInt8(limit - gap)))
            }
        }
        for from in states {
            for to in states {
                let smc = FakeSMC(from)
                let outcome = Engine(smc: smc).apply(to)
                #expect(smc.rejections == 0, "\(from) -> \(to)")
                #expect(smc.state.satisfies(to), "\(from) -> \(to): got \(smc.state), \(outcome)")
            }
        }
    }
}

struct EngineTests {
    @Test func appliesAndReportsTheWrites() {
        let smc = FakeSMC(SMCState(mode: 0, stop: 80, resume: 79))
        let outcome = Engine(smc: smc).apply(SMCState(mode: 2, stop: 80, resume: 75))
        #expect(outcome == .applied([Write(.resume, 75), Write(.mode, 2)]))
        #expect(smc.state == SMCState(mode: 2, stop: 80, resume: 75))
    }

    @Test func writesNothingWhenAlreadyRight() {
        let smc = FakeSMC(SMCState(mode: 2, stop: 80, resume: 75))
        #expect(Engine(smc: smc).apply(SMCState(mode: 2, stop: 80, resume: 75)) == .unchanged)
        #expect(smc.writes.isEmpty)
    }

    @Test func restoresTheModeTheFirmwareClearedAfterWake() {
        let smc = FakeSMC(SMCState(mode: 0, stop: 80, resume: 75))
        let outcome = Engine(smc: smc).apply(SMCState(mode: 2, stop: 80, resume: 75))
        #expect(outcome == .applied([Write(.mode, 2)]))
    }

    @Test func aFailedWriteIsReportedNotFatalAndRetriedNextTime() {
        let smc = FakeSMC(.off)
        smc.failNextWrite = true
        let engine = Engine(smc: smc)
        if case .failed = engine.apply(SMCState(mode: 2, stop: 80, resume: 75)) {} else { Issue.record("expected failure") }
        // The next call (next minute) finishes the job.
        #expect(engine.apply(SMCState(mode: 2, stop: 80, resume: 75)) != .unchanged)
        #expect(smc.state == SMCState(mode: 2, stop: 80, resume: 75))
    }

    @Test func switchingOffRestoresNormalCharging() {
        let smc = FakeSMC(SMCState(mode: 2, stop: 80, resume: 75))
        _ = Engine(smc: smc).apply(Config(enabled: false).target)
        #expect(smc.state.mode == 0)
        #expect(smc.writes == [Write(.mode, 0)])
    }
}
