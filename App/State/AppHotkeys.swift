import KeyboardShortcuts

// MARK: - Global hotkey names

/// App-wide global hotkeys, registered at launch in `AppDelegate.bootstrapHotkeys()`.
/// `dictation` is registered separately by `HotkeyMonitor` in `DictationKit`.
extension KeyboardShortcuts.Name {
    /// Toggle Meeting Mode recording. Default ⌘⇧R.
    static let toggleMeeting = Self("toggleMeeting", default: .init(.r, modifiers: [.command, .shift]))

    /// Toggle Voice Note Mode recording. Default ⌘⇧N.
    static let toggleVoiceNote = Self("toggleVoiceNote", default: .init(.n, modifiers: [.command, .shift]))

    /// Open the Library window. Default ⌘L (chord-only when an app window is foreground;
    /// global registration via KeyboardShortcuts works regardless).
    static let openLibrary = Self("openLibrary", default: .init(.l, modifiers: [.command, .shift]))

    /// Toggle the on-screen drawing overlay. Default ⌘⇧K. Sit on top of every
    /// other window with a transparent canvas and a small floating toolbar so
    /// you can ink arrows / circles / notes over whatever the screen currently
    /// shows. Because the overlay is a real on-screen NSWindow, ScreenCaptureKit
    /// captures it automatically as part of `screen.mp4` — same trick Loom uses.
    static let toggleAnnotation = Self("toggleAnnotation", default: .init(.k, modifiers: [.command, .shift]))
}
