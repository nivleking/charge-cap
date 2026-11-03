// chargecap: command line for the charge limit.
//
//   chargecap status            battery, the three limit keys, and what the config asks for (no root needed)
//   chargecap limit 80          set the limit (the daemon applies it at once; with sudo it applies it itself)
//   chargecap off               switch the limit off (emergency: use sudo, it works even if the daemon is dead)
//   chargecap gap 5             start charging again this many points below the limit (1-15)
//   chargecap heat 35           stop charging while the battery is 35 C or hotter (30-50; "heat off" to disable)
//   chargecap topup             charge to 100% once, then the limit comes back
//   sudo chargecap apply        make the keys match config.json once (what the daemon does every minute)
//   chargecap logs [N]          last N lines of the daemon log (default 20)
//   chargecap report            did the battery stay under the limit today? (for the multi-day soak test)

import ChargeCapCore
import ChargeCapKit
import Foundation

let directory = ConfigStore.directory()
let log = FileLog()

let usage = """
    usage: chargecap status
           chargecap limit <20-100>   (100 = no limit)
           chargecap off              (use sudo for the emergency switch-off)
           chargecap gap <1-15>
           chargecap heat <30-50|off>
           chargecap topup
           sudo chargecap apply
           chargecap logs [lines]
           chargecap report
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

/// Saves the config. As root it also applies it at once (so it works before the daemon is installed or
/// when it is dead); as a normal user the running daemon notices the new file and applies it within seconds.
func saveAndApply(_ config: Config) {
    do { try ConfigStore.save(config, to: directory) } catch {
        fail("Tidak bisa menyimpan config di \(directory.path): \(error)\nCoba dengan sudo, atau jalankan ulang scripts/install.sh (izin folder).")
    }
    guard getuid() == 0 else {
        print("Config disimpan. Daemon menerapkannya sebentar lagi (cek: chargecap status).")
        return
    }
    do {
        let decision = Policy.decide(config: config, conditions: Battery.read()?.conditions, previous: PolicyState())
        let outcome = Engine(smc: try SMCClient()).apply(decision.target)
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
        print("Baterai: \(b.percent)%, \(charging)" + (b.notChargingReason != 0 ? " [firmware menahan pengisian]" : "")
              + (b.temperatureC.map { String(format: ", %.1f°C", $0) } ?? ""))
    } else {
        print("Baterai: tidak terbaca")
    }
    do {
        let state = try SMCClient().readState()
        print("Kunci SMC: \(state)" + (state.mode == 2 ? "  (batas firmware AKTIF)" : "  (batas firmware mati)"))
        let decision = Policy.decide(config: config, conditions: Battery.read()?.conditions, previous: PolicyState())
        let want = decision.target
        print("Config: " + (config.enabled ? "batas \(config.limit)%, mulai lagi di \(config.limit - config.gap)%" : "batas mati")
              + (config.heatLimitC > 0 ? ", proteksi suhu \(config.heatLimitC)°C" : "")
              + (config.topUp ? ", top up berjalan" : "")
              + (decision.heatHolding ? " [SEDANG menahan karena panas]" : "")
              + (state.satisfies(want) ? "  ✓ kunci SMC sesuai" : "  ✗ kunci SMC BELUM sesuai (daemon atau 'sudo chargecap apply' akan membetulkan)"))
    } catch {
        print("Kunci SMC: tidak terbaca (\(error))")
    }

case "limit":
    guard let value = args.first.flatMap(Int.init), (Config.minLimit...100).contains(value) else {
        fail("limit harus angka \(Config.minLimit)–100 (100 = tanpa batas)", code: 2)
    }
    var config = ConfigStore.load(from: directory)
    config.enabled = value < 100
    config.limit = value
    saveAndApply(config)

case "off", "reset":
    var config = ConfigStore.load(from: directory)
    config.enabled = false
    saveAndApply(config)

case "gap":
    guard let value = args.first.flatMap(Int.init), Config.gapRange.contains(value) else {
        fail("gap harus angka \(Config.gapRange.lowerBound)–\(Config.gapRange.upperBound)", code: 2)
    }
    var config = ConfigStore.load(from: directory)
    config.gap = value
    saveAndApply(config)

case "heat":
    var config = ConfigStore.load(from: directory)
    if args.first == "off" {
        config.heatLimitC = 0
    } else if let value = args.first.flatMap(Int.init), Config.heatRange.contains(value) {
        config.heatLimitC = value
    } else {
        fail("heat harus angka \(Config.heatRange.lowerBound)–\(Config.heatRange.upperBound) (°C) atau 'off'", code: 2)
    }
    saveAndApply(config)

case "topup":
    var config = ConfigStore.load(from: directory)
    config.topUp = true
    saveAndApply(config)

case "apply":
    needRoot()
    saveAndApply(ConfigStore.load(from: directory))

case "logs":
    let n = args.first.flatMap(Int.init) ?? 20
    let text = log.tail(n)
    print(text.isEmpty ? "Belum ada log di \(log.path)" : text)

case "report":
    let config = ConfigStore.load(from: directory)
    guard let b = Battery.read() else { fail("Baterai tidak terbaca") }
    print("Baterai sekarang: \(b.percent)%" + (b.cycleCount.map { ", siklus \($0)" } ?? ""))
    print("Tertinggi hari ini (gauge): \(b.dailyMaxSoc.map { "\($0)%" } ?? "?"), terendah: \(b.dailyMinSoc.map { "\($0)%" } ?? "?")")
    switch Soak.verdict(dailyMax: b.dailyMaxSoc, limit: config.validated().limit, enabled: config.enabled) {
    case .withinLimit: print("Batas \(config.limit)%: ✓ baterai tidak melewati batas")
    case .exceeded(let by): print("Batas \(config.limit)%: ✗ sempat melewati batas sebesar \(by) poin (bisa terjadi sebelum batas dinyalakan hari ini)")
    case .notApplicable: print("Batas: mati, tidak ada yang dinilai")
    }
    let s = Soak.summarize(log: log.tail(5000), since: Date().addingTimeInterval(-86_400))
    print("Daemon 24 jam terakhir: \(s.starts) start, \(s.wakes) kejadian bangun, \(s.applied) kali menulis ulang kunci, \(s.failed) gagal")
    if s.failed > 0 { print("  ada yang gagal: lihat `chargecap logs 50`") }

case "-h", "--help", "help":
    print(usage)

default:
    fail(usage, code: 2)
}
