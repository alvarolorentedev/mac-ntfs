import SwiftUI

@main
struct MacNTFSApp: App {
    @StateObject private var model = AppModel()

    init() {
        CLI.handle(arguments: CommandLine.arguments)
    }

    var body: some Scene {
        MenuBarExtra("MacNTFS", systemImage: "externaldrive") {
            MenuView(model: model)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
