import SwiftUI
import SwiftData

@main
struct RegistratoreAIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Recording.self, Summary.self, CustomTemplate.self])
    }
}
