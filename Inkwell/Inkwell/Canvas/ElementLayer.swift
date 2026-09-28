import UIKit

/// A text box or image on the page, in drawing (page) coordinates (PRD §8.1 PageElement).
nonisolated struct ElementSnapshot: Equatable, @unchecked Sendable {
    var id: UUID
    var kind: ElementKind
    var frame: CGRect
    var text: String
    var fontSize: CGFloat
    var isBold: Bool
    var colorHex: String
    var image: UIImage?
    var createdAt: Date

    static let defaultFontSize: CGFloat = 16

    func font(zoom: CGFloat = 1) -> UIFont {
        ElementSnapshot.serif(fontSize * zoom, bold: isBold)
    }

    /// Typed text on a page uses a serif face, not the system sans.
    static func serif(_ size: CGFloat, bold: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard let d = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    /// Height a text box needs for its width.
    static func textHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let s = text.isEmpty ? " " : text
        let rect = (s as NSString).boundingRect(with: CGSize(width: width - 12, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font], context: nil)
        return ceil(rect.height) + 12
    }

    /// Draws the element into a context in page coordinates (thumbnails, PDF export).
    func draw(offsetY: CGFloat = 0) {
        let r = frame.offsetBy(dx: 0, dy: -offsetY)
        switch kind {
        case .image:
            image?.draw(in: r)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: font(), .foregroundColor: UIColor(hex: colorHex)]
            (text as NSString).draw(with: r.insetBy(dx: 6, dy: 6), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: attrs, context: nil)
        }
    }
}

/// Renders elements beneath the ink. Lives inside the PKCanvasView (index 0) so it scrolls
/// natively; frames are laid out in zoomed content coordinates.
final class ElementsLayerView: UIView {
    private var views: [UUID: UIView] = [:]
    private(set) var elements: [ElementSnapshot] = []
    private var zoom: CGFloat = 1
    var hiddenID: UUID? { didSet { if oldValue != hiddenID { relayout() } } }
    /// Elements that haven't "happened" yet at the replay playhead (drawn faded).
    var futureIDs: Set<UUID> = [] { didSet { if oldValue != futureIDs { relayout() } } }
    var paperIsDark = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ elements: [ElementSnapshot]) {
        self.elements = elements
        let ids = Set(elements.map(\.id))
        for (id, v) in views where !ids.contains(id) {
            v.removeFromSuperview()
            views[id] = nil
        }
        for e in elements where views[e.id] == nil {
            let v: UIView
            switch e.kind {
            case .image:
                let iv = UIImageView()
                iv.contentMode = .scaleToFill
                v = iv
            case .text:
                let l = UILabel()
                l.numberOfLines = 0
                l.lineBreakMode = .byWordWrapping
                v = l
            }
            addSubview(v)
            views[e.id] = v
        }
        relayout()
    }

    /// Live frame change during a drag/resize (before the model is updated).
    func updateFrame(_ id: UUID, _ frame: CGRect) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[i].frame = frame
        relayout()
    }

    func setZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        relayout()
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for e in elements {
            guard let v = views[e.id] else { continue }
            v.frame = CGRect(x: e.frame.minX * zoom, y: e.frame.minY * zoom,
                             width: e.frame.width * zoom, height: e.frame.height * zoom)
            v.isHidden = e.id == hiddenID
            v.alpha = futureIDs.contains(e.id) ? 0.22 : 1
            if let iv = v as? UIImageView {
                iv.image = e.image
            } else if let l = v as? UILabel {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                l.attributedText = NSAttributedString(string: e.text, attributes: [
                    .font: e.font(zoom: zoom),
                    .foregroundColor: UIColor(hex: e.colorHex),
                    .paragraphStyle: style,
                ])
                l.frame = v.frame.insetBy(dx: 6 * zoom, dy: 6 * zoom)
                l.frame.size.height = max(l.frame.height, 1)
                // Align to the top like the editor does.
                let fit = l.sizeThatFits(CGSize(width: l.frame.width, height: .greatestFiniteMagnitude))
                l.frame.size.height = min(fit.height, v.frame.height)
            }
        }
        CATransaction.commit()
    }

    func hit(_ point: CGPoint) -> UUID? {
        // Topmost (last-added) first.
        elements.reversed().first { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }?.id
    }
}

/// Selection chrome for one element: move by dragging, resize from the corner, delete,
/// and (for text) edit in place. Lives inside the PKCanvasView above the ink.
final class ElementSelectionView: UIView, UITextViewDelegate {
    var onMove: ((CGRect, _ final: Bool) -> Void)?
    var onDelete: (() -> Void)?
    var onTextChange: ((String, CGFloat) -> Void)?   // text, new height in page units
    var onEndEditing: ((String) -> Void)?

    private(set) var element: ElementSnapshot?
    private var zoom: CGFloat = 1
    private let border = CAShapeLayer()
    private let handle = UIView()
    private let deleteButton = UIButton(type: .system)
    let textView = UITextView()
    private var dragStartFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        border.fillColor = nil
        border.strokeColor = UIColor(hex: "#4A90E2").cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [5, 3]
        layer.addSublayer(border)

        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.autocorrectionType = .default
        addSubview(textView)

        handle.backgroundColor = UIColor(hex: "#4A90E2")
        handle.layer.cornerRadius = 7
        handle.layer.borderColor = UIColor.white.cgColor
        handle.layer.borderWidth = 2
        handle.accessibilityLabel = "Resize"
        addSubview(handle)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        config.baseBackgroundColor = UIColor(hex: "#FF453A")
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        deleteButton.configuration = config
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        addSubview(deleteButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        handle.addGestureRecognizer(resize)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ element: ElementSnapshot, zoom: CGFloat, editText: Bool) {
        self.element = element
        self.zoom = zoom
        isHidden = false
        textView.isHidden = element.kind != .text
        if element.kind == .text {
            textView.text = element.text
            textView.font = element.font(zoom: zoom)
            textView.textColor = UIColor(hex: element.colorHex)
            textView.tintColor = UIColor(hex: "#4A90E2")
            if editText { textView.becomeFirstResponder() }
        }
        layoutForElement()
    }

    func update(zoom: CGFloat) {
        guard element != nil else { return }
        self.zoom = zoom
        if let e = element, e.kind == .text { textView.font = e.font(zoom: zoom) }
        layoutForElement()
    }

    func updateStyle(_ element: ElementSnapshot) {
        guard self.element?.id == element.id else { return }
        self.element = element
        textView.font = element.font(zoom: zoom)
        textView.textColor = UIColor(hex: element.colorHex)
        layoutForElement()
    }

    func hide() {
        if textView.isFirstResponder { textView.resignFirstResponder() }
        element = nil
        isHidden = true
    }

    private func layoutForElement() {
        guard let e = element else { return }
        let f = CGRect(x: e.frame.minX * zoom, y: e.frame.minY * zoom, width: e.frame.width * zoom, height: e.frame.height * zoom)
        frame = f.insetBy(dx: -14, dy: -14)
        let inner = CGRect(x: 14, y: 14, width: f.width, height: f.height)
        border.path = UIBezierPath(roundedRect: inner, cornerRadius: 3).cgPath
        textView.frame = inner.insetBy(dx: 6 * zoom, dy: 6 * zoom)
        handle.frame = CGRect(x: inner.maxX - 7, y: inner.maxY - 7, width: 14, height: 14)
        deleteButton.frame = CGRect(x: inner.minX - 11, y: inner.minY - 11, width: 22, height: 22)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only the element itself and its controls take touches; the margin stays pass-through.
        let inner = bounds.insetBy(dx: 14, dy: 14)
        return inner.contains(point) || handle.frame.insetBy(dx: -12, dy: -12).contains(point)
            || deleteButton.frame.insetBy(dx: -10, dy: -10).contains(point)
    }

    @objc private func handleMove(_ g: UIPanGestureRecognizer) {
        guard var e = element else { return }
        if textView.isFirstResponder { return }
        switch g.state {
        case .began:
            dragStartFrame = e.frame
        case .changed, .ended:
            let t = g.translation(in: superview)
            e.frame.origin = CGPoint(x: dragStartFrame.minX + t.x / zoom, y: dragStartFrame.minY + t.y / zoom)
            element = e
            layoutForElement()
            onMove?(e.frame, g.state == .ended)
        default:
            break
        }
    }

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard var e = element else { return }
        switch g.state {
        case .began:
            dragStartFrame = e.frame
        case .changed, .ended:
            let t = g.translation(in: superview)
            var w = max(40, dragStartFrame.width + t.x / zoom)
            var h: CGFloat
            if e.kind == .image {
                let aspect = dragStartFrame.height / max(dragStartFrame.width, 1)
                h = w * aspect
            } else {
                w = max(80, w)
                h = ElementSnapshot.textHeight(e.text, width: w, font: e.font())
            }
            h = max(h, 20)
            e.frame.size = CGSize(width: w, height: h)
            element = e
            layoutForElement()
            onMove?(e.frame, g.state == .ended)
        default:
            break
        }
    }

    // MARK: Text editing

    func textViewDidChange(_ textView: UITextView) {
        guard var e = element else { return }
        e.text = textView.text
        let h = ElementSnapshot.textHeight(e.text, width: e.frame.width, font: e.font())
        e.frame.size.height = h
        element = e
        layoutForElement()
        onTextChange?(e.text, h)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onEndEditing?(textView.text)
    }
}
