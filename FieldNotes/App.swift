import CoreData
import SwiftUI

@main struct MyApp: App {
    let persistenceController = PersistenceController()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .font(AppFont.body)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

enum AppFont {
    static let body = Font.custom("HackNFP-Regular", size: 17, relativeTo: .body)
    static let headline = Font.custom("HackNFP-Bold", size: 17, relativeTo: .headline)
    static let caption = Font.custom("HackNFP-Regular", size: 12, relativeTo: .caption)
    static let caption2 = Font.custom("HackNFP-Regular", size: 11, relativeTo: .caption2)
}
