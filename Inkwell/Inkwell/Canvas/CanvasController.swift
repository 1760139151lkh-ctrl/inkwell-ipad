import UIKit
import PencilKit

/// Owns the UIKit side of the note editor: the editable `PKCanvasView`, the page
/// backgrounds behind it, the replay overlay above it, and the scrolling title.
///
/// Deliberately *not* observable: ink latency must never depend on SwiftUI
/// re-rendering (PRD §11). SwiftUI talks to it through methods; it talks back
/// through the closures below.
@MainActor
final class CanvasController: NSObject {
    // MARK: Outputs
    var onDrawingChanged: ((PKDrawing) -> Void)?
    var onVisiblePageChanged: ((Int) -> Void)?
    var onUndoStateChanged: ((Bool, Bool) -> Void)?
    var onTap: ((CGPoint, _ isPencil: Bool) -> Void)?   // drawing coordinates
    var onTitleCommitted: ((String) -> Void)?
    var onPencilDoubleTap: (() -> Void)?
    var onUserScrolled: (() -> Void)?
    var onToolUseChanged: ((Bool) -> Void)?
    /// Selected element moved/resized (final = gesture ended).
    var onElementFrameChanged: ((UUID, CGRect, _ final: Bool) -> Void)?
    var onElementDeleteRequested: ((UUID) -> Void)?
    var onElementTextChanged: ((UUID, String, CGFloat) -> Void)?
    var onElementEditingEnded: ((UUID, String) -> Void)?

    // MARK: Views
    let container = CanvasContainerView()
    let canvas = PKCanvasView()
    private let replayCanvas = PKCanvasView()
    private let pagesView = PagesBackgroundView()
    private let titleField = UITextField()
    private let elementsLayer = ElementsLayerView()
    private let replayElementsLayer = ElementsLayerView()
    private let selectionView = ElementSelectionView()

    // MARK: State
    private(set) var paper: Paper
    private(set) var pageCount: Int
    private var geometry: PageGeometry
    private var lastFitWidth: CGFloat = 0
    private var relativeZoom: CGFloat = 1
    private var isApplyingDrawing = false
    private var replayActive = false
    private var replayRevealed = -1
    /// Replay drawing's strokes (faded or not), kept between playhead moves so only the
    /// strokes that cross the playhead are touched (PRD §7.4).
    private var replayStrokes: [PKStroke] = []
    private var replaySourceCount = -1
    private var replayMaskLayer = CALayer()
    private var lastReportedPage = -1
    private var drawingEnabled = true
    private var eraserSessionDrawing: PKDrawing?
    private(set) var viewMode: ViewMode = .seamless
    /// Page under the finger when a drag began (Single Page snapping).
    private var dragStartPage = 0
    private var pdfDocument: CGPDFDocument?

    /// Space reserved above page 1 for the floating toolbars + title.
    var topInset: CGFloat = 62 { didSet { updateInsets() } }
    static let titleHeight: CGFloat = 44
    static let sidePadding: CGFloat = 20

    init(drawing: PKDrawing, paper: Paper, pageCount: Int, title: String, viewMode: ViewMode = .seamless, pdfURL: URL? = nil) {
        self.paper = paper
        self.pageCount = max(1, pageCount)
        self.geometry = PageGeometry(paper: paper)
        self.viewMode = viewMode
        self.pdfDocument = pdfURL.flatMap { CGPDFDocument($0 as CFURL) }
        super.init()
        configureViews()
        pagesView.pdf = pdfDocument
        isApplyingDrawing = true
        canvas.drawing = drawing
        isApplyingDrawing = false
        titleField.text = title
        pagesView.configure(paper: paper, geometry: geometry, pageCount: self.pageCount)
        applyAppearance()
    }

    private func configureViews() {
        container.backgroundColor = Theme.uiCanvasBackdrop
        container.clipsToBounds = true
        container.onLayout = { [weak self] in self?.layout() }
        // The window's undo manager is shared across notes: start each note with a clean history.
        container.onMovedToWindow = { [weak self] in self?.resetUndo() }

        pagesView.isUserInteractionEnabled = false
        container.addSubview(pagesView)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.accessibilityIdentifier = "inkwell.canvas"
        canvas.drawingPolicy = AppSettings.shared.drawWithFinger ? .anyInput : .pencilOnly
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.bouncesZoom = true
        canvas.isScrollEnabled = true
        canvas.addObserver(self, forKeyPath: "contentOffset", options: [], context: nil)
        container.addSubview(canvas)
        // Images and text boxes sit under the ink and scroll with it.
        canvas.addSubview(elementsLayer)
        selectionView.isHidden = true
        canvas.addSubview(selectionView)
        wireSelection()

        replayCanvas.backgroundColor = .clear
        replayCanvas.isOpaque = false
        replayCanvas.isUserInteractionEnabled = false
        replayCanvas.isHidden = true
        replayCanvas.contentInsetAdjustmentBehavior = .never
        replayCanvas.showsVerticalScrollIndicator = false
        replayCanvas.showsHorizontalScrollIndicator = false
        replayCanvas.addSubview(replayElementsLayer)
        container.addSubview(replayCanvas)

        titleField.font = Theme.uiSerif(22, weight: .semibold)
        titleField.textColor = UIColor.white.withAlphaComponent(0.94)
        titleField.returnKeyType = .done
        titleField.autocorrectionType = .no
        titleField.delegate = self
        titleField.accessibilityLabel = "Note title"
        container.addSubview(titleField)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(tap)

        let pencilTap = UITapGestureRecognizer(target: self, action: #selector(handlePencilTap(_:)))
        pencilTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilTap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(pencilTap)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(redoTap)
        undoTap.require(toFail: redoTap)

        let pencil = UIPencilInteraction(delegate: self)
        container.addInteraction(pencil)

        replayMaskLayer.frame = .zero

        let nc = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint] {
            nc.addObserver(self, selector: #selector(undoStateChanged), name: name, object: nil)
        }
    }

    isolated deinit {
        canvas.removeObserver(self, forKeyPath: "contentOffset")
    }

    // MARK: - Public API

    var drawing: PKDrawing { canvas.drawing }

    func setTool(_ tool: PKTool?) {
        if let tool {
            canvas.tool = tool
            drawingEnabled = true
        } else {
            drawingEnabled = false
        }
        canvas.drawingGestureRecognizer.isEnabled = drawingEnabled && selectionView.element == nil
    }

    func setDrawWithFinger(_ on: Bool) {
        canvas.drawingPolicy = on ? .anyInput : .pencilOnly
    }

    func setPaper(_ paper: Paper) {
        let orientationChanged = paper.landscape != self.paper.landscape
        self.paper = paper
        geometry = PageGeometry(paper: paper)
        pagesView.configure(paper: paper, geometry: geometry, pageCount: pageCount)
        applyAppearance()
        if orientationChanged { lastFitWidth = 0 }
        layout()
    }

    func setPageCount(_ count: Int) {
        let count = max(1, count)
        guard count != pageCount else { return }
        pageCount = count
        pagesView.configure(paper: paper, geometry: geometry, pageCount: count)
        updateContentSize()
        reportVisiblePage(force: true)
    }

    func setTitle(_ title: String) {
        if !titleField.isFirstResponder { titleField.text = title }
    }

    func beginEditingTitle() { titleField.becomeFirstResponder() }

    /// Programmatic drawing change (e.g. deleting pages). Rebuilds the stroke index via the
    /// normal change path so replay, tap-to-seek, and auto-scroll stay correct.
    func replaceDrawing(_ drawing: PKDrawing) {
        isApplyingDrawing = true
        canvas.drawing = drawing
        isApplyingDrawing = false
        replayRevealed = -1
        onDrawingChanged?(drawing)
    }

    func undo() { canvas.undoManager?.undo(); undoStateChanged() }
    func redo() { canvas.undoManager?.redo(); undoStateChanged() }

    func resetUndo() {
        canvas.undoManager?.removeAllActions()
        undoStateChanged()
    }

    var visiblePage: Int {
        let zoom = canvas.zoomScale
        let centerY = (canvas.contentOffset.y + canvas.bounds.height * 0.45) / zoom
        return min(pageCount - 1, geometry.pageIndex(forY: max(0, centerY)))
    }

    func scrollToPage(_ index: Int, animated: Bool = true) {
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: offsetY(forPage: index)), animated: animated)
    }

    /// The one page → scroll offset used by the navigator, Go to Page, and Single Page snapping.
    private func offsetY(forPage index: Int) -> CGFloat {
        let i = max(0, min(pageCount - 1, index))
        let rect = geometry.pageRect(i)
        // Page 0 shows its title; later pages sit just under the floating toolbar area.
        let y = i == 0 ? -canvas.contentInset.top : rect.minY * canvas.zoomScale - canvas.contentInset.top + Self.titleHeight - 12
        let maxY = max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        return min(max(-canvas.contentInset.top, y), maxY)
    }

    /// Scrolls so that a drawing-space rect is visible (auto-scroll during replay).
    func ensureVisible(_ rect: CGRect) {
        let zoom = canvas.zoomScale
        let visible = CGRect(x: canvas.contentOffset.x, y: canvas.contentOffset.y + canvas.contentInset.top,
                             width: canvas.bounds.width, height: canvas.bounds.height - canvas.contentInset.top)
        let target = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        guard !visible.intersects(target) else { return }
        let y = target.midY - canvas.bounds.height / 2
        let maxY = max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: min(max(-canvas.contentInset.top, y), maxY)), animated: true)
    }

    // MARK: - Replay (PRD §7.4)

    /// Shows the replay overlay with future strokes faded. Rebuilds only when the
    /// playhead crosses a stroke boundary.
    func updateReplay(active: Bool, playhead: TimeInterval, index: StrokeTimeIndex) {
        guard active, !index.isEmpty else {
            if replayActive { endReplay() }
            return
        }
        if !replayActive {
            replayActive = true
            replayRevealed = -1
            replayCanvas.isHidden = false
            canvas.layer.mask = replayMaskLayer
            syncReplayScroll()
        }
        let revealed = index.revealedCount(at: playhead)
        guard revealed != replayRevealed else { return }
        let source = canvas.drawing.strokes
        if replayRevealed < 0 || replaySourceCount != source.count || replayStrokes.count != source.count {
            // Full rebuild: first frame, or the drawing changed.
            replayStrokes = source
            for i in replayStrokes.indices where index.isFuture(i, at: playhead) {
                replayStrokes[i] = Self.restyled(source[i], ink: Self.faded(source[i].ink))
            }
            replaySourceCount = source.count
        } else {
            // Incremental: only strokes between the old and new playhead positions change.
            // Each changed stroke is rebuilt as a new PKStroke: PencilKit caches rendering per
            // stroke identity and won't repaint a stroke whose only change is its ink color,
            // which made replay lag seconds behind the audio (and stay dark after seeking back).
            let lo = min(revealed, replayRevealed), hi = max(revealed, replayRevealed)
            for k in lo..<hi {
                let i = index.entries[k].stroke
                guard i < source.count else { continue }
                replayStrokes[i] = Self.restyled(source[i], ink: k < revealed ? source[i].ink : Self.faded(source[i].ink))
            }
        }
        replayRevealed = revealed
        replayCanvas.drawing = PKDrawing(strokes: replayStrokes)
    }

    private static func restyled(_ stroke: PKStroke, ink: PKInk) -> PKStroke {
        PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    private static func faded(_ ink: PKInk) -> PKInk {
        var a: CGFloat = 0
        ink.color.getRed(nil, green: nil, blue: nil, alpha: &a)
        return PKInk(ink.inkType, color: ink.color.withAlphaComponent(a * 0.22))
    }

    func invalidateReplay() { replayRevealed = -1 }

    private func endReplay() {
        replayActive = false
        replayRevealed = -1
        replayCanvas.isHidden = true
        replayCanvas.drawing = PKDrawing()
        replayStrokes = []
        replaySourceCount = -1
        canvas.layer.mask = nil
    }

    // MARK: - Layout

    private func layout() {
        let bounds = container.bounds
        guard bounds.width > 0 else { return }
        pagesView.frame = bounds
        canvas.frame = bounds
        replayCanvas.frame = bounds

        let fit = fitScale
        canvas.minimumZoomScale = fit * 0.75
        canvas.maximumZoomScale = fit * 3
        var widthChanged = false
        if abs(bounds.width - lastFitWidth) > 0.5 {
            // Stay pinned to the top of the note if we were there (first layout, library toggle).
            let wasAtTop = lastFitWidth == 0 || canvas.contentOffset.y <= -canvas.contentInset.top + 2
            lastFitWidth = bounds.width
            canvas.zoomScale = fit * relativeZoom
            replayCanvas.minimumZoomScale = canvas.minimumZoomScale
            replayCanvas.maximumZoomScale = canvas.maximumZoomScale
            widthChanged = wasAtTop
        }
        updateContentSize()
        if widthChanged {
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
        syncChrome()
    }

    /// Seamless: page width fills the view. Single Page: the whole page fits on screen.
    private var fitScale: CGFloat {
        let widthFit = (container.bounds.width - Self.sidePadding * 2) / paper.pageSize.width
        guard viewMode == .singlePage else { return widthFit }
        let available = container.bounds.height - topInset - Self.titleHeight - 24
        return max(0.1, min(widthFit, available / paper.pageSize.height))
    }

    private func updateContentSize() {
        let zoom = canvas.zoomScale
        canvas.contentSize = CGSize(width: paper.pageSize.width * zoom,
                                    height: geometry.contentHeight(pageCount: pageCount) * zoom)
        elementsLayer.frame = CGRect(origin: .zero, size: canvas.contentSize)
        elementsLayer.setZoom(zoom)
        replayElementsLayer.frame = elementsLayer.frame
        replayElementsLayer.setZoom(zoom)
        selectionView.update(zoom: zoom)
        updateInsets()
    }

    private func updateInsets() {
        let width = canvas.bounds.width
        let side = max(Self.sidePadding, (width - canvas.contentSize.width) / 2)
        let insets = UIEdgeInsets(top: topInset + Self.titleHeight, left: side, bottom: 160, right: side)
        if canvas.contentInset != insets { canvas.contentInset = insets }
        syncChrome()
    }

    /// Keeps the page backgrounds, title, and replay overlay locked to the canvas scroll.
    private func syncChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let zoom = canvas.zoomScale
        let offset = canvas.contentOffset
        pagesView.setTransform(offset: offset, zoom: zoom, viewport: container.bounds.size)
        let pageLeft = -offset.x
        let pageTop = -offset.y
        titleField.frame = CGRect(x: pageLeft + 4, y: pageTop - Self.titleHeight - 2,
                                  width: max(120, paper.pageSize.width * zoom - 8), height: Self.titleHeight)
        titleField.isHidden = titleField.frame.maxY < topInset - 20 && !titleField.isFirstResponder
        titleField.alpha = min(1, max(0, (titleField.frame.maxY - topInset + 30) / 30))
        CATransaction.commit()
        if replayActive { syncReplayScroll() }
    }

    private func syncReplayScroll() {
        if replayCanvas.zoomScale != canvas.zoomScale { replayCanvas.zoomScale = canvas.zoomScale }
        replayCanvas.contentSize = canvas.contentSize
        replayCanvas.contentInset = canvas.contentInset
        replayCanvas.contentOffset = canvas.contentOffset
    }

    // MARK: - View mode (Seamless / Single Page)

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let page = visiblePage
        viewMode = mode
        canvas.decelerationRate = mode == .singlePage ? .fast : .normal
        relativeZoom = 1
        lastFitWidth = 0
        layout()
        scrollToPage(page, animated: false)
    }

    /// Single Page: after a drag, settle on the page the drag started from, or the next /
    /// previous one for a flick or a drag past half a page. Never skips pages.
    private func snapTarget(for proposedY: CGFloat, velocity: CGFloat) -> CGFloat {
        let pitch = geometry.pitch * canvas.zoomScale
        let startY = offsetY(forPage: dragStartPage)
        var target = dragStartPage
        if velocity > 0.3 || proposedY - startY > pitch / 2 { target += 1 }
        if velocity < -0.3 || startY - proposedY > pitch / 2 { target -= 1 }
        return offsetY(forPage: max(0, min(pageCount - 1, target)))
    }

    // MARK: - Elements (text boxes, images)

    func setElements(_ elements: [ElementSnapshot]) {
        elementsLayer.apply(elements)
        replayElementsLayer.apply(elements)
        if let sel = selectionView.element, let updated = elements.first(where: { $0.id == sel.id }) {
            selectionView.updateStyle(updated)
        }
    }

    func elementHit(at point: CGPoint) -> UUID? { elementsLayer.hit(point) }

    func setPDF(url: URL) {
        pdfDocument = CGPDFDocument(url as CFURL)
        pagesView.pdf = pdfDocument
        pagesView.invalidatePDF()
        syncChrome()
    }

    var selectedElementID: UUID? { selectionView.element?.id }

    func select(elementID: UUID?, editText: Bool = false) {
        guard let id = elementID, let e = elementsLayer.elements.first(where: { $0.id == id }) else {
            selectionView.hide()
            elementsLayer.hiddenID = nil
            canvas.drawingGestureRecognizer.isEnabled = drawingEnabled
            return
        }
        // While an element is selected, drags move it — the pencil must not draw or lasso.
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.bringSubviewToFront(selectionView)
        selectionView.show(e, zoom: canvas.zoomScale, editText: editText)
        elementsLayer.hiddenID = e.kind == .text ? id : nil
    }

    private func wireSelection() {
        selectionView.onMove = { [weak self] frame, final in
            guard let self, let id = self.selectionView.element?.id else { return }
            // The element follows the finger live; the model is updated when the gesture ends.
            self.elementsLayer.updateFrame(id, frame)
            self.replayElementsLayer.updateFrame(id, frame)
            self.onElementFrameChanged?(id, frame, final)
        }
        selectionView.onDelete = { [weak self] in
            guard let self, let id = self.selectionView.element?.id else { return }
            self.onElementDeleteRequested?(id)
        }
        selectionView.onTextChange = { [weak self] text, height in
            guard let self, let id = self.selectionView.element?.id else { return }
            self.onElementTextChanged?(id, text, height)
        }
        selectionView.onEndEditing = { [weak self] text in
            guard let self, let id = self.selectionView.element?.id else { return }
            self.onElementEditingEnded?(id, text)
        }
    }

    /// Replay: fade elements created after the playhead.
    func setElementReplay(future: Set<UUID>) {
        replayElementsLayer.futureIDs = future
    }

    private func applyAppearance() {
        // PencilKit adapts ink colors to the interface style; match the paper, not the app chrome.
        let style: UIUserInterfaceStyle = paper.color.isDark ? .dark : .light
        canvas.overrideUserInterfaceStyle = style
        replayCanvas.overrideUserInterfaceStyle = style
    }

    private func reportVisiblePage(force: Bool = false) {
        let page = visiblePage
        if force || page != lastReportedPage {
            lastReportedPage = page
            onVisiblePageChanged?(page)
        }
    }

    // swiftlint:disable:next block_based_kvo
    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated {
            syncChrome()
            reportVisiblePage()
        }
    }

    // MARK: - Gestures

    @objc private func handleFingerTap(_ g: UITapGestureRecognizer) { reportTap(g, isPencil: false) }
    @objc private func handlePencilTap(_ g: UITapGestureRecognizer) { reportTap(g, isPencil: true) }

    private func reportTap(_ g: UITapGestureRecognizer, isPencil: Bool) {
        guard g.state == .ended else { return }
        let p = g.location(in: canvas)
        let zoom = canvas.zoomScale
        onTap?(CGPoint(x: p.x / zoom, y: p.y / zoom), isPencil)
    }

    var isNavigateMode: Bool { !drawingEnabled }
    var isReplayActive: Bool { replayActive }

    @objc private func handleUndoTap() { undo() }
    @objc private func handleRedoTap() { redo() }

    @objc private func undoStateChanged() {
        let um = canvas.undoManager
        onUndoStateChanged?(um?.canUndo ?? false, um?.canRedo ?? false)
    }
}

// MARK: - PKCanvasViewDelegate

extension CanvasController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        replayRevealed = -1
        onDrawingChanged?(canvasView.drawing)
        undoStateChanged()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if canvasView.tool is PKEraserTool { eraserSessionDrawing = canvasView.drawing }
        // Writing during replay: show the real ink while the pencil is down.
        if replayActive { canvas.layer.mask = nil }
        onToolUseChanged?(true)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Repair once the erase gesture is over, never mid-gesture (PRD §7.2 fallback).
        if repairEraserTimestampsIfNeeded() { onDrawingChanged?(canvas.drawing) }
        eraserSessionDrawing = nil
        if replayActive {
            replayRevealed = -1
            canvas.layer.mask = replayMaskLayer
        }
        onToolUseChanged?(false)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === canvas else { return }
        let fit = fitScale
        if fit > 0 { relativeZoom = canvas.zoomScale / fit }
        updateContentSize()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartPage = visiblePage
        onUserScrolled?()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Only snap at (or near) the fit zoom; zoomed in, the page must scroll freely.
        guard scrollView === canvas, viewMode == .singlePage, canvas.zoomScale <= fitScale * 1.01 else { return }
        targetContentOffset.pointee.y = snapTarget(for: targetContentOffset.pointee.y, velocity: velocity.y)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === canvas else { return }
        pagesView.setTransform(offset: canvas.contentOffset, zoom: canvas.zoomScale, viewport: container.bounds.size, force: true)
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        onUserScrolled?()
    }

    /// PRD §7.2 fallback: if partial erase ever gives split pieces a fresh creationDate,
    /// restore the original stroke's date by bounds overlap so replay timing survives.
    @discardableResult
    private func repairEraserTimestampsIfNeeded() -> Bool {
        guard let before = eraserSessionDrawing, canvas.tool is PKEraserTool else { return false }
        let sessionStart = Date().addingTimeInterval(-600)
        let beforeDates = Set(before.strokes.map { $0.path.creationDate })
        var after = canvas.drawing.strokes
        var changed = false
        for i in after.indices {
            let date = after[i].path.creationDate
            guard !beforeDates.contains(date), date > sessionStart else { continue }
            let bounds = after[i].renderBounds
            var best: (area: CGFloat, date: Date)?
            for old in before.strokes {
                let overlap = old.renderBounds.intersection(bounds)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                if best == nil || area > best!.area { best = (area, old.path.creationDate) }
            }
            if let best {
                let path = after[i].path
                after[i].path = PKStrokePath(controlPoints: Array(path), creationDate: best.date)
                changed = true
            }
        }
        if changed {
            isApplyingDrawing = true
            canvas.drawing = PKDrawing(strokes: after)
            isApplyingDrawing = false
        }
        return changed
    }
}

// MARK: - Title

extension CanvasController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onTitleCommitted?(textField.text ?? "")
    }
}

// MARK: - Apple Pencil double-tap

extension CanvasController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore, .showColorPalette, .showInkAttributes, .showContextualPalette, .runSystemShortcut:
            return
        default:
            onPencilDoubleTap?()
        }
    }
}

// MARK: - Views

final class CanvasContainerView: UIView {
    var onLayout: (() -> Void)?
    var onMovedToWindow: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Paper pages drawn as layers (vector shape layers stay crisp at any zoom).
final class PagesBackgroundView: UIView {
    private let content = CALayer()
    private var pageLayers: [CALayer] = []
    private var configured: (Paper, Int)?
    private var geometry = PageGeometry(paper: Paper())
    /// Imported PDF (P1): each PDF page is drawn as the background of the matching note page.
    var pdf: CGPDFDocument?
    private var pdfLayers: [Int: CALayer] = [:]
    private var pdfRenderedScale: [Int: CGFloat] = [:]
    private var pdfInFlight: Set<Int> = []
    private static let pdfQueue = DispatchQueue(label: "inkwell.pdf-render", qos: .userInitiated)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(content)
        content.anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(paper: Paper, geometry: PageGeometry, pageCount: Int) {
        if let c = configured, c.0 == paper, c.1 == pageCount { return }
        configured = (paper, pageCount)
        self.geometry = geometry
        pdfLayers = [:]
        pdfRenderedScale = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers = []
        let pattern = PaperRenderer.patternPath(paper: paper, size: paper.pageSize)
        for i in 0..<pageCount {
            let page = CALayer()
            page.frame = geometry.pageRect(i)
            page.backgroundColor = UIColor(hex: paper.color.hex).cgColor
            page.cornerRadius = 2
            page.shadowColor = UIColor.black.cgColor
            page.shadowOpacity = 0.28
            page.shadowRadius = 6
            page.shadowOffset = CGSize(width: 0, height: 2)
            page.shadowPath = UIBezierPath(rect: page.bounds).cgPath
            if let pattern {
                let shape = CAShapeLayer()
                shape.frame = page.bounds
                shape.path = pattern
                let color = UIColor(hex: paper.color.patternHex).cgColor
                if paper.style == .dot {
                    shape.fillColor = color
                    shape.strokeColor = nil
                } else {
                    shape.fillColor = nil
                    shape.strokeColor = color
                    shape.lineWidth = 0.6
                }
                shape.contentsScale = UIScreen.main.scale * 3
                page.addSublayer(shape)
            }
            content.addSublayer(page)
            pageLayers.append(page)
        }
        CATransaction.commit()
    }

    func setTransform(offset: CGPoint, zoom: CGFloat, viewport: CGSize, force: Bool = false) {
        var t = CATransform3DMakeTranslation(-offset.x, -offset.y, 0)
        t = CATransform3DScale(t, zoom, zoom, 1)
        content.transform = t
        guard pdf != nil, zoom > 0 else { return }
        // Visible pages ±1 get a bitmap at the current zoom; others are released.
        let top = offset.y / zoom, bottom = (offset.y + viewport.height) / zoom
        let first = max(0, geometry.pageIndex(forY: max(0, top)) - 1)
        let last = min(pageLayers.count - 1, geometry.pageIndex(forY: max(0, bottom)) + 1)
        guard first <= last else { return }
        let wanted = Set(first...last)
        for (i, l) in pdfLayers where !wanted.contains(i) {
            l.removeFromSuperlayer()
            pdfLayers[i] = nil
            pdfRenderedScale[i] = nil
        }
        let scale = min(4, UIScreen.main.scale * zoom)
        for i in wanted {
            if let done = pdfRenderedScale[i], done >= scale * 0.9, !force || done >= scale * 0.99 { continue }
            renderPDFPage(i, scale: scale)
        }
    }

    func invalidatePDF() {
        pdfLayers.values.forEach { $0.removeFromSuperlayer() }
        pdfLayers = [:]
        pdfRenderedScale = [:]
    }

    private func renderPDFPage(_ index: Int, scale: CGFloat) {
        guard let pdf, index + 1 <= pdf.numberOfPages, !pdfInFlight.contains(index),
              index < pageLayers.count else { return }
        pdfInFlight.insert(index)
        let pageSize = geometry.pageSize
        Self.pdfQueue.async { [weak self] in
            let image = Self.renderPDF(pdf, pageNumber: index + 1, pageSize: pageSize, scale: scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pdfInFlight.remove(index)
                guard index < self.pageLayers.count, let image else { return }
                let layer = self.pdfLayers[index] ?? {
                    let l = CALayer()
                    l.frame = CGRect(origin: .zero, size: pageSize)
                    l.contentsGravity = .resize
                    self.pageLayers[index].insertSublayer(l, at: 0)
                    self.pdfLayers[index] = l
                    return l
                }()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = image
                CATransaction.commit()
                self.pdfRenderedScale[index] = scale
            }
        }
    }

    /// Draws one PDF page aspect-fit onto a page-sized bitmap.
    nonisolated static func renderPDF(_ pdf: CGPDFDocument, pageNumber: Int, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        guard let page = pdf.page(at: pageNumber) else { return nil }
        let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        PDFBackground.draw(page: page, in: CGRect(origin: .zero, size: pageSize), context: ctx, flipped: false)
        return ctx.makeImage()
    }
}

/// Draws an imported PDF page aspect-fit into a note page (live canvas, thumbnails, export).
nonisolated enum PDFBackground {
    /// `flipped`: true when the context is UIKit-style (origin top-left, y down).
    /// Page size as displayed, honoring the PDF's /Rotate.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let r = ((Int(page.rotationAngle) % 360) + 360) % 360
        return (r == 90 || r == 270) ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func draw(page: CGPDFPage, in rect: CGRect, context ctx: CGContext, flipped: Bool) {
        let box = page.getBoxRect(.cropBox)
        let shown = displaySize(of: page)
        guard box.width > 0, box.height > 0 else { return }
        let s = min(rect.width / shown.width, rect.height / shown.height)
        let w = shown.width * s, h = shown.height * s
        let origin = CGPoint(x: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2)
        ctx.saveGState()
        // Move to the target rect in PDF-style (y-up) space.
        if flipped {
            ctx.translateBy(x: origin.x, y: origin.y + h)
            ctx.scaleBy(x: 1, y: -1)
        } else {
            ctx.translateBy(x: origin.x, y: rect.maxY - origin.y - h + rect.minY)
        }
        ctx.scaleBy(x: s, y: s)
        // Apply /Rotate (clockwise in PDF), mapping the rotated box into (0,0)-(shown).
        let r = ((Int(page.rotationAngle) % 360) + 360) % 360
        switch r {
        case 90:
            ctx.translateBy(x: 0, y: shown.height)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: shown.width, y: shown.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: shown.width, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
