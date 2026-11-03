import ChargeCapCore
import CSMC
import Foundation

/// The real `SMCAccess`: talks to AppleSMC, and can only read or write the three charge-limit keys.
/// Writing needs root; reading does not.
public final class SMCClient: SMCAccess {
    public struct SMCError: Error, CustomStringConvertible {
        public var description: String
    }

    private var connection: io_connect_t = 0

    public init() throws {
        if smc_open(&connection) != SMC_OK { throw SMCError(description: "could not open AppleSMC") }
    }

    deinit { smc_close(connection) }

    public func readState() throws -> SMCState {
        SMCState(mode: try readFirstByte(.mode), stop: try readFirstByte(.stop), resume: try readFirstByte(.resume))
    }

    /// Mode is one byte; stop and resume are ui32 little-endian, so the percent is the first byte.
    private func readFirstByte(_ key: ChargeKey) throws -> UInt8 {
        var value = smc_value_t()
        var detail: Int32 = 0
        let rc = key.rawValue.withCString { smc_read_key(connection, $0, &value, &detail) }
        guard rc == SMC_OK else { throw SMCError(description: "read \(key.rawValue): \(Self.describe(rc, detail))") }
        return value.bytes.0
    }

    public func write(_ write: Write) throws {
        let bytes: [UInt8]
        switch write.key {
        case .mode:
            guard write.value == 0 || write.value == 2 else { throw SMCError(description: "refusing mode \(write.value)") }
            bytes = [write.value]
        case .stop, .resume:
            guard (1...100).contains(write.value) else { throw SMCError(description: "refusing \(write.key.rawValue)=\(write.value)") }
            bytes = [write.value, 0, 0, 0]
        }
        var detail: Int32 = 0
        let rc = write.key.rawValue.withCString { smc_write_key(connection, $0, bytes, UInt32(bytes.count), &detail) }
        guard rc == SMC_OK else { throw SMCError(description: "write \(write.key.rawValue): \(Self.describe(rc, detail))") }
    }

    private static func describe(_ rc: Int32, _ detail: Int32) -> String {
        switch rc {
        case Int32(SMC_ERR_OPEN): "could not open AppleSMC"
        case Int32(SMC_ERR_CALL): "IOKit call failed (0x\(String(detail, radix: 16)); root needed for writes)"
        case Int32(SMC_ERR_KEY): detail == 0x84 ? "key not found" : "SMC error 0x\(String(detail, radix: 16))"
        case Int32(SMC_ERR_SIZE): "size mismatch (key is \(detail) bytes)"
        default: "error \(rc)"
        }
    }
}
