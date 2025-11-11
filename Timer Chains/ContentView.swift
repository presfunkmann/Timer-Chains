//
//  ContentView.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI
import UserNotifications

// MARK: - Models

struct Activity: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let durationMinutes: Int          // currently treated as *seconds* for testing
    var status: ActivityStatus = .notStarted
    var remainingSeconds: Int? = nil  // used when paused or not yet started
    var targetEndDate: Date? = nil    // non-nil when actively running
}

enum ActivityStatus: Hashable {
    case notStarted
    case inProgress
    case completedToday
}

// MARK: - Main Screen

struct ContentView: View {
    @State private var activities: [Activity] = [
        Activity(name: "Study programming", durationMinutes: 5),
        Activity(name: "Exercise", durationMinutes: 10),
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
            .onAppear {
                requestNotificationPermission()
            }
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
                    initialRemainingSeconds: remainingSeconds(for: activity),
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
                        cancelNotification(for: activity)
                        markActivityNotStarted(activity)
                        activeActivity = nil
                    },
                    onPauseAndExit: { secondsLeft in
                        // paused; save remaining time but keep inProgress
                        saveRemainingTime(for: activity, seconds: secondsLeft)
                        cancelNotification(for: activity)
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
        if let end = activity.targetEndDate {
            // When running: compute from absolute end time
            let diff = Int(end.timeIntervalSinceNow)
            return max(diff, 0)
        } else if let stored = activity.remainingSeconds {
            // Paused or prepared but not started
            return max(stored, 0)
        } else {
            // Fresh: treat durationMinutes as *seconds* for testing
            return max(activity.durationMinutes, 0)
        }
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
        guard let index = activities.firstIndex(where: { $0.id == activity.id }) else { return }
        
        // Determine how much time is left for this activity
        let secondsLeft = remainingSeconds(for: activities[index])
        
        // Set a new absolute end date based on "now + secondsLeft"
        let endDate = Date().addingTimeInterval(TimeInterval(secondsLeft))
        
        activities[index].status = .inProgress
        activities[index].targetEndDate = endDate
        activities[index].remainingSeconds = nil
        
        let updated = activities[index]
        scheduleNotification(for: updated, endDate: endDate)
        activeActivity = updated
    }
    
    private func markActivityCompletedToday(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].status = .completedToday
            activities[index].remainingSeconds = nil
            activities[index].targetEndDate = nil
        }
        cancelNotification(for: activity)
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].status = .notStarted
            activities[index].remainingSeconds = nil
            activities[index].targetEndDate = nil
        }
        cancelNotification(for: activity)
    }
    
    private func saveRemainingTime(for activity: Activity, seconds: Int) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].remainingSeconds = seconds
            activities[index].targetEndDate = nil   // not running while paused
            activities[index].status = .inProgress
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                // you could check 'granted' here if you want
            }
    }
    
    private func scheduleNotification(for activity: Activity, endDate: Date) {
        let seconds = max(Int(endDate.timeIntervalSinceNow), 0)
        guard seconds > 0 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Timer finished"
        content.body = "Timer for “\(activity.name)” is done."
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: activity.id.uuidString,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    private func cancelNotification(for activity: Activity) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [activity.id.uuidString])
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
    let initialRemainingSeconds: Int
    let onFinish: (Bool) -> Void      // true = user confirmed they did it
    let onCancel: () -> Void          // user explicitly cancels
    let onPauseAndExit: (Int) -> Void // user pauses then goes back to list
    
    @State private var remainingSeconds: Int
    @State private var isRunning: Bool = true
    @State private var timer: Timer?
    @State private var showCompletionConfirm = false
    @State private var localEndDate: Date?
    
    init(
        activity: Activity,
        initialRemainingSeconds: Int,
        onFinish: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void,
        onPauseAndExit: @escaping (Int) -> Void
    ) {
        self.activity = activity
        self.initialRemainingSeconds = initialRemainingSeconds
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onPauseAndExit = onPauseAndExit
        
        _remainingSeconds = State(initialValue: max(initialRemainingSeconds, 0))
        _localEndDate = State(initialValue: activity.targetEndDate)
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
            startTimerIfNeeded()
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
            Text("Did you actually do “\(activity.name)” for \(initialRemainingSeconds) seconds?")
        }
    }
    
    // MARK: - Timer logic
    
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        
        if localEndDate == nil {
            // If we don't have an end date yet, create one from remainingSeconds
            localEndDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard isRunning, let end = localEndDate else { return }
            
            let secondsLeft = max(Int(end.timeIntervalSinceNow), 0)
            remainingSeconds = secondsLeft
            
            if secondsLeft <= 0 {
                timer?.invalidate()
                isRunning = false
                showCompletionConfirm = true
            }
        }
    }
    
    private func toggleRunning() {
        if isRunning {
            // going from running -> paused
            if let end = localEndDate {
                let secsLeft = max(Int(end.timeIntervalSinceNow), 0)
                remainingSeconds = secsLeft
            }
            localEndDate = nil
            isRunning = false
        } else {
            // paused -> running
            localEndDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            isRunning = true
        }
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

//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}




#Preview {
    ContentView()
}
