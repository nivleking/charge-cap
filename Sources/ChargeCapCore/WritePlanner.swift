import Foundation

/// Decides which writes get the keys from `current` to `target`, and in which order.
///
/// The firmware rejects a configuration where stop < resume (SMC error 0x89) and then clears the
/// mode key. So at every moment stop >= resume must hold:
///  - lowering resume: write resume first, then stop;
///  - raising resume: write stop first, then resume;
///  - switching on: values first, mode last;
///  - switching off: only the mode (the firmware ignores the values while the mode is 00).
public enum WritePlanner {
    public static func steps(from current: SMCState, to target: SMCState) -> [Write] {
        if target.mode == 0 { return current.mode == 0 ? [] : [Write(.mode, 0)] }
        var values: [Write] = []
        let lowering = target.resume < current.resume
        let ordered: [(ChargeKey, UInt8, UInt8)] = lowering
            ? [(.resume, current.resume, target.resume), (.stop, current.stop, target.stop)]
            : [(.stop, current.stop, target.stop), (.resume, current.resume, target.resume)]
        for (key, now, want) in ordered where now != want { values.append(Write(key, want)) }

        return values + (current.mode != target.mode ? [Write(.mode, target.mode)] : [])
    }
}
