import CoreData
import SwiftUI

@main struct MyApp: App {
    let persistenceController = PersistenceController()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
