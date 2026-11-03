// chargecapd: keeps the firmware charge limit in place. Runs as root (LaunchDaemon in Phase 2).
//
// It does not watch the battery percentage: the firmware itself stops and resumes charging. The daemon only
// makes sure the three limit keys hold what config.json asks for, at start, after wake, when the power source
// changes, and every minute (the firmware cleared them before; see PLAN.md).
// Leaving (SIGTERM) does not touch the keys, so a stopped daemon never leaves the Mac in a worse state;
// `chargecap off` is the way to switch the limit off.

import ChargeCapCore
import ChargeCapKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let log = FileLog()
let directory = ConfigStore.directory()

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("chargecapd needs root (sudo)\n".utf8))
    exit(1)
}

let smc: SMCClient
do { smc = try SMCClient() } catch {
    log.write("cannot open SMC: \(error)")
    exit(1)
}
let engine = Engine(smc: smc)
var lastReport = ""
var signalSources: [DispatchSourceSignal] = []

func tick(_ reason: String) {
    let config = ConfigStore.load(from: directory)
    let outcome = engine.apply(config.target)
    // Quiet when nothing changes: log the first quiet tick after a change and every real event.
    let line: String
    switch outcome {
    case .unchanged: line = "ok \(config.target)"
    case .applied(let writes): line = "applied [\(writes.map(\.description).joined(separator: " "))] -> \(config.target)"
    case .failed(let message): line = "FAILED \(message)"
    }
    if line != lastReport || reason != "timer" {
        let battery = Battery.read().map { "battery \($0.percent)% charging=\($0.isCharging) reason=\($0.notChargingReason)" } ?? "battery ?"
        log.write("[\(reason)] \(line) | \(battery)")
        lastReport = line
    }
}

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log.write("stopping (signal \(sig)); the limit keys are left as they are")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

log.write("chargecapd started, config dir \(directory.path)")
tick("start")

let timer = Timer(timeInterval: 60, repeats: true) { _ in tick("timer") }
timer.tolerance = 5
RunLoop.main.add(timer, forMode: .common)

let watcher = PowerWatcher { event in
    switch event {
    case .wake:
        // Give the SMC a moment to settle after wake before reading it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { tick("wake") }
    case .powerSourceChanged:
        tick("power")
    }
}
withExtendedLifetime(watcher) { RunLoop.main.run() }

