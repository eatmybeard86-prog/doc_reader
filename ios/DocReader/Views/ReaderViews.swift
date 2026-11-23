import SwiftUI

/// SwiftUI-обгортка для перегляду PDF і фото.
struct PagedReaderView: UIViewRepresentable {
    let document: ReaderDocument
    @ObservedObject var model: ReaderModel

    func makeUIView(context: Context) -> PagedView {
        let v = PagedView(document: document)
        v.apply(theme: model.theme, tintPhotos: model.tintPhotos)
        model.attach(paged: v)
        return v
    }

    func updateUIView(_ v: PagedView, context: Context) {
        v.apply(theme: model.theme, tintPhotos: model.tintPhotos)
    }
}

/// SwiftUI-обгортка для текстових документів.
struct TextReaderView: UIViewRepresentable {
    let document: ReaderDocument
    @ObservedObject var model: ReaderModel

    func makeUIView(context: Context) -> TextReader {
        let v = TextReader(document: document)
        model.attach(text: v)
        v.apply(theme: model.theme, zoom: model.textZoom)
        return v
    }

    func updateUIView(_ v: TextReader, context: Context) {
        v.apply(theme: model.theme, zoom: model.textZoom)
    }
}
