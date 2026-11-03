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

var policyState = PolicyState()

func tick(_ reason: String) {
    var config = ConfigStore.load(from: directory)
    let battery = Battery.read()
    let decision = Policy.decide(config: config, conditions: battery?.conditions, previous: policyState)
    let heatChanged = decision.heatHolding != (policyState.heatHold != nil)
    policyState = decision.state
    if decision.topUpDone {
        config.topUp = false
        do { try ConfigStore.save(config, to: directory) } catch { log.write("cannot clear topUp: \(error)") }
        log.write("top up finished at \(battery?.percent ?? 100)%, limit is back")
    }
    if heatChanged {
        log.write(decision.heatHolding
            ? "heat protection ON: \(battery?.temperatureC.map { String(format: "%.1f", $0) } ?? "?") C, holding at \(decision.state.heatHold ?? 0)%"
            : "heat protection released: \(battery?.temperatureC.map { String(format: "%.1f", $0) } ?? "?") C")
    }
    let outcome = engine.apply(decision.target)
    // Quiet when nothing changes: log the first quiet tick after a change and every real event.
    let line: String
    switch outcome {
    case .unchanged: line = "ok \(decision.target)"
    case .applied(let writes): line = "applied [\(writes.map(\.description).joined(separator: " "))] -> \(decision.target)"
    case .failed(let message): line = "FAILED \(message)"
    }
    if line != lastReport || reason != "timer" {
        let info = battery.map { "battery \($0.percent)% \($0.temperatureC.map { String(format: "%.1fC", $0) } ?? "") charging=\($0.isCharging) reason=\($0.notChargingReason)" } ?? "battery ?"
        log.write("[\(reason)] \(line) | \(info)")
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

// Apply a changed config.json at once (the menu bar app and the CLI replace it without root).
var configWatch: DispatchSourceFileSystemObject?
let directoryFD = open(directory.path, O_EVTONLY)
if directoryFD >= 0 {
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFD, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler {
        // A save writes a temp file and renames it: wait a moment so we see the finished file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tick("config") }
    }
    source.setCancelHandler { close(directoryFD) }
    source.resume()
    configWatch = source
}

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

