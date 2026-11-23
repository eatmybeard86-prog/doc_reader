import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Системні вікна UIKit: «Поділитися», збереження файлу, друк, діалоги.
@MainActor
enum Presenter {
    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.compactMap { $0.keyWindow }.first ?? scenes.flatMap(\.windows).first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    private static func anchor(_ vc: UIViewController, on host: UIViewController) {
        if let pop = vc.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.maxX - 40, y: host.view.safeAreaInsets.top + 20, width: 1, height: 1)
            pop.permittedArrowDirections = [.up]
        }
    }

    static func share(_ urls: [URL]) {
        guard let host = top(), !urls.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        anchor(vc, on: host)
        host.present(vc, animated: true)
    }

    private static var exportDelegate: ExportDelegate?

    /// Збереження файлу в «Файли» (вибір місця користувачем).
    static func exportFile(_ url: URL, done: @escaping (Bool) -> Void) {
        guard let host = top() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = ExportDelegate { ok in
            exportDelegate = nil
            done(ok)
        }
        exportDelegate = delegate
        picker.delegate = delegate
        host.present(picker, animated: true)
    }

    static func print(_ url: URL, title: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info
        pc.printingItem = url
        if UIDevice.current.userInterfaceIdiom == .pad, let host = top() {
            let rect = CGRect(x: host.view.bounds.maxX - 40, y: host.view.safeAreaInsets.top + 20, width: 1, height: 1)
            pc.present(from: rect, in: host.view, animated: true)
        } else {
            pc.present(animated: true)
        }
    }

    static func askNumber(title: String, placeholder: String, done: @escaping (Int) -> Void) {
        guard let host = top() else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.placeholder = placeholder
        }
        alert.addAction(UIAlertAction(title: "Скасувати", style: .cancel))
        alert.addAction(UIAlertAction(title: "Перейти", style: .default) { _ in
            if let t = alert.textFields?.first?.text, let n = Int(t.trimmingCharacters(in: .whitespaces)) { done(n) }
        })
        host.present(alert, animated: true)
    }

    static func confirm(title: String, message: String, save: @escaping () -> Void, discard: @escaping () -> Void) {
        guard let host = top() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Зберегти", style: .default) { _ in save() })
        alert.addAction(UIAlertAction(title: "Не зберігати", style: .destructive) { _ in discard() })
        alert.addAction(UIAlertAction(title: "Скасувати", style: .cancel))
        host.present(alert, animated: true)
    }

    // MARK: вибір фото

    private static var photoDelegate: PhotoDelegate?

    /// Вибір одного або кількох фото з галереї. Фото копіюються в тимчасову теку.
    static func pickPhotos(done: @escaping ([URL]) -> Void) {
        guard let host = top() else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        let delegate = PhotoDelegate { urls in
            photoDelegate = nil
            done(urls)
        }
        photoDelegate = delegate
        picker.delegate = delegate
        host.present(picker, animated: true)
    }
}

private final class ExportDelegate: NSObject, UIDocumentPickerDelegate {
    let done: (Bool) -> Void
    init(done: @escaping (Bool) -> Void) { self.done = done }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        done(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        done(false)
    }
}

private final class PhotoDelegate: NSObject, PHPickerViewControllerDelegate {
    let done: ([URL]) -> Void
    init(done: @escaping ([URL]) -> Void) { self.done = done }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        if results.isEmpty { done([]); return }
        let dir = DocumentLoader.exportDir()
        var urls = [URL?](repeating: nil, count: results.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, r) in results.enumerated() {
            let provider = r.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                // тимчасовий файл видаляється після виходу з обробника – копіюємо
                let sub = dir.appendingPathComponent("\(i)", isDirectory: true)
                try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                let dest = sub.appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    lock.lock(); urls[i] = dest; lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [done] in
            done(urls.compactMap { $0 })
        }
    }
}
