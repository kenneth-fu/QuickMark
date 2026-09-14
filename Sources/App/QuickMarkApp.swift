import SwiftUI

@main
struct QuickMarkApp: App {
    var body: some Scene {
        Window("QuickMark", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
