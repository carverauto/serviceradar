import SwiftUI

@main
struct FieldSurveyApp: App {
    var body: some Scene {
        WindowGroup {
            if #available(iOS 16.0, *) {
                ContentView()
            } else {
                Text("FieldSurvey requires iOS 16.0 or newer.")
            }
        }
    }
}