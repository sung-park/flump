import SwiftUI

@main
struct FlumpApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        Window("Flump", id: "main") {
            ContentView()
                .environmentObject(library)
                .tint(Color(red: 0.36, green: 0.42, blue: 0.98))
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 820, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
