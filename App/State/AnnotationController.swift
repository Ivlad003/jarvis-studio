import AppKit

// MARK: - KeyableBorderlessWindow

/// Forces `canBecomeKey`/`canBecomeMain` to true on a borderless window so
/// content-view keyDown events fire. Kept here even though the current toolbar
/// drives Edit/View transitions — future revisions may want keyboard shortcuts
/// on the overlay (e.g. `[` / `]` for brush size).
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - AnnotationController

/// Owns the on-screen drawing overlay used over a screen recording. Three
/// states cycle via the global `.toggleAnnotation` hotkey (default ⌘⇧K) and
/// the toolbar's segmented Edit / View control + Close button:
///
///   - `hidden`  — no overlay; strokes from a previous session are discarded.
///   - `editing` — overlay catches mouse events, user draws with the mouse.
///   - `viewing` — overlay is click-through (`ignoresMouseEvents=true`); mouse
///                 clicks land on the underlying apps. **Strokes stay on
///                 screen** so they're still inside `screen.mp4`, and the
///                 floating toolbar stays visible + clickable so the user can
///                 switch back to Edit without the hotkey.
///
/// The toolbar is a separate NSPanel that sits on top in both modes — making
/// the overlay click-through doesn't affect it. That's the whole point of
/// this layout: the user can interact with applications behind the overlay
/// while still seeing their annotations and being able to re-enter Edit
/// with one click.
@available(macOS 14.0, *)
@MainActor
final class AnnotationController {

    enum Mode: Equatable {
        case hidden
        case editing
        case viewing
    }

    private(set) var mode: Mode = .hidden

    private var overlayWindow: NSWindow?
    private weak var canvas: AnnotationCanvasView?
    private var toolPanel: NSPanel?
    private weak var toolPanelView: AnnotationToolPanelView?
    /// Observer that keeps `canvas.toolbarScreenFrame` in sync when the user
    /// drags the floating toolbar around. Removed in `close()`.
    private var toolPanelMoveObserver: NSObjectProtocol?

    // MARK: - Public API

    /// Drive the state machine forward. Bound to the global hotkey. Picks the
    /// right transition based on the current mode so a single key cycles
    /// hidden → editing → viewing → editing → viewing → … indefinitely.
    func toggle() {
        switch mode {
        case .hidden:  enterEditing(preservingStrokes: false)
        case .editing: enterViewing()
        case .viewing: enterEditing(preservingStrokes: true)
        }
    }

    /// editing → viewing. Called by the toolbar's segmented control. Strokes
    /// stay on screen, toolbar stays visible (separate NSPanel), overlay
    /// becomes click-through.
    func lock() {
        guard mode == .editing else { return }
        enterViewing()
    }

    /// viewing → editing. Called by the toolbar's segmented control when the
    /// user picks "Edit". Strokes are preserved; mouse capture is re-armed
    /// on the overlay so subsequent drags add new strokes on top.
    func resumeEditing() {
        guard mode == .viewing else { return }
        enterEditing(preservingStrokes: true)
    }

    /// Fully tear the overlay down and forget all strokes. Called only by the
    /// toolbar's "Close" button — the hotkey deliberately does NOT trigger
    /// this path so the user can't lose their work with a stray keystroke.
    func close() {
        if let token = toolPanelMoveObserver {
            NotificationCenter.default.removeObserver(token)
            toolPanelMoveObserver = nil
        }
        toolPanel?.orderOut(nil)
        toolPanel = nil
        toolPanelView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        canvas = nil
        mode = .hidden
    }

    /// Compatibility hook for older call sites; equivalent to `close()`.
    func hide() { close() }

    // MARK: - State transitions

    /// Open (or re-arm) the overlay in editing mode. When `preservingStrokes`
    /// is true the existing canvas is kept; otherwise a fresh canvas is built.
    /// Idempotent — calling while already editing re-asserts the overlay's
    /// key status without disturbing strokes.
    private func enterEditing(preservingStrokes: Bool) {
        if overlayWindow == nil {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            buildOverlay(screen: screen)
        }
        guard let window = overlayWindow, let canvas else { return }

        if !preservingStrokes {
            canvas.clearAll()
        }
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()

        // Toolbar: keep it open between modes; only create the first time.
        if toolPanel == nil, let screenForPanel = window.screen ?? NSScreen.main {
            showToolPanel(near: screenForPanel)
        }
        toolPanel?.orderFrontRegardless()
        toolPanelView?.setMode(editing: true)
        mode = .editing
    }

    /// editing → viewing. Overlay becomes click-through; toolbar stays.
    private func enterViewing() {
        if let window = overlayWindow {
            window.ignoresMouseEvents = true
        }
        toolPanelView?.setMode(editing: false)
        // Toolbar must stay both visible AND clickable so the user can
        // switch back to Edit. NSPanel is a separate window — the overlay's
        // `ignoresMouseEvents` flag doesn't affect it.
        toolPanel?.orderFrontRegardless()
        mode = .viewing
    }

    // MARK: - Window construction

    private func buildOverlay(screen: NSScreen) {
        let frame = screen.frame
        let window = KeyableBorderlessWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false

        let canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: frame.size))
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas

        self.overlayWindow = window
        self.canvas = canvas
    }

    private func showToolPanel(near screen: NSScreen) {
        guard let canvas else { return }

        let panelSize = NSSize(width: 480, height: 110)
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panelSize.width - 16,
            y: visible.maxY - panelSize.height - 16
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // CRITICAL: toolbar must sit ABOVE the overlay window in window-level
        // order. With both at `.screenSaver`, macOS's hit-test could route
        // a click on the toolbar to the underlying canvas (we observed this
        // in production — strokes drew right across the toolbar buttons).
        // Bumping the panel one tier above guarantees clicks land on the
        // toolbar's controls, not on the overlay below.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.isMovableByWindowBackground = true
        let view = AnnotationToolPanelView(canvas: canvas, controller: self)
        panel.contentView = view
        panel.orderFrontRegardless()

        self.toolPanel = panel
        self.toolPanelView = view

        // Belt-and-suspenders: tell the canvas the toolbar's current screen
        // rect so its mouseDown / mouseDragged refuses to start a stroke
        // inside it, in case macOS routes a click through the overlay
        // despite the higher-level panel above it.
        canvas.toolbarScreenFrame = panel.frame
        if let token = toolPanelMoveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        toolPanelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.canvas?.toolbarScreenFrame = self.toolPanel?.frame ?? .zero
            }
        }
    }
}
