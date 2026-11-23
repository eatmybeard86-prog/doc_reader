import SwiftUI

@main
struct DocReaderApp: App {
    @StateObject private var model = ReaderModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // файл, відкритий з інших застосунків («Відкрити в…», «Поділитися», «Файли»)
                .onOpenURL { url in
                    started = true
                    model.open(urls: [url])
                }
                .onAppear {
                    guard !started else { return }
                    started = true
                    // даємо шанс onOpenURL спрацювати першим
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if model.doc == nil { model.restoreLast() }
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.savePosition() }
        }
    }
}
