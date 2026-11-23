import UIKit

/// Показ і редагування текстових документів (DOC, DOCX, RTF).
final class TextReader: UIView, UITextViewDelegate {
    enum StyleKind { case bold, italic, underline }

    let document: ReaderDocument
    let textView: UITextView
    private let layoutManager = NSLayoutManager()
    private let storage = NSTextStorage()

    var onScrollPercent: ((Int) -> Void)?
    var onEdited: (() -> Void)?
    var onPinch: ((CGFloat) -> Void)?

    /// Основний розмір шрифту, pt (без масштабу).
    static let baseFontSize: CGFloat = 17

    private var theme: ReaderTheme?
    private var zoom: CGFloat = 0
    private(set) var editing = false
    private var recolored: [String: UIImage] = [:]
    private var pendingChar: Int?

    init(document: ReaderDocument) {
        self.document = document
        // TextKit 1 – передбачувана розкладка вбудованих зображень на всіх версіях iOS
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = UITextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 48, right: 14)
        textView.delegate = self
        textView.dataDetectorTypes = []
        textView.autocorrectionType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinchGesture(_:)))
        textView.addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: оформлення

    func apply(theme: ReaderTheme, zoom: CGFloat) {
        guard !editing else { return }
        guard theme != self.theme || abs(zoom - self.zoom) > 0.001 else { return }
        let keep = self.theme == nil ? pendingChar : topCharacterIndex()
        self.theme = theme
        self.zoom = zoom
        backgroundColor = theme.page
        textView.backgroundColor = theme.page
        textView.tintColor = theme.isDark ? UIColor(hex: 0x64A8FF) : UIColor.systemBlue
        textView.indicatorStyle = theme.isDark ? .white : .black
        textView.keyboardAppearance = theme.isDark ? .dark : .light
        let text = RichText.attributed(document.blocks, images: document.images,
                                       style: .init(fontSize: TextReader.baseFontSize * zoom, ink: theme.ink, imageTheme: theme),
                                       recolored: &recolored)
        textView.attributedText = text
        if let c = keep { scheduleScroll(toCharacter: c) }
    }

    // MARK: позиція

    func topCharacterIndex() -> Int {
        let inset = textView.textContainerInset
        let point = CGPoint(x: 4, y: max(0, textView.contentOffset.y - inset.top + 2))
        let glyph = layoutManager.glyphIndex(for: point, in: textView.textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    func restore(character: Int) {
        if theme == nil { pendingChar = character } else { scheduleScroll(toCharacter: character) }
    }

    private func scheduleScroll(toCharacter c: Int) {
        // чекаємо, поки текст отримає розміри
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bounds.width > 0 else { return }
            self.scroll(toCharacter: c)
        }
    }

    private func scroll(toCharacter c: Int) {
        let length = storage.length
        guard length > 0, c > 0 else { textView.contentOffset = .zero; return }
        let ch = min(c, length - 1)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: ch + 1))
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: ch, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        let maxY = max(0, textView.contentSize.height - textView.bounds.height)
        textView.contentOffset = CGPoint(x: 0, y: min(max(0, rect.minY + textView.textContainerInset.top), maxY))
    }

    func scrollPercent() -> Int {
        let maxY = textView.contentSize.height - textView.bounds.height
        guard maxY > 1 else { return 100 }
        return Int(min(max(textView.contentOffset.y / maxY, 0), 1) * 100)
    }

    // MARK: редагування

    func startEditing() {
        editing = true
        textView.isEditable = true
        textView.allowsEditingTextAttributes = true
        let font = RichText.font(size: TextReader.baseFontSize * zoom, bold: false, italic: false, mono: false)
        textView.typingAttributes = [.font: font, .foregroundColor: theme?.ink ?? UIColor.label]
        textView.becomeFirstResponder()
    }

    /// Вихід з редагування без збереження – повертає початковий текст.
    func stopEditing() {
        editing = false
        textView.resignFirstResponder()
        textView.isEditable = false
        textView.allowsEditingTextAttributes = false
        let t = theme
        theme = nil
        if let t = t { apply(theme: t, zoom: zoom) }
    }

    /// Абзаци відредагованого тексту для збереження в DOCX.
    func editedParagraphs() -> [TextParagraph] {
        RichText.paragraphs(from: textView.attributedText, baseSize: TextReader.baseFontSize * zoom)
    }

    /// Вмикає/вимикає стиль для виділеного тексту. Повертає false, якщо нічого не виділено.
    func toggle(_ kind: StyleKind) -> Bool {
        let r = textView.selectedRange
        guard r.length > 0 else { return false }
        let ts = textView.textStorage
        switch kind {
        case .bold, .italic:
            let trait: UIFontDescriptor.SymbolicTraits = kind == .bold ? .traitBold : .traitItalic
            var runs: [(NSRange, UIFont)] = []
            ts.enumerateAttribute(.font, in: r, options: []) { v, sub, _ in
                if let f = v as? UIFont { runs.append((sub, f)) }
            }
            let all = !runs.isEmpty && runs.allSatisfy { $0.1.fontDescriptor.symbolicTraits.contains(trait) }
            ts.beginEditing()
            for (sub, f) in runs {
                var traits = f.fontDescriptor.symbolicTraits
                if all { traits.remove(trait) } else { traits.insert(trait) }
                if let d = f.fontDescriptor.withSymbolicTraits(traits) {
                    ts.addAttribute(.font, value: UIFont(descriptor: d, size: f.pointSize), range: sub)
                }
            }
            ts.endEditing()
        case .underline:
            var all = true
            ts.enumerateAttribute(.underlineStyle, in: r, options: []) { v, _, _ in
                if ((v as? Int) ?? 0) == 0 { all = false }
            }
            if all {
                ts.removeAttribute(.underlineStyle, range: r)
            } else {
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }
        }
        textView.selectedRange = r
        onEdited?()
        return true
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        if editing { onEdited?() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !editing { onScrollPercent?(scrollPercent()) }
    }

    @objc private func onPinchGesture(_ g: UIPinchGestureRecognizer) {
        guard !editing else { return }
        if g.state == .ended { onPinch?(g.scale) }
    }
}
