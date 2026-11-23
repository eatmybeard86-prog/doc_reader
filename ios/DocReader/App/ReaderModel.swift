import SwiftUI
import UIKit

/// Стан застосунку: відкритий документ, тема, масштаб, режим редагування.
@MainActor
final class ReaderModel: ObservableObject {
    @Published private(set) var doc: ReaderDocument?
    @Published var theme: ReaderTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var tintPhotos: Bool {
        didSet { defaults.set(tintPhotos, forKey: Keys.tintPhotos) }
    }
    /// Масштаб шрифту для текстових документів.
    @Published var textZoom: CGFloat = 1
    @Published private(set) var loading = false
    @Published private(set) var editing = false
    @Published var error: ErrorInfo?
    @Published var toast: String?
    @Published var pageLabel: String?
    @Published var showThemePicker = false
    @Published var showFileImporter = false
    @Published var showPhotoPicker = false

    struct ErrorInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    weak var pagedView: PagedView?
    weak var textReader: TextReader?
    private var editorDirty = false
    private var toastTask: Task<Void, Never>?
    private var labelTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let theme = "theme"
        static let tintPhotos = "tint_photos"
        static let last = "last_dir"
    }

    init() {
        theme = ReaderTheme.named(UserDefaults.standard.string(forKey: Keys.theme))
        tintPhotos = UserDefaults.standard.object(forKey: Keys.tintPhotos) as? Bool ?? true
    }

    // MARK: відкриття

    /// Відкриває останній документ після запуску.
    func restoreLast() {
        guard doc == nil, !loading else { return }
        guard let name = defaults.string(forKey: Keys.last) else {
            DocumentLoader.cleanup(keep: nil)
            return
        }
        let dir = DocumentLoader.root.appendingPathComponent(name, isDirectory: true)
        DocumentLoader.cleanup(keep: dir)
        load(silent: true) { try DocumentLoader.load(directory: dir) }
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        load(silent: false) { try DocumentLoader.open(urls: urls) }
    }

    private func load(silent: Bool, _ work: @escaping () throws -> ReaderDocument) {
        loadTask?.cancel()
        if editing { leaveEditing() }
        savePosition()
        loading = true
        loadTask = Task {
            let result: Result<ReaderDocument, Error> = await Task.detached(priority: .userInitiated) {
                Result { try work() }
            }.value
            loading = false
            switch result {
            case .success(let newDoc):
                if Task.isCancelled { newDoc.deleteFiles(); return }
                setDocument(newDoc)
            case .failure(let e):
                if silent {
                    defaults.removeObject(forKey: Keys.last)
                } else {
                    let msg = (e as? DocError)?.message ?? "Не вдалося відкрити файл.\n\n\(e.localizedDescription)"
                    error = ErrorInfo(title: "Не вдалося відкрити", message: msg)
                }
            }
        }
    }

    private func setDocument(_ newDoc: ReaderDocument) {
        let old = doc
        textZoom = 1
        if !newDoc.paged, let saved = savedPosition(newDoc), saved.count >= 2, let z = Double(saved[1]) {
            textZoom = clampTextZoom(CGFloat(z))
        }
        doc = newDoc
        pageLabel = nil
        defaults.set(newDoc.directory.lastPathComponent, forKey: Keys.last)
        if let old = old, old.directory != newDoc.directory { old.deleteFiles() }
    }

    func closeDocument() {
        if editing { leaveEditing() }
        savePosition()
        guard let d = doc else { return }
        doc = nil
        pageLabel = nil
        defaults.removeObject(forKey: Keys.last)
        d.deleteFiles()
    }

    // MARK: позиція читання

    private func savedPosition(_ d: ReaderDocument) -> [String]? {
        defaults.string(forKey: d.positionKey)?.components(separatedBy: ",")
    }

    func savePosition() {
        guard let d = doc else { return }
        if d.paged, let v = pagedView, v.document === d {
            let p = v.currentPosition()
            defaults.set("\(p.page),\(p.fraction),\(p.zoom)", forKey: d.positionKey)
        } else if let t = textReader, t.document === d, !t.editing {
            defaults.set("\(t.topCharacterIndex()),\(textZoom)", forKey: d.positionKey)
        }
    }

    /// Викликається, коли перегляд документа створено – відновлює місце читання.
    func attach(paged v: PagedView) {
        pagedView = v
        v.onPageChange = { [weak self] page in
            guard let self = self, let d = self.doc else { return }
            self.showLabel("\(page + 1) / \(d.pageCount)")
        }
        if let s = savedPosition(v.document), s.count >= 3,
           let page = Int(s[0]), let frac = Double(s[1]), let z = Double(s[2]) {
            v.restore(page: page, fraction: CGFloat(frac), zoom: CGFloat(z))
        }
    }

    func attach(text t: TextReader) {
        textReader = t
        t.onScrollPercent = { [weak self] pct in self?.showLabel("\(pct)%") }
        t.onEdited = { [weak self] in self?.editorDirty = true }
        t.onPinch = { [weak self] scale in
            guard let self = self else { return }
            self.textZoom = self.clampTextZoom(self.textZoom * scale)
        }
        if let s = savedPosition(t.document), let c = Int(s[0]) {
            t.restore(character: c)
        }
    }

    private func showLabel(_ text: String) {
        pageLabel = text
        labelTask?.cancel()
        labelTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { pageLabel = nil }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: масштаб

    private func clampTextZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.6), 3) }

    func zoomIn() {
        guard let d = doc else { return }
        if d.paged { pagedView?.zoom(by: 1.25) } else { textZoom = clampTextZoom(textZoom * 1.25) }
    }

    func zoomOut() {
        guard let d = doc else { return }
        if d.paged { pagedView?.zoom(by: 1 / 1.25) } else { textZoom = clampTextZoom(textZoom / 1.25) }
    }

    func resetZoom() {
        guard let d = doc else { return }
        if d.paged { pagedView?.resetZoom() } else { textZoom = 1 }
    }

    func goToPage() {
        guard let d = doc, d.paged else { return }
        Presenter.askNumber(title: "Перейти до сторінки", placeholder: "1 – \(d.pageCount)") { [weak self] n in
            self?.pagedView?.goTo(page: n - 1)
        }
    }

    // MARK: редагування (лише Word: DOC, DOCX, RTF)

    func startEditing() {
        guard let d = doc, !d.paged, let t = textReader else { return }
        editing = true
        editorDirty = false
        t.startEditing()
        let hasImages = d.blocks.contains { if case .image = $0 { return true } else { return false } }
        showToast(hasImages
            ? "Редагування: виділіть текст і натисніть Ж / К / П. Картинки в новому файлі не збережуться."
            : "Редагування: виділіть текст і натисніть Ж / К / П, щоб змінити стиль.")
    }

    func toggleStyle(_ kind: TextReader.StyleKind) {
        guard let t = textReader else { return }
        if !t.toggle(kind) { showToast("Спочатку виділіть текст") }
    }

    /// Зберігає відредагований текст у новий DOCX і відкриває його.
    func saveDocx() {
        guard let d = doc, let t = textReader, editing else { return }
        let paragraphs = t.editedParagraphs()
        let base = ((d.sources.first?.name ?? d.title) as NSString).deletingPathExtension
        let url = DocumentLoader.exportDir().appendingPathComponent("\(base.isEmpty ? "Документ" : base) (ред.).docx")
        do {
            try DocxWriter.write(paragraphs).write(to: url)
        } catch {
            self.error = ErrorInfo(title: "Помилка збереження", message: "Не вдалося зберегти: \(error.localizedDescription)")
            return
        }
        Presenter.exportFile(url) { [weak self] saved in
            guard let self = self, saved else { return }
            self.editorDirty = false
            self.leaveEditing()
            self.showToast("Збережено. Відкриваю новий файл.")
            self.open(urls: [url])
        }
    }

    /// Вихід з редагування з питанням про незбережені зміни.
    func exitEditing() {
        guard editing else { return }
        if !editorDirty { leaveEditing(); return }
        Presenter.confirm(title: "Зміни не збережено", message: "Зберегти зміни в новий файл?",
                          save: { [weak self] in self?.saveDocx() },
                          discard: { [weak self] in self?.leaveEditing() })
    }

    private func leaveEditing() {
        editing = false
        editorDirty = false
        textReader?.stopEditing()
    }

    // MARK: поділитися, друк, PDF

    func share(asPdf: Bool) {
        guard let d = doc else { return }
        if !asPdf {
            Presenter.share(d.sources.map(\.url))
            return
        }
        makePdf(d) { url in Presenter.share([url]) }
    }

    func exportPdf() {
        guard let d = doc else { return }
        makePdf(d) { [weak self] url in
            Presenter.exportFile(url) { saved in
                if saved { self?.showToast("Збережено PDF") }
            }
        }
    }

    func printDocument() {
        guard let d = doc else { return }
        if d.kind == .pdf, let src = d.sources.first {
            Presenter.print(src.url, title: d.title)
            return
        }
        makePdf(d) { url in Presenter.print(url, title: d.title) }
    }

    private func makePdf(_ d: ReaderDocument, then: @escaping (URL) -> Void) {
        loading = true
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result { try PdfExport.export(d) }
            }.value
            loading = false
            switch result {
            case .success(let url): then(url)
            case .failure(let e):
                error = ErrorInfo(title: "Помилка", message: "Не вдалося створити PDF: \(e.localizedDescription)")
            }
        }
    }
}
