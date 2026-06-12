import AppKit
import SwiftUI
import StorageKit

// MARK: - LibraryWindowController

/// Opens (or focuses) the Library window from AppDelegate.
///
/// Pattern mirrors the Settings window in AppDelegate: singleton NSWindow,
/// isReleasedWhenClosed = false, delegates window-close back to AppDelegate
/// via NSWindowDelegate so the activation policy can be restored.
@available(macOS 14.0, *)
@MainActor
final class LibraryWindowController {

    private weak var window: NSWindow?

    /// Open the Library window. If it already exists, bring it to front.
    /// `settings` is optional so tests / previews can build a window without
    /// constructing a full AppSettings (semantic search just stays off).
    func open(
        database: AppDatabase,
        sessionStore: SessionStore,
        settings: AppSettings? = nil,
        windowDelegate: NSWindowDelegate
    ) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let libraryState = LibraryState(
            database: database,
            sessionStore: sessionStore,
            settings: settings,
            canClearAllSessions: { [weak self] in
                guard let delegate = self?.window?.delegate as? AppDelegate else { return true }
                return delegate.canClearLibrarySessions
            }
        )
        let view = LibraryView(state: libraryState)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.title = "KosmoNotes Library"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 1100, height: 700))
        win.minSize = NSSize(width: 800, height: 500)
        win.center()
        win.identifier = NSUserInterfaceItemIdentifier("library")
        win.delegate = windowDelegate

        self.window = win

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Called by AppDelegate's windowWillClose to nil the reference.
    func didClose() {
        window = nil
    }

    /// True when the Library window is open and visible. Used by AppDelegate's
    /// activation-policy bookkeeping so closing Settings or Chat doesn't demote
    /// the app while the Library is still on screen.
    var isVisible: Bool {
        window?.isVisible == true
    }
}
