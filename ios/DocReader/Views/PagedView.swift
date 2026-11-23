import UIKit

/// Перегляд растрових сторінок (PDF, фото): вертикальна прокрутка, масштаб щипком і подвійним дотиком.
final class PagedView: UIScrollView, UIScrollViewDelegate {
    let document: ReaderDocument
    var onPageChange: ((Int) -> Void)?

    private let content = UIView()
    private var pageViews: [UIImageView] = []
    private var pageFrames: [CGRect] = []
    private var laidOutWidth: CGFloat = 0
    private let gap: CGFloat = 6

    private var theme: ReaderTheme = .day
    private var tintPhotos = true
    /// Ключ рендеру, який очікує кожна сторінка.
    private var wanted: [Int: String] = [:]
    private var shown: [Int: String] = [:]
    private let cache = NSCache<NSString, UIImage>()
    private var pendingPosition: (page: Int, fraction: CGFloat, zoom: CGFloat)?

    private static let renderQueue = DispatchQueue(label: "ua.docreader.render", qos: .userInitiated)

    init(document: ReaderDocument) {
        self.document = document
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        cache.totalCostLimit = 200 * 1024 * 1024
        addSubview(content)
        for _ in 0..<document.pageCount {
            let v = UIImageView()
            v.contentMode = .scaleToFill
            v.clipsToBounds = true
            content.addSubview(v)
            pageViews.append(v)
        }
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: тема

    func apply(theme: ReaderTheme, tintPhotos: Bool) {
        guard theme != self.theme || tintPhotos != self.tintPhotos else { return }
        self.theme = theme
        self.tintPhotos = tintPhotos
        backgroundColor = theme.outer
        for v in pageViews { v.backgroundColor = theme.page }
        wanted.removeAll()
        loadVisible()
    }

    private var recolorTheme: ReaderTheme? {
        if document.isPhoto && !tintPhotos { return nil }
        return theme.recolor ? theme : nil
    }

    // MARK: розкладка

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && abs(bounds.width - laidOutWidth) > 0.5 {
            relayout()
        }
        loadVisible()
    }

    private func relayout() {
        let restore = pendingPosition ?? (laidOutWidth > 0 ? currentPosition() : nil)
        pendingPosition = nil
        let w = bounds.width
        laidOutWidth = w
        let z = zoomScale
        zoomScale = 1
        var y: CGFloat = 0
        pageFrames = document.pageSizes.map { size in
            let h = max(1, (w * size.height / size.width).rounded())
            let r = CGRect(x: 0, y: y, width: w, height: h)
            y += h + gap
            return r
        }
        let height = max(0, y - gap)
        content.frame = CGRect(x: 0, y: 0, width: w, height: height)
        for (i, v) in pageViews.enumerated() { v.frame = pageFrames[i] }
        contentSize = content.frame.size
        if let p = restore {
            setZoomScale(p.zoom, animated: false)
            scrollTo(page: p.page, fraction: p.fraction)
        } else {
            setZoomScale(z, animated: false)
        }
    }

    // MARK: позиція

    func currentPage() -> Int {
        guard !pageFrames.isEmpty else { return 0 }
        let mid = (contentOffset.y + bounds.height / 2) / zoomScale
        for (i, f) in pageFrames.enumerated() where f.maxY + gap >= mid { return i }
        return pageFrames.count - 1
    }

    func currentPosition() -> (page: Int, fraction: CGFloat, zoom: CGFloat) {
        guard !pageFrames.isEmpty else { return (0, 0, zoomScale) }
        let top = contentOffset.y / zoomScale
        var page = pageFrames.count - 1
        for (i, f) in pageFrames.enumerated() where f.maxY + gap > top { page = i; break }
        let f = pageFrames[page]
        let fraction = min(max((top - f.minY) / f.height, 0), 1)
        return (page, fraction, zoomScale)
    }

    func restore(page: Int, fraction: CGFloat, zoom: CGFloat) {
        if laidOutWidth == 0 {
            pendingPosition = (page, fraction, zoom)
            return
        }
        setZoomScale(zoom, animated: false)
        scrollTo(page: page, fraction: fraction)
    }

    func goTo(page: Int) {
        scrollTo(page: page, fraction: 0)
        loadVisible()
    }

    private func scrollTo(page: Int, fraction: CGFloat) {
        guard !pageFrames.isEmpty else { return }
        let p = min(max(page, 0), pageFrames.count - 1)
        let f = pageFrames[p]
        let y = (f.minY + f.height * fraction) * zoomScale
        let maxY = max(0, contentSize.height - bounds.height)
        contentOffset = CGPoint(x: contentOffset.x, y: min(max(0, y), maxY))
    }

    func zoom(by factor: CGFloat) {
        let target = min(max(zoomScale * factor, minimumZoomScale), maximumZoomScale)
        let center = CGPoint(x: (contentOffset.x + bounds.width / 2) / zoomScale, y: contentOffset.y / zoomScale)
        zoom(to: target, focus: center, topAnchored: true)
    }

    func resetZoom() {
        setZoomScale(1, animated: true)
    }

    private func zoom(to scale: CGFloat, focus: CGPoint, topAnchored: Bool = false) {
        let w = bounds.width / scale
        let h = bounds.height / scale
        let y = topAnchored ? focus.y : focus.y - h / 2
        zoom(to: CGRect(x: focus.x - w / 2, y: y, width: w, height: h), animated: true)
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.05 {
            setZoomScale(1, animated: true)
        } else {
            zoom(to: 2.5, focus: g.location(in: content))
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        loadVisible()
        if pageFrames.count > 1 { onPageChange?(currentPage()) }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        wanted.removeAll()
        loadVisible()
    }

    // MARK: рендер

    private func renderWidth() -> CGFloat {
        // рендеримо з запасом під масштаб, але квантуємо, щоб не перерендерювати на кожному кадрі щипка
        let factor = max(1, ceil(min(zoomScale, 3)))
        let px = laidOutWidth * factor * UIScreen.main.scale
        return min(max(px, 200), 3000).rounded()
    }

    private func loadVisible() {
        guard laidOutWidth > 0, !pageFrames.isEmpty else { return }
        let z = zoomScale
        let visible = CGRect(x: 0, y: contentOffset.y / z, width: laidOutWidth, height: bounds.height / z)
        let near = visible.insetBy(dx: 0, dy: -visible.height)
        let keep = visible.insetBy(dx: 0, dy: -visible.height * 4)
        let width = renderWidth()
        let recolor = recolorTheme
        for (i, f) in pageFrames.enumerated() {
            if f.intersects(near) {
                let key = "\(i)@\(Int(width))|\(recolor?.rawValue ?? "orig")" as NSString
                if shown[i] == key as String { continue }
                if let img = cache.object(forKey: key) {
                    pageViews[i].image = img
                    shown[i] = key as String
                    wanted[i] = key as String
                    continue
                }
                if wanted[i] == key as String { continue }
                wanted[i] = key as String
                request(page: i, key: key, width: width, recolor: recolor)
            } else if !f.intersects(keep), pageViews[i].image != nil {
                pageViews[i].image = nil
                shown[i] = nil
                wanted[i] = nil
            }
        }
    }

    private func request(page i: Int, key: NSString, width: CGFloat, recolor: ReaderTheme?) {
        let doc = document
        PagedView.renderQueue.async { [weak self] in
            // сторінка могла вже зникнути з екрана
            let stillWanted = DispatchQueue.main.sync { self?.wanted[i] == key as String }
            guard stillWanted else { return }
            var image = autoreleasepool { doc.renderPage(i, width: width) }
            if let img = image, let theme = recolor {
                image = autoreleasepool { Recolor.apply(img, theme: theme) }
            }
            DispatchQueue.main.async {
                guard let self = self, let img = image else { return }
                let cost = Int(img.size.width * img.size.height * 4)
                self.cache.setObject(img, forKey: key, cost: cost)
                if self.wanted[i] == key as String {
                    self.pageViews[i].image = img
                    self.shown[i] = key as String
                }
            }
        }
    }
}
