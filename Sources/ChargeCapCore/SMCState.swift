import Foundation

/// The three SMC keys that make up the firmware charge limit (found in Phase 0):
/// - mode   `bfF0` (ui8): 02 = limit on, 00 = off
/// - stop   `bfD0` (ui32, little-endian): stop charging at this %
/// - resume `bfE0` (ui32, little-endian): start charging again at this %
public enum ChargeKey: String, Sendable, CaseIterable {
    case mode = "bfF0"
    case stop = "bfD0"
    case resume = "bfE0"
}

/// What the three keys hold right now (or should hold): percents as plain numbers.
public struct SMCState: Equatable, Sendable, CustomStringConvertible {
    public var mode: UInt8
    public var stop: UInt8
    public var resume: UInt8

    public init(mode: UInt8, stop: UInt8, resume: UInt8) {
        self.mode = mode
        self.stop = stop
        self.resume = resume
    }

    /// Limit switched off: nothing stops charging. 100/99 is what the Phase 0 baseline wrote.
    public static let off = SMCState(mode: 0, stop: 100, resume: 99)

    /// Whether these keys already do what `target` asks. With the limit off only the mode matters:
    /// the firmware ignores stop and resume while the mode is 00.
    public func satisfies(_ target: SMCState) -> Bool {
        target.mode == 0 ? mode == 0 : self == target
    }

    public var description: String { "bfF0=\(String(format: "%02x", mode)) bfD0=\(stop)% bfE0=\(resume)%" }
}

/// One write the engine wants to make.
public struct Write: Equatable, Sendable, CustomStringConvertible {
    public var key: ChargeKey
    public var value: UInt8
    public init(_ key: ChargeKey, _ value: UInt8) {
        self.key = key
        self.value = value
    }

    public var description: String { "\(key.rawValue)=\(value)" }
}

/// Reads and writes the three keys. Real implementation: `SMCClient` in ChargeCapKit.
/// By construction nothing else in the SMC can be reached through this protocol.
public protocol SMCAccess {
    func readState() throws -> SMCState
    func write(_ write: Write) throws
}
