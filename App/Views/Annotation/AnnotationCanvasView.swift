import AppKit

// MARK: - AnnotationCanvasView

/// Transparent NSView that owns a list of drawn strokes. Mouse drag adds points
/// to the current stroke; mouse up closes it. Strokes are rendered with the
/// currently-selected color and line width. The view is the entire screen,
/// click-through everywhere we haven't drawn yet — but since NSWindow tracks
/// mouse events on its content view, drag-anywhere-and-draw works.
///
/// Strokes are deliberately retained on screen until `clearAll()` is called so
/// the user can mark up a slide, scroll past, and add another mark — the same
/// way OBS / Loom annotation works. Undo is a single-step pop of the last
/// stroke; we don't implement a full undo stack for v1.
final class AnnotationCanvasView: NSView {

    // MARK: - Stroke model

    struct Stroke {
        let color: NSColor
        let lineWidth: CGFloat
        var points: [CGPoint]
    }

    private(set) var strokes: [Stroke] = []
    private var currentStroke: Stroke?

    /// Active brush color. Switched via the toolbar.
    var brushColor: NSColor = .systemRed
    /// Active brush width. Three presets: 2 / 5 / 10. Persisted by the toolbar.
    var brushWidth: CGFloat = 5

    // The canvas is never the key responder by itself — Edit / View is
    // controlled exclusively from the toolbar's segmented control, so we
    // don't need ESC interception or first-responder hooks here. The
    // overlay window stays non-key in both modes.

    /// Screen-coordinate rectangle of the floating toolbar. Updated by
    /// `AnnotationController` whenever the toolbar appears or moves so the
    /// canvas can refuse mouse events that fall inside it — clicks on the
    /// toolbar buttons must route to the toolbar, not draw a stroke under
    /// it. Belt-and-suspenders alongside the window-level ordering.
    var toolbarScreenFrame: NSRect = .zero

    /// True when the given window-coordinate point falls inside the toolbar
    /// in screen space. Used as the early-bail in mouseDown / mouseDragged
    /// so a click that started on the toolbar never starts (or extends) a
    /// stroke on the canvas underneath.
    private func isPointOverToolbar(_ windowPoint: NSPoint) -> Bool {
        guard !toolbarScreenFrame.isEmpty,
              let win = self.window else { return false }
        let screen = win.convertPoint(toScreen: windowPoint)
        return toolbarScreenFrame.contains(screen)
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    // MARK: - Public API (controller-facing)

    /// Drop all strokes and redraw a clean canvas.
    func clearAll() {
        strokes.removeAll()
        currentStroke = nil
        needsDisplay = true
    }

    /// Pop the most-recent completed stroke. No-op when none. Single-step undo.
    func undoLast() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        // Refuse to start a stroke if the click landed inside the toolbar's
        // screen rect — the event reached us only because the toolbar window
        // didn't catch it (z-order race, level glitch). Without this, fast
        // clicks on Edit / View / Clear etc. start a tiny stroke under them.
        if isPointOverToolbar(event.locationInWindow) {
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        currentStroke = Stroke(color: brushColor, lineWidth: brushWidth, points: [p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = currentStroke else { return }
        // If the drag wandered into the toolbar's screen rect, stop extending
        // the stroke for the remainder of this gesture so it doesn't paint
        // across the toolbar buttons.
        if isPointOverToolbar(event.locationInWindow) {
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        // Drop micro-jitter so the path stays smooth and the stroke array
        // doesn't balloon during fast drags.
        if let last = stroke.points.last,
           abs(last.x - p.x) < 0.5, abs(last.y - p.y) < 0.5 {
            return
        }
        stroke.points.append(p)
        currentStroke = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = currentStroke else { return }
        if stroke.points.count > 1 {
            strokes.append(stroke)
        }
        currentStroke = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for stroke in strokes {
            renderStroke(stroke)
        }
        if let stroke = currentStroke {
            renderStroke(stroke)
        }
    }

    private func renderStroke(_ stroke: Stroke) {
        guard let first = stroke.points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = stroke.lineWidth
        path.move(to: first)
        for p in stroke.points.dropFirst() {
            path.line(to: p)
        }
        stroke.color.setStroke()
        path.stroke()
    }
}

// MARK: - AnnotationToolPanelView

/// SwiftUI-free, plain AppKit toolbar so it never accidentally captures focus
/// (which would let arrow keys / cmd-q be intercepted by SwiftUI). Hosted in
/// a small floating NSPanel by `AnnotationController`.
final class AnnotationToolPanelView: NSView {

    // Five preset colors mapped to the same NSColor values the canvas uses.
    // Picked from system palette so they look right in both light + dark modes.
    private static let palette: [(name: String, color: NSColor)] = [
        ("Red", .systemRed),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Blue", .systemBlue),
        ("Black", .black),
    ]
    private static let widths: [(label: String, value: CGFloat)] = [
        ("Thin", 2),
        ("Medium", 5),
        ("Thick", 10),
    ]

    private weak var canvas: AnnotationCanvasView?
    private weak var controller: AnnotationController?
    private var colorButtons: [NSButton] = []
    private var widthButtons: [NSButton] = []
    /// Segmented "Edit | View" control. Controller can call `setMode(_:)` to
    /// sync the selection when the hotkey changes the controller's state.
    private var modeSegment: NSSegmentedControl?

    init(canvas: AnnotationCanvasView, controller: AnnotationController) {
        self.canvas = canvas
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 96))
        buildUI()
    }

    /// Reflect the controller's current mode on the segmented control without
    /// firing the action target. Used when the global hotkey flips the state
    /// so the toolbar stays in sync.
    func setMode(editing: Bool) {
        modeSegment?.selectedSegment = editing ? 0 : 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 10

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        for (i, entry) in Self.palette.enumerated() {
            let btn = NSButton(title: "", target: self, action: #selector(colorPicked(_:)))
            btn.bezelStyle = .circular
            btn.tag = i
            btn.contentTintColor = entry.color
            btn.image = Self.swatchImage(color: entry.color, size: NSSize(width: 18, height: 18))
            btn.toolTip = entry.name
            colorButtons.append(btn)
            colorRow.addArrangedSubview(btn)
        }

        let widthRow = NSStackView()
        widthRow.orientation = .horizontal
        widthRow.spacing = 6
        for (i, entry) in Self.widths.enumerated() {
            let btn = NSButton(title: entry.label, target: self, action: #selector(widthPicked(_:)))
            btn.bezelStyle = .roundRect
            btn.tag = i
            widthButtons.append(btn)
            widthRow.addArrangedSubview(btn)
        }

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 6

        // Mode switch: Edit (mouse captures strokes) ↔ View (overlay is
        // click-through; mouse goes to underlying apps; strokes stay on
        // screen so they're still in `screen.mp4`). The toolbar itself
        // stays clickable in BOTH modes — it's a separate NSPanel, so the
        // overlay's `ignoresMouseEvents` flag doesn't affect it.
        let segment = NSSegmentedControl(labels: ["Edit", "View"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        segment.selectedSegment = 0
        segment.toolTip = "Edit — draw with the mouse · View — overlay is click-through but the toolbar stays interactive"
        modeSegment = segment
        actionRow.addArrangedSubview(segment)

        let undo = NSButton(title: "Undo", target: self, action: #selector(undoPressed))
        undo.bezelStyle = .roundRect
        actionRow.addArrangedSubview(undo)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearPressed))
        clear.bezelStyle = .roundRect
        actionRow.addArrangedSubview(clear)
        // Close: tear the overlay down completely + wipe strokes.
        let close = NSButton(title: "Close", target: self, action: #selector(closePressed))
        close.bezelStyle = .roundRect
        actionRow.addArrangedSubview(close)

        let mainStack = NSStackView(views: [colorRow, widthRow, actionRow])
        mainStack.orientation = .vertical
        mainStack.spacing = 6
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        // Reflect initial canvas state in the button highlighting.
        refreshSelection()
    }

    /// Render a small colored circle into an NSImage. Used so the color
    /// button's icon shows the actual color even on systems where the
    /// `contentTintColor` doesn't propagate to circular bezel buttons.
    private static func swatchImage(color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    private func refreshSelection() {
        guard let canvas else { return }
        for (i, btn) in colorButtons.enumerated() {
            let active = (Self.palette[i].color == canvas.brushColor)
            btn.alphaValue = active ? 1.0 : 0.55
        }
        for (i, btn) in widthButtons.enumerated() {
            let active = abs(Self.widths[i].value - canvas.brushWidth) < 0.01
            btn.alphaValue = active ? 1.0 : 0.55
        }
    }

    // MARK: - Actions

    @objc private func colorPicked(_ sender: NSButton) {
        guard let canvas, sender.tag >= 0, sender.tag < Self.palette.count else { return }
        canvas.brushColor = Self.palette[sender.tag].color
        refreshSelection()
    }

    @objc private func widthPicked(_ sender: NSButton) {
        guard let canvas, sender.tag >= 0, sender.tag < Self.widths.count else { return }
        canvas.brushWidth = Self.widths[sender.tag].value
        refreshSelection()
    }

    @objc private func undoPressed() {
        canvas?.undoLast()
    }

    @objc private func clearPressed() {
        canvas?.clearAll()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        // 0 = Edit, 1 = View. Controller flips overlay mouse-event capture
        // accordingly; toolbar stays visible + clickable in both modes.
        if sender.selectedSegment == 0 {
            controller?.resumeEditing()
        } else {
            controller?.lock()
        }
    }

    @objc private func closePressed() {
        controller?.close()
    }
}
