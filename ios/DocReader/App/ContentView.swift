import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: ReaderModel

    private var theme: ReaderTheme { model.theme }

    static let openTypes: [UTType] = {
        var types: [UTType] = [.pdf, .rtf, .image, .jpeg, .png]
        for id in ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "public.heic"] {
            if let t = UTType(id) { types.append(t) }
        }
        // деякі месенджери зберігають файли без правильного типу – дозволяємо будь-які дані
        types.append(.data)
        return types
    }()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            ZStack {
                Color(theme.page)
                if let doc = model.doc {
                    if doc.paged {
                        PagedReaderView(document: doc, model: model).id(doc.id)
                    } else {
                        TextReaderView(document: doc, model: model).id(doc.id)
                    }
                } else {
                    EmptyStateView(model: model)
                }
                overlays
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Color(theme.bar).ignoresSafeArea())
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $model.showThemePicker) {
            ThemePicker(model: model)
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: ContentView.openTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.open(urls: urls) }
        }
        .alert(item: $model.error) { e in
            Alert(title: Text(e.title), message: Text(e.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder private var overlays: some View {
        if model.loading {
            ProgressView()
                .scaleEffect(1.6)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(theme.bar).opacity(0.9)))
                .tint(Color(theme.barText))
        }
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.8)))
                        .onTapGesture { model.toast = nil }
                }
                Spacer()
                if let label = model.pageLabel {
                    Text(label)
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.67)))
                }
            }
            .padding(16)
            .padding(.bottom, 20)
            .animation(.easeInOut(duration: 0.25), value: model.pageLabel)
            .animation(.easeInOut(duration: 0.25), value: model.toast)
        }
        .allowsHitTesting(model.toast != nil)
    }
}

/// Верхня панель з назвою документа та кнопками.
struct TopBar: View {
    @ObservedObject var model: ReaderModel

    private var theme: ReaderTheme { model.theme }
    private var fg: Color { Color(theme.barText) }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.doc?.title ?? "Читалка")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = subtitle {
                    Text(sub).font(.caption).opacity(0.7)
                }
            }
            Spacer(minLength: 4)
            if model.editing {
                editButtons
            } else {
                mainButtons
            }
        }
        .foregroundColor(fg)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(theme.bar))
        .overlay(Rectangle().fill(Color(theme.outer)).frame(height: 0.5), alignment: .bottom)
    }

    private var subtitle: String? {
        if model.editing { return "Редагування" }
        guard let d = model.doc, d.paged, d.pageCount > 1 else { return nil }
        return "\(d.pageCount) стор."
    }

    private var editButtons: some View {
        HStack(spacing: 16) {
            Button { model.toggleStyle(.bold) } label: { Text("Ж").font(.system(size: 18, weight: .bold)) }
            Button { model.toggleStyle(.italic) } label: { Text("К").font(.system(size: 18).italic()) }
            Button { model.toggleStyle(.underline) } label: { Text("П").font(.system(size: 18)).underline() }
            Button("Зберегти") { model.saveDocx() }.font(.body.weight(.semibold))
            Button { model.exitEditing() } label: { Image(systemName: "xmark.circle") }
                .accessibilityLabel("Вийти з редагування")
        }
    }

    private var mainButtons: some View {
        HStack(spacing: 18) {
            Menu {
                Button { model.showFileImporter = true } label: { Label("Файл…", systemImage: "folder") }
                Button {
                    Presenter.pickPhotos { urls in model.open(urls: urls) }
                } label: { Label("Фото з галереї…", systemImage: "photo.on.rectangle") }
            } label: {
                Image(systemName: "folder").font(.system(size: 19))
            }
            .accessibilityLabel("Відкрити")

            Button { model.showThemePicker = true } label: {
                Image(systemName: "paintpalette").font(.system(size: 19))
            }
            .accessibilityLabel("Колір сторінки")

            if let d = model.doc {
                Menu {
                    documentMenu(d)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19))
                }
                .accessibilityLabel("Ще")
            }
        }
    }

    @ViewBuilder private func documentMenu(_ d: ReaderDocument) -> some View {
        Section {
            Button { model.zoomIn() } label: { Label(d.paged ? "Збільшити" : "Більший шрифт", systemImage: "plus.magnifyingglass") }
            Button { model.zoomOut() } label: { Label(d.paged ? "Зменшити" : "Менший шрифт", systemImage: "minus.magnifyingglass") }
            Button { model.resetZoom() } label: { Label("Звичайний масштаб", systemImage: "1.magnifyingglass") }
            if d.paged && d.pageCount > 1 {
                Button { model.goToPage() } label: { Label("Перейти до сторінки…", systemImage: "arrow.down.to.line") }
            }
            if d.isPhoto {
                Toggle(isOn: $model.tintPhotos) { Label("Застосовувати колір до фото", systemImage: "camera.filters") }
            }
        }
        Section {
            // редагування лише для документів Word (DOC/DOCX/RTF)
            if !d.paged {
                Button { model.startEditing() } label: { Label("Редагувати", systemImage: "pencil") }
            }
            if d.kind != .pdf {
                Button { model.exportPdf() } label: { Label("Зберегти як PDF…", systemImage: "arrow.down.doc") }
            }
            Button { model.share(asPdf: false) } label: { Label("Поділитися…", systemImage: "square.and.arrow.up") }
            if d.kind != .pdf {
                Button { model.share(asPdf: true) } label: { Label("Поділитися як PDF…", systemImage: "doc.richtext") }
            }
            Button { model.printDocument() } label: { Label("Друк…", systemImage: "printer") }
        }
        Section {
            Button(role: .destructive) { model.closeDocument() } label: { Label("Закрити документ", systemImage: "xmark") }
        }
    }
}

/// Екран без документа.
struct EmptyStateView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 24) {
            Text("Відкрийте документ для читання\n\nPDF · DOC · DOCX · RTF · JPG · PNG\n\nМожна вибрати кілька фото одразу – вони відкриються як сторінки.")
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(theme.ink))
            VStack(spacing: 12) {
                Button { model.showFileImporter = true } label: {
                    Label("Відкрити файл", systemImage: "folder").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Presenter.pickPhotos { urls in model.open(urls: urls) }
                } label: {
                    Label("Вибрати фото", systemImage: "photo.on.rectangle").frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(32)
    }
}

/// Вибір кольору сторінки.
struct ThemePicker: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ReaderTheme.allCases) { t in
                        Button {
                            model.theme = t
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark").opacity(t == model.theme ? 1 : 0)
                                Text(t.title).font(.system(size: 17, design: .serif))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .foregroundColor(Color(t.ink))
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(t.page)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(t.outer), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Колір сторінки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
