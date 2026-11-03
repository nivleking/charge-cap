import Foundation

/// Reads the keys, compares with what the config wants, and writes only the difference.
/// Called at start, after wake, on power changes and every minute; calling it when nothing is wrong
/// writes nothing.
public final class Engine {
    public enum Outcome: Equatable, Sendable {
        case unchanged
        case applied([Write])
        case failed(String)
    }

    private let smc: SMCAccess

    public init(smc: SMCAccess) {
        self.smc = smc
    }

    public func apply(_ target: SMCState) -> Outcome {
        var done: [Write] = []
        // A second pass lets us notice a key the firmware changed under us while we were writing.
        for _ in 0..<2 {
            let current: SMCState
            do { current = try smc.readState() } catch { return .failed("read failed: \(error)") }
            let steps = WritePlanner.steps(from: current, to: target)
            if steps.isEmpty { return done.isEmpty ? .unchanged : .applied(done) }
            for step in steps {
                do { try smc.write(step) } catch {
                    return .failed("write \(step) failed: \(error) (after \(done.map(\.description).joined(separator: ", ")))")
                }
                done.append(step)
            }
        }
        return .failed("state still differs from \(target) after writing: \(done.map(\.description).joined(separator: ", "))")
    }
}
