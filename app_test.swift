import SwiftUI

@main
struct TestApp: App {
    var body: some Scene {
        MenuBarExtra("Test", systemImage: "music.note") {
            VStack {
                Text("Hello from MenuBarExtra").padding()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.padding()
        }
    }
}
