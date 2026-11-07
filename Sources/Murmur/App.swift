import AppKit
import SwiftUI

@main
@MainActor struct MurmurApp: App {
    @State private var model = AppModel()

    init() {
        Prefs.register()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .onAppear { Task { if !model.llmReady { await model.refreshLLM() } } }
        } label: {
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform")
                .task { if !started { started = true; model.start() } }
        }
        .menuBarExtraStyle(.window)

        Window("Murmur History", id: "history") { HistoryView(model: model) }
            .defaultSize(width: 760, height: 520)

        Window("Murmur Settings", id: "settings") { SettingsView(model: model) }
            .windowResizability(.contentSize)
    }

    @State private var started = false
}
