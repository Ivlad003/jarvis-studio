import Foundation
import KeyboardShortcuts
import os

// MARK: - TriggerHotkeyInstaller
//
// Bridges any of the three HotkeyTrigger flavours onto the right backend:
//
//   - .combo            → KeyboardShortcuts under the supplied Name
//   - .holdKey          → KeyTriggerEngine CGEventTap (needs Accessibility)
//   - .doubleTapModifier → not supported here; falls back to .combo with a log
//
// Centralises the routing/fallback logic that all three press/hold/release
// callers (Dictation, Push-to-Markdown, Agent) used to duplicate inline. Each
// caller now just constructs one installer with a unique combo Name + label
// for logs, then drives it via install/uninstall/reinstall.

@available(macOS 14.0, *)
@MainActor
public final class TriggerHotkeyInstaller {

    public typealias Handler = @MainActor () -> Void

    // MARK: Configuration

    /// `KeyboardShortcuts.Name` to use for the legacy combo path. Each consumer
    /// should pass a distinct name (e.g. `.dictation`, `.pushToMarkdown`) so the
    /// user can rebind them independently.
    private let comboName: KeyboardShortcuts.Name
    /// Tag for log messages so a missing-AX failure points at the right feature.
    private let label: String
    private let log: Logger

    // MARK: Backends

    private let monitor: HotkeyMonitor
    /// Engine subscription id when the active trigger is .holdKey. Nil means
    /// the combo path is in use (or nothing is installed).
    private var engineSubscription: KeyTriggerEngine.SubscriptionID?

    // MARK: Init

    public init(comboName: KeyboardShortcuts.Name, label: String) {
        self.comboName = comboName
        self.label = label
        self.monitor = HotkeyMonitor(name: comboName)
        self.log = Logger(subsystem: "dev.kosmonotes.studio", category: "TriggerInstaller.\(label)")
    }

    // MARK: API

    /// Install the supplied trigger. Press/release fire on the main actor.
    public func install(trigger: HotkeyTrigger,
                        onPress: @escaping Handler,
                        onRelease: @escaping Handler) {
        switch trigger {
        case .combo:
            // KeyboardShortcuts handlers are @Sendable; hop back to the main
            // actor before invoking the @MainActor caller closures.
            monitor.startMonitoring(
                onPress: { Task { @MainActor in onPress() } },
                onRelease: { Task { @MainActor in onRelease() } }
            )

        case .holdKey:
            engineSubscription = KeyTriggerEngine.shared.register(
                trigger: trigger,
                onPress: onPress,
                onRelease: onRelease
            )
            if engineSubscription == nil {
                // Engine refused (.combo would never reach here, but
                // Accessibility permission missing also returns nil). Fall
                // back to the combo path so SOMETHING fires.
                log.error("\(self.label): KeyTriggerEngine refused — falling back to .combo")
                install(trigger: .combo, onPress: onPress, onRelease: onRelease)
            }

        case .doubleTapModifier:
            // Push-to-talk has no meaningful "release" event for a double-tap
            // (there's nothing held). Refuse and fall back so the feature
            // stays usable even if a user JSON-edits the pref to an
            // unsupported variant.
            log.error("\(self.label): .doubleTapModifier is not supported for press/hold/release; falling back to .combo")
            install(trigger: .combo, onPress: onPress, onRelease: onRelease)
        }
    }

    /// Tear down whichever path is currently active. Safe to call when nothing
    /// is installed — both backends idempotently no-op.
    public func uninstall() {
        monitor.stopMonitoring()
        if let id = engineSubscription {
            KeyTriggerEngine.shared.unregister(id)
            engineSubscription = nil
        }
    }

    /// Convenience: uninstall + install in one call. Use this from a Settings
    /// change observer so a new trigger takes effect without an app relaunch.
    public func reinstall(trigger: HotkeyTrigger,
                          onPress: @escaping Handler,
                          onRelease: @escaping Handler) {
        uninstall()
        install(trigger: trigger, onPress: onPress, onRelease: onRelease)
    }
}
