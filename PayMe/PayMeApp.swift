import SwiftUI
import SwiftData

@main
struct PayMeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(PayMeTheme.coral)
        }
        .modelContainer(for: [Receipt.self, ReceiptItem.self, Participant.self])
    }
}
