import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Tells the daemon when to look at the keys again: after the Mac wakes, and when the power source changes
/// (charger plugged or removed). Both run on the main run loop.
public final class PowerWatcher {
    // IOKit's sleep/wake message numbers (IOMessage.h); they are C macros, so Swift does not import them.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    public enum Event { case wake, powerSourceChanged }

    private let onEvent: (Event) -> Void
    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?

    public init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        let context = Unmanaged.passUnretained(self).toOpaque()

        // Power source changes.
        let psSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue().onEvent(.powerSourceChanged)
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), psSource, .defaultMode)

        // Sleep and wake.
        root = IORegisterForSystemPower(context, &notificationPort, { ctx, _, messageType, messageArgument in
            guard let ctx else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue()
            switch messageType {
            case PowerWatcher.canSystemSleep, PowerWatcher.systemWillSleep:
                // We never delay sleep.
                IOAllowPowerChange(watcher.root, Int(bitPattern: messageArgument))
            case PowerWatcher.systemHasPoweredOn:
                watcher.onEvent(.wake)
            default:
                break
            }
        }, &notifier)
        if let port = notificationPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        }
    }
}
