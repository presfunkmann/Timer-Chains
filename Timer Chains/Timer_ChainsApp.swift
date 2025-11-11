//
//  Timer_ChainsApp.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI
import SwiftData

@main
struct YourProjectNameApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Activity.self)
    }
}
