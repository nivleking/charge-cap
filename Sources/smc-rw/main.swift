// smc-rw: read SMC keys, and write only the charging keys ChargeCap needs.
//
//   smc-rw read KEY [KEY ...]      print "KEY TYPE SIZE HEX" per key (no root needed)
//   smc-rw write KEY HEX           write bytes, read back, print JSON (root only)
//
// Writes are limited to an allow-list so a typo can never touch an unrelated key.

import CSMC
import Foundation

/// Keys we are allowed to write, with the byte size we expect them to have.
let writableKeys: [String: UInt32] = [
    "bfD0": 4,  // firmware charge limit: stop charging at this %, ui32 little-endian (64000000 = 100%)
    "bfE0": 4,  // firmware charge limit: resume charging at this %, ui32 little-endian (63000000 = 99%)
    "CHTE": 4,  // charge inhibit on newer firmware (absent on MacBookPro18,1 + macOS 15.8.1)
    "CHIE": 1,  // adapter inhibit (Apple Silicon): 00 = use adapter, 08 = run on battery
]

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("smc-rw: \(message)\n".utf8))
    exit(code)
}

func checkKey(_ key: String) {
    guard key.count == 4, key.allSatisfy({ $0.isASCII }) else {
        fail("key must be exactly 4 ASCII characters: \(key)")
    }
}

func typeString(_ code: UInt32) -> String {
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> UInt32($0)) & 0xff))) }
    return String(chars).trimmingCharacters(in: .whitespaces)
}

func hexString(_ value: smc_value_t) -> String {
    withUnsafeBytes(of: value.bytes) { raw in
        raw.prefix(Int(value.data_size)).map { String(format: "%02x", $0) }.joined()
    }
}

func parseHex(_ text: String) -> [UInt8]? {
    let clean = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
    guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
    var bytes: [UInt8] = []
    var index = clean.startIndex
    while index < clean.endIndex {
        let next = clean.index(index, offsetBy: 2)
        guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

func describe(_ rc: Int32, _ detail: Int32) -> String {
    switch rc {
    case Int32(SMC_ERR_OPEN): return "could not open AppleSMC"
    case Int32(SMC_ERR_CALL): return "IOKit call failed (kern_return 0x\(String(detail, radix: 16)))"
    case Int32(SMC_ERR_KEY): return detail == 0x84 ? "key not found" : "SMC error 0x\(String(detail, radix: 16))"
    case Int32(SMC_ERR_SIZE): return "size mismatch (key is \(detail) bytes)"
    default: return "error \(rc)"
    }
}

func read(_ conn: io_connect_t, _ key: String) -> smc_value_t {
    var value = smc_value_t()
    var detail: Int32 = 0
    let rc = key.withCString { smc_read_key(conn, $0, &value, &detail) }
    if rc != SMC_OK { fail("read \(key): \(describe(rc, detail))") }
    return value
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: smc-rw read KEY [KEY ...] | smc-rw write KEY HEX", code: 2)
}

var conn: io_connect_t = 0
if smc_open(&conn) != SMC_OK { fail("could not open AppleSMC") }
defer { smc_close(conn) }

switch command {
case "read":
    let keys = args.dropFirst()
    if keys.isEmpty { fail("read needs at least one key", code: 2) }
    for key in keys {
        checkKey(key)
        let value = read(conn, key)
        print("\(key) \(typeString(value.data_type)) \(value.data_size) \(hexString(value))")
    }

case "list":
    // Optional prefix filter, e.g. "smc-rw list CH" lists every charging-related key.
    let prefix = args.count > 1 ? args[1] : ""
    let countValue = read(conn, "#KEY")
    let count = withUnsafeBytes(of: countValue.bytes) { raw in
        raw.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    for index in 0..<count {
        var name: [CChar] = [0, 0, 0, 0]
        var detail: Int32 = 0
        if smc_key_at_index(conn, index, &name, &detail) != SMC_OK { continue }
        let key = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard key.hasPrefix(prefix) else { continue }
        var value = smc_value_t()
        let rc = key.withCString { smc_read_key(conn, $0, &value, &detail) }
        if rc == SMC_OK {
            print("\(key) \(typeString(value.data_type)) \(value.data_size) \(hexString(value))")
        } else {
            print("\(key) ? ? (\(describe(rc, detail)))")
        }
    }

case "write":
    guard args.count == 3 else { fail("usage: smc-rw write KEY HEX", code: 2) }
    let key = args[1]
    checkKey(key)
    guard let expectedSize = writableKeys[key] else {
        fail("refusing to write \(key); allowed keys: \(writableKeys.keys.sorted().joined(separator: ", "))")
    }
    guard let bytes = parseHex(args[2]), bytes.count == Int(expectedSize) else {
        fail("\(key) needs exactly \(expectedSize) byte(s) of hex, e.g. \(String(repeating: "00", count: Int(expectedSize)))")
    }
    guard getuid() == 0 else { fail("write needs root (run with sudo)") }

    let before = hexString(read(conn, key))
    var detail: Int32 = 0
    let rc = key.withCString { smc_write_key(conn, $0, bytes, expectedSize, &detail) }
    if rc != SMC_OK { fail("write \(key): \(describe(rc, detail))") }
    let after = hexString(read(conn, key))
    let wanted = bytes.map { String(format: "%02x", $0) }.joined()
    let ok = after == wanted
    print("{\"key\":\"\(key)\",\"before\":\"\(before)\",\"wanted\":\"\(wanted)\",\"after\":\"\(after)\",\"ok\":\(ok)}")
    exit(ok ? 0 : 3)

default:
    fail("unknown command \(command)", code: 2)
}
