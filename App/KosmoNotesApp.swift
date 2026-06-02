import SwiftUI
import AppKit
import AVFoundation
import KeyboardShortcuts
import StorageKit
import DictationKit

@main
struct KosmoNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Stub Settings scene — required by SwiftUI App. Real Settings UI
        // is hosted in a custom NSWindow managed by AppDelegate, because
        // the SwiftUI Settings window doesn't reliably surface from a
        // menu-bar-only app (LSUIElement: true).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var chatWindow: NSWindow?

    // Shared app singletons. Created on launch, kept for the lifetime of the
    // process. macOS-14-only — guarded by `if #available` at construction.
    private var sharedSettings: AnyObject?      // AppSettings (macOS 14+)
    private var recorderHolder: AnyObject?       // RecorderState (macOS 14+)
    private var databaseHolder: AnyObject?       // AppDatabase
    private var sessionStoreHolder: AnyObject?   // SessionStore
    private var chatHolder: AnyObject?           // ChatState (macOS 14+)
    private var dictationHolder: AnyObject?      // DictationState (macOS 14+)
    private var pushToMarkdownHolder: AnyObject? // PushToMarkdownState (macOS 14+)
    private var agentSessionHolder: AnyObject?   // AgentSessionState (macOS 14+)
    private var agentHotkeyHolder: AnyObject?    // AgentHotkeyState (macOS 14+)
    private var agentConsoleHolder: AnyObject?   // AgentConsoleWindowController (macOS 14+)
    private var startupScreenRecordingWarning: String?

    // Library window controller. Stored as AnyObject to avoid @available on
    // a stored property (Swift disallows that). Cast at use-site with #available.
    private var libraryControllerHolder: AnyObject?
    /// On-screen drawing overlay controller (ScreenCaptureKit picks the
    /// overlay window up as part of `screen.mp4`). Stored as AnyObject for
    /// the same reason as the other macOS-14-gated holders.
    private var annotationControllerHolder: AnyObject?

    /// Active KeyTriggerEngine subscription for the optional Library
    /// double-tap shortcut. Stored as `Any?` (rather than the strongly-typed
    /// optional) because Swift disallows `@available` on a stored property
    /// and SubscriptionID is itself macOS-14-gated.
    private var libraryDoubleTapSub: Any?
    private var libraryDoubleTapObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AC-6: minimum-OS gate. Deployment target is 14.0+ (LSMinimumSystemVersion
        // pins this, so macOS will refuse to launch on <14). The remaining check
        // surfaces a defensive warning if somehow the gate didn't fire.
        if !checkMinimumOS() {
            return
        }

        // Ignore SIGPIPE so that writing to a closed child-process stdin
        // (ExternalAgentRunner, BashTool) raises EPIPE in the throwing
        // FileHandle API instead of killing our host process. Default macOS
        // behaviour for SIGPIPE is to terminate.
        signal(SIGPIPE, SIG_IGN)

        // One-shot rename migration: copy `JarvisNote` AppSupport dir +
        // Keychain entries to `KosmoNotes` ones so existing users keep their
        // recordings, sessions, and API keys after the bundle-ID rename.
        // Idempotent — flips a UserDefault flag once done.
        MigrationService.runIfNeeded()

        configureStatusItem()
        configureMenu()

        if #available(macOS 14.0, *) {
            bootstrapAppState()
            bootstrapHotkeys()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding()
        }

        checkPermissionsOnStartup()
    }

    /// Checks and requests system permissions on every launch.
    /// - Mic / Accessibility: request only when not yet determined (system shows dialog).
    /// - Screen recording: uses `CGPreflightScreenCaptureAccess()` on every launch;
    ///   the recording path still handles runtime SCKit failures as audio-only.
    private func checkPermissionsOnStartup() {
        startupScreenRecordingWarning = StartupPermissionPolicy.screenRecordingWarning()
        if #available(macOS 14.0, *),
           let warning = startupScreenRecordingWarning,
           let recorder = recorderState {
            recorder.screenRecordingWarning = warning
            statusItem?.menu?.update()
        }

        // Microphone — request if not yet determined; silent otherwise.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        // Accessibility — prompt if not trusted (system shows its own dialog).
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }
    }

    /// Register global hotkeys for Meeting / Voice Note record + Library open.
    /// Defaults: ⌘⇧R / ⌘⇧N / ⌘⇧L. Users can rebind via System Settings (Wallop's
    /// approach — KeyboardShortcuts persists overrides in UserDefaults under the
    /// shortcut's name).
    @available(macOS 14.0, *)
    private func bootstrapHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleMeeting) { [weak self] in
            Task { @MainActor in self?.recordToggleAction() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleVoiceNote) { [weak self] in
            Task { @MainActor in self?.voiceNoteToggleAction() }
        }
        KeyboardShortcuts.onKeyDown(for: .openLibrary) { [weak self] in
            Task { @MainActor in self?.openLibraryAction() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleAnnotation) { [weak self] in
            Task { @MainActor in self?.toggleAnnotationAction() }
        }

        // Optional one-shot double-tap shortcut for the Library window. Off by
        // default; user opts in via Settings → Hotkeys → "Library double-tap".
        // The combo .openLibrary stays wired regardless.
        applyLibraryDoubleTap()
        libraryDoubleTapObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.libraryDoubleTapModifierDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyLibraryDoubleTap() }
        }
    }

    /// (Re-)register the Library double-tap shortcut from current settings.
    /// Idempotent — drops any previous subscription first.
    @available(macOS 14.0, *)
    @MainActor
    private func applyLibraryDoubleTap() {
        if let existing = libraryDoubleTapSub as? KeyTriggerEngine.SubscriptionID {
            KeyTriggerEngine.shared.unregister(existing)
            libraryDoubleTapSub = nil
        }
        guard let mod = appSettings?.libraryDoubleTapModifier else { return }
        // 350 ms double-tap window — fast enough not to clash with deliberate
        // single taps, slow enough that a double-tap actually feels intentional.
        libraryDoubleTapSub = KeyTriggerEngine.shared.register(
            trigger: .doubleTapModifier(mod, withinMs: 350),
            onPress: { [weak self] in self?.openLibraryAction() },
            onRelease: { /* one-shot — no release work */ }
        )
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If a recording is in progress, defer termination until stop() finishes
        // so segments are finalized and SleepAssertion is released. Returning
        // .terminateLater suspends the quit until we call NSApp.reply(...).
        if #available(macOS 14.0, *), let recorder = recorderState, recorder.status.isBusy {
            Task { @MainActor in
                await recorder.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Returns true when the OS is supported. The actual deployment target is
    /// macOS 14.0+ — `LSMinimumSystemVersion` should already block launch on
    /// anything older, but this is a belt-and-suspenders modal in case the
    /// binary somehow runs on a downgraded system.
    @MainActor
    private func checkMinimumOS() -> Bool {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let major = info.majorVersion
        let minor = info.minorVersion

        guard major < 14 else { return true }

        let alert = NSAlert()
        alert.messageText = "macOS 14.0 or newer required"
        alert.informativeText = "KosmoNotes requires macOS 14.0 or newer. You're on macOS \(major).\(minor). Recording, Library, Settings, and Dictation all require 14.0+; the app cannot run on this system."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Status item + menu

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "KosmoNotes") {
            item.button?.image = image
        }
        item.button?.title = "KN"
        item.button?.imagePosition = .imageLeading
        item.length = NSStatusItem.variableLength
        item.isVisible = true
        self.statusItem = item
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Version header — disabled menu item that shows what build is actually
        // running. Useful when rebuilding ad-hoc dev binaries: confirms whether
        // the app you're talking to is the latest one or a stale relaunch.
        let versionItem = NSMenuItem(title: "KosmoNotes \(Self.appVersionLine())", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let copyVersionItem = NSMenuItem(title: "Copy version info",
                                         action: #selector(copyVersionAction),
                                         keyEquivalent: "")
        copyVersionItem.target = self
        menu.addItem(copyVersionItem)

        menu.addItem(.separator())

        let recordItem = NSMenuItem(title: "Start Recording",
                                    action: #selector(recordToggleAction),
                                    keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        recordItem.identifier = NSUserInterfaceItemIdentifier("recordToggle")
        menu.addItem(recordItem)

        let voiceNoteItem = NSMenuItem(title: "Start Voice Note",
                                       action: #selector(voiceNoteToggleAction),
                                       keyEquivalent: "n")
        voiceNoteItem.keyEquivalentModifierMask = [.command, .shift]
        voiceNoteItem.target = self
        voiceNoteItem.identifier = NSUserInterfaceItemIdentifier("voiceNoteToggle")
        menu.addItem(voiceNoteItem)

        // Live mic mute — only meaningful while a recording is active.
        // menuNeedsUpdate enables / disables it based on RecorderState.status
        // and toggles the title between "Mute mic" and "Unmute mic".
        let muteItem = NSMenuItem(title: "Mute mic",
                                  action: #selector(toggleMicMuteAction),
                                  keyEquivalent: "m")
        muteItem.keyEquivalentModifierMask = [.command, .shift]
        muteItem.target = self
        muteItem.identifier = NSUserInterfaceItemIdentifier("toggleMicMute")
        menu.addItem(muteItem)

        let liveTranscriptItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        liveTranscriptItem.identifier = NSUserInterfaceItemIdentifier("liveTranscriptStatus")
        liveTranscriptItem.isEnabled = false
        liveTranscriptItem.isHidden = true
        menu.addItem(liveTranscriptItem)

        let screenWarningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        screenWarningItem.identifier = NSUserInterfaceItemIdentifier("screenRecordingWarning")
        screenWarningItem.isEnabled = false
        screenWarningItem.isHidden = true
        menu.addItem(screenWarningItem)

        menu.addItem(.separator())

        let openLastSessionItem = NSMenuItem(title: "Open last session in Finder",
                                             action: #selector(openLastSessionAction),
                                             keyEquivalent: "")
        openLastSessionItem.target = self
        openLastSessionItem.identifier = NSUserInterfaceItemIdentifier("openLastSession")
        menu.addItem(openLastSessionItem)

        let libraryItem = NSMenuItem(title: "Library…",
                                     action: #selector(openLibraryAction),
                                     keyEquivalent: "l")
        libraryItem.target = self
        menu.addItem(libraryItem)

        menu.addItem(.separator())

        let chatItem = NSMenuItem(title: "Chat…",
                                  action: #selector(openChat),
                                  keyEquivalent: "t")
        chatItem.keyEquivalentModifierMask = [.command]
        chatItem.target = self
        menu.addItem(chatItem)

        let agentItem = NSMenuItem(title: "Agent Console…",
                                   action: #selector(openAgentConsole),
                                   keyEquivalent: "")
        agentItem.target = self
        menu.addItem(agentItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit KosmoNotes",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        // Leave target = nil so the responder chain reaches NSApp.terminate(_:).
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    // MARK: - App state bootstrap (macOS 14+)

    @available(macOS 14.0, *)
    private func bootstrapAppState() {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            presentFatalSetupError("Could not locate Application Support directory.", error: error)
            return
        }

        let appDir = appSupport.appendingPathComponent("KosmoNotes", isDirectory: true)
        let recordingsDir = appDir.appendingPathComponent("recordings", isDirectory: true)
        let dbPath = appDir.appendingPathComponent("sessions.sqlite")

        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            presentFatalSetupError("Could not create recordings directory at \(recordingsDir.path).", error: error)
            return
        }

        let database: AppDatabase
        do {
            database = try AppDatabase(path: dbPath)
        } catch {
            presentFatalSetupError("Could not open database at \(dbPath.path).", error: error)
            return
        }

        let sessionStore: SessionStore
        do {
            sessionStore = try SessionStore(rootDir: recordingsDir, database: database)
        } catch {
            presentFatalSetupError("Could not create session store at \(recordingsDir.path).", error: error)
            return
        }

        // Settings load from UserDefaults / Keychain — pure read, safe to do
        // before migration. Stored on the side so the migration Task can pick
        // it up without recapturing.
        let settings = AppSettings()
        self.sharedSettings = settings
        // Emit a snapshot of the loaded config to os_log so the Settings → Logs
        // tab shows the user exactly what state the app booted with — useful
        // when triaging "this didn't work" reports without needing to ask the
        // user to read out a dozen toggle states.
        settings.logSnapshot(context: "startup")

        // CRITICAL: do NOT publish recorder/dictation/database/sessionStore until
        // database.migrate() finishes. menuNeedsUpdate, hotkeys, and UI all read
        // recorderState; the moment that returns non-nil, an INSERT INTO sessions
        // can race the schema migration. Holding back the assignment is the only
        // reliable way to gate that path.
        Task { @MainActor in
            do {
                try await database.migrate()
            } catch {
                presentFatalSetupError("Could not migrate database.", error: error)
                return
            }

            // Migration complete — publish everything.
            self.databaseHolder = database
            self.sessionStoreHolder = sessionStore

            let recorder = RecorderState(
                database: database,
                sessionStore: sessionStore,
                settings: settings
            )
            if let startupScreenRecordingWarning {
                recorder.screenRecordingWarning = startupScreenRecordingWarning
            }
            self.recorderHolder = recorder

            // Dictation: register the global hotkey monitor. The pipeline itself
            // is rebuilt on every press so settings changes apply without relaunch.
            // sessionStore is wired so each successful dictation lands in Library
            // as a mode = .dictation SessionRecord with audio.m4a + transcript.
            let dictation = DictationState(settings: settings, sessionStore: sessionStore)
            dictation.install()
            self.dictationHolder = dictation

            // Push-to-Markdown: same press/hold/release shape as Dictation,
            // saves a `.md` file at markdownExportFolder via MarkdownExporter
            // instead of pasting into the focused field.
            let p2md = PushToMarkdownState(settings: settings, sessionStore: sessionStore)
            p2md.install()
            self.pushToMarkdownHolder = p2md

            // Autonomous agent: voice instruction → tool-using Claude loop
            // restricted to the workspace folder. Hotkey installs even when
            // disabled (it bails inside handlePress on the toggle), so a
            // future enable doesn't require relaunch.
            let agentSession = AgentSessionState(settings: settings)
            self.agentSessionHolder = agentSession
            let agentHotkey = AgentHotkeyState(settings: settings, agentSession: agentSession)
            agentHotkey.install()
            self.agentHotkeyHolder = agentHotkey

            // Force a menu refresh so any stale "Recording requires macOS 14+"
            // labels flip to the real recorder-ready titles.
            statusItem?.menu?.update()

            // After migration, scan for orphan sessions and offer recovery.
            let coordinator = RecoveryCoordinator(sessionStore: sessionStore, database: database)
            let recoveryResult = await coordinator.runAtLaunch(rootDir: recordingsDir)
            switch recoveryResult {
            case .noOrphans, .userDeclined:
                break
            case .recovered(let n):
                let alert = NSAlert()
                alert.messageText = "Recovered \(n) session(s)"
                alert.informativeText = "Audio files were rebuilt from interrupted recordings. Open the Library to review."
                alert.alertStyle = .informational
                alert.runModal()
            case .partial(let r, let f):
                let alert = NSAlert()
                alert.messageText = "Recovery partial"
                alert.informativeText = "\(r) recovered, \(f) failed. Failed sessions remain on disk under \(recordingsDir.path)."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func presentFatalSetupError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "KosmoNotes setup failed"
        alert.informativeText = "\(message)\n\n\(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.runModal()
    }

    @available(macOS 14.0, *)
    private var recorderState: RecorderState? {
        recorderHolder as? RecorderState
    }

    @available(macOS 14.0, *)
    private var appSettings: AppSettings? {
        sharedSettings as? AppSettings
    }

    @available(macOS 14.0, *)
    private var appDatabase: AppDatabase? {
        databaseHolder as? AppDatabase
    }

    @available(macOS 14.0, *)
    private var appSessionStore: SessionStore? {
        sessionStoreHolder as? SessionStore
    }

    // Returns the shared LibraryWindowController, creating it on first access.
    @available(macOS 14.0, *)
    private var libraryWindowController: LibraryWindowController {
        if let existing = libraryControllerHolder as? LibraryWindowController {
            return existing
        }
        let controller = LibraryWindowController()
        libraryControllerHolder = controller
        return controller
    }

    // MARK: - Menu actions

    /// "0.0.2 (build 2)" — read at runtime from the bundle's Info.plist so the
    /// menu always reflects what's actually loaded, not a stale source-coded
    /// constant. Sole reason this exists: rebuild loops where the user can't
    /// tell whether the running instance is the latest binary or a stale one.
    @MainActor
    static func appVersionLine() -> String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (build \(build))"
    }

    /// Copy a one-line version + system summary to the clipboard. Useful when
    /// reporting issues — paste it into chat / GitHub and the recipient knows
    /// exactly which build of which OS produced the problem.
    @MainActor
    @objc private func copyVersionAction() {
        let line = "KosmoNotes \(Self.appVersionLine()) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(line, forType: .string)
    }

    @MainActor
    @objc private func toggleMicMuteAction() {
        guard #available(macOS 14.0, *), let recorder = recorderState else { return }
        Task { @MainActor in
            await recorder.toggleMicMute()
            statusItem?.menu?.update()
        }
    }

    @objc private func recordToggleAction() {
        guard #available(macOS 14.0, *) else {
            let alert = NSAlert()
            alert.messageText = "Recording requires macOS 14.0+"
            alert.runModal()
            return
        }
        guard let recorder = recorderState else { return }
        Task { @MainActor in
            await recorder.toggle()
            statusItem?.menu?.update()
            // No modals here. `recorder.screenRecordingWarning` and
            // `recorder.status` are @Observable — RecorderView surfaces both
            // inline. On `.complete`, just reveal the audio file in Finder so
            // the user can grab it without a confirmation popup.
            if case .complete(_, let audioFile, _) = recorder.status {
                NSWorkspace.shared.activateFileViewerSelecting([audioFile])
            }
        }
    }

    @objc private func openLastSessionAction() {
        guard #available(macOS 14.0, *), let recorder = recorderState else { return }
        if case .complete(_, let audioFile, _) = recorder.status {
            NSWorkspace.shared.activateFileViewerSelecting([audioFile])
        }
    }

    /// Toggle Voice Note Mode recording (⌘⇧N). Same lifecycle as Meeting toggle,
    /// but starts the recorder in `.voiceNote` mode so the post-process pipeline
    /// uses the voice-note prompt template.
    @MainActor
    @objc private func voiceNoteToggleAction() {
        guard #available(macOS 14.0, *) else { return }
        guard let recorder = recorderState else { return }
        Task { @MainActor in
            switch recorder.status {
            case .idle, .complete, .failed:
                await recorder.start(mode: .voiceNote)
            case .recording:
                await recorder.stop()
            case .transcribing:
                break
            }
            statusItem?.menu?.update()
        }
    }

    @MainActor
    @objc private func openLibraryAction() {
        guard #available(macOS 14.0, *) else {
            let alert = NSAlert()
            alert.messageText = "Library requires macOS 14.0+"
            alert.runModal()
            return
        }
        guard let database = databaseHolder as? AppDatabase,
              let sessionStore = sessionStoreHolder as? SessionStore else { return }
        libraryWindowController.open(
            database: database,
            sessionStore: sessionStore,
            settings: appSettings,
            windowDelegate: self
        )
    }

    /// Toggle the on-screen drawing overlay (default ⌘⇧K). Lazy-creates the
    /// controller on first use so unused launches don't pay any cost. The
    /// drawn strokes live inside an NSWindow above all app content, so
    /// ScreenCaptureKit picks them up automatically as part of `screen.mp4`.
    @objc private func toggleAnnotationAction() {
        guard #available(macOS 14.0, *) else { return }
        let controller: AnnotationController
        if let existing = annotationControllerHolder as? AnnotationController {
            controller = existing
        } else {
            let new = AnnotationController()
            annotationControllerHolder = new
            controller = new
        }
        controller.toggle()
    }

    @MainActor
    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard #available(macOS 14.0, *), let settings = appSettings else {
            let alert = NSAlert()
            alert.messageText = "Settings require macOS 14.0+"
            alert.runModal()
            return
        }

        let view = SettingsView(settings: settings)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "KosmoNotes Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    @MainActor
    @objc private func openAgentConsole() {
        guard #available(macOS 14.0, *) else { return }
        guard let session = agentSessionHolder as? AgentSessionState else { return }
        let controller: AgentConsoleWindowController
        if let existing = agentConsoleHolder as? AgentConsoleWindowController {
            controller = existing
        } else {
            controller = AgentConsoleWindowController()
            agentConsoleHolder = controller
        }
        controller.open(session: session, windowDelegate: self)
    }

    @MainActor
    @objc private func openChat() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = chatWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard #available(macOS 14.0, *),
              let settings = appSettings,
              let database = appDatabase,
              let sessionStore = appSessionStore else {
            let alert = NSAlert()
            alert.messageText = "Chat requires macOS 14.0+"
            alert.runModal()
            return
        }

        guard let recorder = recorderState else {
            // recorderState is guarded by #available above; this path is unreachable in practice.
            return
        }

        let chatState = ChatState(
            settings: settings,
            database: database,
            sessionStore: sessionStore,
            recorder: recorder,
            agentSession: agentSessionHolder as? AgentSessionState,
            onOpenAgentConsole: { [weak self] in
                self?.openAgentConsole()
            }
        )
        self.chatHolder = chatState

        let view = ChatView(chat: chatState, settings: settings)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "KosmoNotes Chat"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 700))
        window.minSize = NSSize(width: 540, height: 600)
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("chat")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.chatWindow = window
    }

    private func showOnboarding() {
        let didOnboardBinding = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: "didOnboard") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "didOnboard")
                if newValue {
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                    if self.settingsWindow == nil {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        )

        let contentView = OnboardingView(didOnboard: didOnboardBinding)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to KosmoNotes"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.delegate = self

        NSApp.setActivationPolicy(.regular)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let recordItem = menu.items.first(where: { $0.identifier?.rawValue == "recordToggle" }) else { return }
        let voiceNoteItem = menu.items.first(where: { $0.identifier?.rawValue == "voiceNoteToggle" })
        let muteItem = menu.items.first(where: { $0.identifier?.rawValue == "toggleMicMute" })
        let liveTranscriptItem = menu.items.first(where: { $0.identifier?.rawValue == "liveTranscriptStatus" })
        let screenWarningItem = menu.items.first(where: { $0.identifier?.rawValue == "screenRecordingWarning" })
        guard let openLastItem = menu.items.first(where: { $0.identifier?.rawValue == "openLastSession" }) else { return }

        // Mute item: only meaningful while a recording is in flight.
        if #available(macOS 14.0, *), let recorder = recorderState, case .recording = recorder.status {
            muteItem?.isEnabled = true
            muteItem?.title = recorder.micMuted ? "Unmute mic" : "Mute mic"
        } else {
            muteItem?.isEnabled = false
            muteItem?.title = "Mute mic"
        }

        if #available(macOS 14.0, *), let recorder = recorderState {
            updateLiveTranscriptItem(liveTranscriptItem, recorder: recorder)
            updateScreenRecordingWarningItem(screenWarningItem, recorder: recorder)
            switch recorder.status {
            case .idle:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            case .recording:
                recordItem.title = "Stop Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Stop Voice Note"
                voiceNoteItem?.isEnabled = true
            case .transcribing:
                recordItem.title = "Transcribing…"
                recordItem.isEnabled = false
                voiceNoteItem?.isEnabled = false
            case .complete:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            case .failed:
                recordItem.title = "Start Recording (last failed — see Settings)"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            }

            if case .complete = recorder.status {
                openLastItem.isEnabled = true
            } else {
                openLastItem.isEnabled = false
            }
        } else {
            recordItem.title = "Recording (macOS 14+ required)"
            recordItem.isEnabled = false
            voiceNoteItem?.isEnabled = false
            openLastItem.isEnabled = false
            liveTranscriptItem?.isHidden = true
            screenWarningItem?.isHidden = true
        }
    }

    @available(macOS 14.0, *)
    private func updateScreenRecordingWarningItem(_ item: NSMenuItem?, recorder: RecorderState) {
        guard let item else { return }
        guard let title = RecorderMenuPresenter.screenRecordingWarningTitle(for: recorder.screenRecordingWarning) else {
            item.isHidden = true
            item.title = ""
            return
        }

        item.isHidden = false
        item.title = title
    }

    @available(macOS 14.0, *)
    private func updateLiveTranscriptItem(_ item: NSMenuItem?, recorder: RecorderState) {
        guard let item else { return }
        guard recorder.showsLiveTranscript else {
            item.isHidden = true
            item.title = ""
            return
        }

        item.isHidden = false
        item.title = formatLiveTranscriptLine(recorder)
    }

    @available(macOS 14.0, *)
    private func formatLiveTranscriptLine(_ recorder: RecorderState) -> String {
        let stable = recorder.liveTranscriptStableText
        let mutable = recorder.liveTranscriptMutableText
        let status = recorder.liveTranscriptStatusText

        var parts: [String] = []
        if !stable.isEmpty {
            parts.append(clippedMenuText(stable, limit: 48))
        }
        if !mutable.isEmpty {
            parts.append("[\(clippedMenuText(mutable, limit: 32))]")
        }

        let transcriptText = parts.joined(separator: " ")
        if transcriptText.isEmpty {
            return "Live: \(status ?? "Waiting…")"
        }
        if let status {
            return "Live: \(transcriptText) • \(status)"
        }
        return "Live: \(transcriptText)"
    }

    private func clippedMenuText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        switch window.identifier?.rawValue {
        case "settings":
            settingsWindow = nil
        case "library":
            if #available(macOS 14.0, *) {
                // Only call didClose if the controller was actually created.
                (libraryControllerHolder as? LibraryWindowController)?.didClose()
            }
        case "onboarding":
            onboardingWindow = nil
        case "chat":
            chatWindow = nil
            chatHolder = nil
        case "agentConsole":
            if #available(macOS 14.0, *) {
                (agentConsoleHolder as? AgentConsoleWindowController)?.didClose()
            }
        default:
            break
        }
        maybeDemoteToAccessory()
    }

    /// Demote the app to .accessory only when no app-owned window is still on
    /// screen. The previous per-case checks each only knew about a subset of the
    /// other windows, so closing Settings while the Library was open would
    /// demote and yank the Library out of the foreground.
    @MainActor
    private func maybeDemoteToAccessory() {
        let libraryVisible: Bool = {
            if #available(macOS 14.0, *),
               let controller = libraryControllerHolder as? LibraryWindowController {
                return controller.isVisible
            }
            return false
        }()
        let agentConsoleVisible: Bool = {
            if #available(macOS 14.0, *),
               let controller = agentConsoleHolder as? AgentConsoleWindowController {
                return controller.isVisible
            }
            return false
        }()
        let anyVisible = settingsWindow != nil
            || onboardingWindow != nil
            || chatWindow != nil
            || libraryVisible
            || agentConsoleVisible
        if !anyVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
