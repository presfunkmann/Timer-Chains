//
//  ContentView.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI

// MARK: - Models

struct Activity: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let durationMinutes: Int
    var status: ActivityStatus = .notStarted
    var remainingSeconds: Int? = nil   // nil means "full duration left"
}

enum ActivityStatus: Hashable {
    case notStarted
    case inProgress
    case completedToday
}

// MARK: - Main Screen

struct ContentView: View {
    @State private var activities: [Activity] = [
        Activity(name: "Study programming", durationMinutes: 1),
        Activity(name: "Exercise", durationMinutes: 30),
        Activity(name: "Read a book", durationMinutes: 15)
    ]
    
    @State private var activeActivity: Activity? = nil           // current timer screen
    @State private var pendingStartActivity: Activity? = nil     // for pre-start confirmation
    @State private var showStartConfirmation = false
    @State private var showActiveTimerAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedActivities) { activity in
                    ActivityRow(
                        activity: activity,
                        remainingSeconds: remainingSeconds(for: activity),
                        onStartTapped: { startTapped(activity) },
                        onStreakTapped: { streakTapped(activity) }
                    )
                }
            }
            .navigationTitle("Timers")
            // Confirm before starting a timer
            .alert(
                "Start timer?",
                isPresented: $showStartConfirmation,
                presenting: pendingStartActivity
            ) { activity in
                Button("Start") {
                    actuallyStartTimer(activity)
                }
                Button("Cancel", role: .cancel) { }
            } message: { activity in
                Text("Start timer with \(formattedRemainingTime(for: activity)) remaining for “\(activity.name)” now?")
            }
            // Alert if user tries to start a second timer
            .alert("Timer already running", isPresented: $showActiveTimerAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("You already have a timer running. Cancel it or wait for it to finish before starting another.")
            }
            // Navigate to full-screen timer
            .navigationDestination(item: $activeActivity) { activity in
                TimerView(
                    activity: activity,
                    onFinish: { didConfirm in
                        if didConfirm {
                            markActivityCompletedToday(activity)
                        } else {
                            // user said they didn't actually do it
                            markActivityNotStarted(activity)
                        }
                        activeActivity = nil
                    },
                    onCancel: {
                        // user explicitly cancels (reset)
                        markActivityNotStarted(activity)
                        activeActivity = nil
                    },
                    onPauseAndExit: { secondsLeft in
                        saveRemainingTime(for: activity, seconds: secondsLeft)
                        activeActivity = nil
                    }
                )
            }
        }
    }
    
    // Sorted so unfinished timers appear first, completed at the bottom
    private var sortedActivities: [Activity] {
        activities.sorted { lhs, rhs in
            switch (lhs.status, rhs.status) {
            case (.completedToday, .completedToday):
                return lhs.name < rhs.name
            case (.completedToday, _):
                return false         // completed goes after not-completed
            case (_, .completedToday):
                return true          // not-completed goes before completed
            default:
                return lhs.name < rhs.name
            }
        }
    }
    
    // MARK: - Remaining time helpers
    
    private func remainingSeconds(for activity: Activity) -> Int {
        let base = activity.remainingSeconds ?? activity.durationMinutes * 60
        return max(base, 0)
    }
    
    private func formattedRemainingTime(for activity: Activity) -> String {
        formattedTime(seconds: remainingSeconds(for: activity))
    }
    
    private func formattedTime(seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    // MARK: - Actions
    
    private func startTapped(_ activity: Activity) {
        if activeActivity != nil {
            // A timer is already running (on the timer screen)
            showActiveTimerAlert = true
        } else {
            pendingStartActivity = activity
            showStartConfirmation = true
        }
    }
    
    private func streakTapped(_ activity: Activity) {
        print("Streak tapped for \(activity.name)")
        // later: navigate to a streak visualization screen
    }
    
    private func actuallyStartTimer(_ activity: Activity) {
        // Ensure we update the version in our array, including remainingSeconds
        guard let index = activities.firstIndex(where: { $0.id == activity.id }) else { return }
        
        // If this is the first time starting, set remainingSeconds to full duration
        if activities[index].remainingSeconds == nil {
            activities[index].remainingSeconds = activities[index].durationMinutes * 60
        }
        
        activities[index].status = .inProgress
        
        // Use the updated activity (with remainingSeconds) for the timer screen
        activeActivity = activities[index]
    }
    
    private func markActivityCompletedToday(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].status = .completedToday
            activities[index].remainingSeconds = nil
        }
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].status = .notStarted
            activities[index].remainingSeconds = nil
        }
    }
    
    private func saveRemainingTime(for activity: Activity, seconds: Int) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].remainingSeconds = seconds
            activities[index].status = .inProgress
        }
    }
}

// MARK: - Row View

struct ActivityRow: View {
    let activity: Activity
    let remainingSeconds: Int
    let onStartTapped: () -> Void
    let onStreakTapped: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.name)
                    .font(.headline)
                
                Text("\(formattedRemaining) remaining • \(statusText)")
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
    
    private var formattedRemaining: String {
        let minutes = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Timer Screen

struct TimerView: View {
    let activity: Activity
    let onFinish: (Bool) -> Void      // true = user confirmed they did it
    let onCancel: () -> Void          // user explicitly cancels
    let onPauseAndExit: (Int) -> Void // user pauses then goes back to list
    
    @State private var remainingSeconds: Int
    @State private var isRunning: Bool = true
    @State private var timer: Timer?
    @State private var showCompletionConfirm = false
    
    init(
        activity: Activity,
        onFinish: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void,
        onPauseAndExit: @escaping (Int) -> Void
    ) {
        self.activity = activity
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onPauseAndExit = onPauseAndExit
        
        // Use saved remainingSeconds if present, otherwise full duration
        let initialSeconds = activity.remainingSeconds ?? activity.durationMinutes * 60
        _remainingSeconds = State(initialValue: initialSeconds)
    }
    
    var body: some View {
        VStack(spacing: 32) {
            Text(activity.name)
                .font(.title)
                .multilineTextAlignment(.center)
            
            Text(formattedTime)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
            
            HStack(spacing: 24) {
                Button(isRunning ? "Pause" : "Resume") {
                    toggleRunning()
                }
                .buttonStyle(.bordered)
                
                Button("Cancel") {
                    cancelTimer()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("Timer")
        .navigationBarBackButtonHidden(true) // we manage back behavior ourselves
        .toolbar {
            // When paused, allow going back to the list while preserving remaining time
            if !isRunning {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        backToList()
                    }
                }
            }
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .alert("Timer finished", isPresented: $showCompletionConfirm) {
            Button("Yes, I did it") {
                onFinish(true)
            }
            Button("No", role: .cancel) {
                onFinish(false)
            }
        } message: {
            Text("Did you actually do “\(activity.name)” for \(activity.durationMinutes) minutes?")
        }
    }
    
    // MARK: - Timer logic
    
    private func startTimer() {
        timer?.invalidate()
        isRunning = true
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard isRunning else { return }
            
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            }
            
            if remainingSeconds <= 0 {
                timer?.invalidate()
                isRunning = false
                showCompletionConfirm = true
            }
        }
    }
    
    private func toggleRunning() {
        isRunning.toggle()
    }
    
    private func cancelTimer() {
        timer?.invalidate()
        onCancel()
    }
    
    private func backToList() {
        timer?.invalidate()
        // Save remaining time, keep status as inProgress
        onPauseAndExit(remainingSeconds)
    }
    
    private var formattedTime: String {
        let minutes = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Preview
//
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}
//
//


#Preview {
    ContentView()
}
