//
//  ContentView.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI

// 1. Basic model for one timer/activity
struct Activity: Identifiable {
    let id = UUID()
    let name: String
    let durationMinutes: Int
    var status: ActivityStatus = .notStarted
}

enum ActivityStatus {
    case notStarted
    case inProgress
    case completedToday
}

// 2. Main screen
struct ContentView: View {
    @State private var activities: [Activity] = [
        Activity(name: "Study programming", durationMinutes: 20),
        Activity(name: "Exercise", durationMinutes: 30),
        Activity(name: "Read a book", durationMinutes: 15)
    ]
    
    // later we’ll use this to navigate to the full-screen timer
    @State private var activeActivity: Activity? = nil
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(activities) { activity in
                    ActivityRow(
                        activity: activity,
                        onStartTapped: { startTapped(activity) },
                        onStreakTapped: { streakTapped(activity) }
                    )
                }
            }
            .navigationTitle("Timers")
        }
    }
    
    // placeholder actions for now
    private func startTapped(_ activity: Activity) {
        print("Start tapped for \(activity.name)")
        // in the next step, this will:
        // - show a confirmation
        // - navigate to a full-screen Timer view
    }
    
    private func streakTapped(_ activity: Activity) {
        print("Streak tapped for \(activity.name)")
        // later, this will navigate to a streak visualization screen
    }
}

// 3. Row for each activity in the list
struct ActivityRow: View {
    let activity: Activity
    let onStartTapped: () -> Void
    let onStreakTapped: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.name)
                    .font(.headline)
                
                Text("\(activity.durationMinutes) minutes • \(statusText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Streak") {
                onStreakTapped()
            }
            .buttonStyle(.bordered)
            
            Button("Start") {
                onStartTapped()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
    
    private var statusText: String {
        switch activity.status {
        case .notStarted:
            return "Not started"
        case .inProgress:
            return "In progress"
        case .completedToday:
            return "Completed today"
        }
    }
}

//// 4. Preview for Xcode canvas
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}


#Preview {
    ContentView()
}
