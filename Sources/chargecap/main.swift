// chargecap: command line for the charge limit.
//
//   chargecap status            battery, the three limit keys, and what the config asks for (no root needed)
//   sudo chargecap limit 80     set the limit and apply it now
//   sudo chargecap off          switch the limit off and apply it now (the emergency button)
//   sudo chargecap apply        make the keys match config.json once (what the daemon does every minute)
//   chargecap logs [N]          last N lines of the daemon log (default 20)

import ChargeCapCore
import ChargeCapKit
import Foundation

let directory = ConfigStore.directory()
let log = FileLog()

let usage = """
    usage: chargecap status
           sudo chargecap limit <20-100>   (100 = no limit)
           sudo chargecap off
           sudo chargecap apply
           chargecap logs [lines]
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func needRoot() {
    if getuid() != 0 { fail("Perintah ini perlu sudo: sudo chargecap \(CommandLine.arguments.dropFirst().joined(separator: " "))") }
}

func describe(_ outcome: Engine.Outcome) -> String {
    switch outcome {
    case .unchanged: "Sudah sesuai, tidak ada yang ditulis."
    case .applied(let writes): "Ditulis: \(writes.map(\.description).joined(separator: ", "))"
    case .failed(let message): "GAGAL: \(message)"
    }
}

/// Writes the config, then applies it at once so the limit works even before the daemon is installed.
func saveAndApply(_ config: Config) {
    do { try ConfigStore.save(config, to: directory) } catch { fail("Tidak bisa menyimpan config di \(directory.path): \(error)") }
    do {
        let outcome = Engine(smc: try SMCClient()).apply(config.validated().target)
        print(describe(outcome))
        log.write("[cli] \(CommandLine.arguments.dropFirst().joined(separator: " ")) -> \(describe(outcome))")
        if case .failed = outcome { exit(1) }
    } catch {
        fail("Tidak bisa membuka SMC: \(error)")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage, code: 2) }
args.removeFirst()

switch command {
case "status":
    let config = ConfigStore.load(from: directory)
    if let b = Battery.read() {
        let charging = b.isCharging ? "mengisi" : (b.externalConnected ? "tidak mengisi (charger terpasang)" : "memakai baterai")
        print("Baterai: \(b.percent)%, \(charging)" + (b.notChargingReason != 0 ? " [firmware menahan pengisian]" : ""))
    } else {
        print("Baterai: tidak terbaca")
    }
    do {
        let state = try SMCClient().readState()
        print("Kunci SMC: \(state)" + (state.mode == 2 ? "  (batas firmware AKTIF)" : "  (batas firmware mati)"))
        let want = config.target
        print("Config: " + (config.enabled ? "batas \(config.limit)%, mulai lagi di \(config.limit - config.gap)%" : "batas mati")
              + (state.satisfies(want) ? "  ✓ kunci SMC sesuai" : "  ✗ kunci SMC BELUM sesuai (daemon atau 'sudo chargecap apply' akan membetulkan)"))
    } catch {
        print("Kunci SMC: tidak terbaca (\(error))")
    }

case "limit":
    needRoot()
    guard let value = args.first.flatMap(Int.init), (Config.minLimit...100).contains(value) else {
        fail("limit harus angka \(Config.minLimit)–100 (100 = tanpa batas)", code: 2)
    }
    var config = ConfigStore.load(from: directory)
    config.enabled = value < 100
    config.limit = value
    saveAndApply(config)

case "off", "reset":
    needRoot()
    var config = ConfigStore.load(from: directory)
    config.enabled = false
    saveAndApply(config)

case "apply":
    needRoot()
    saveAndApply(ConfigStore.load(from: directory))

case "logs":
    let n = args.first.flatMap(Int.init) ?? 20
    let text = log.tail(n)
    print(text.isEmpty ? "Belum ada log di \(log.path)" : text)

case "-h", "--help", "help":
    print(usage)

default:
    fail(usage, code: 2)
}
