//
//  ContentView.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI
import SwiftData
import UserNotifications

// MARK: - SwiftData Model

@Model
final class Activity: Identifiable, Hashable {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Currently treated as **seconds** for testing.
    var durationMinutes: Int
    var isCompletedToday: Bool
    /// Used when paused (how many seconds are left) or before first start.
    var remainingSeconds: Int?
    /// Non-nil when actively running.
    var targetEndDate: Date?
    
    init(
        name: String,
        durationMinutes: Int,
        isCompletedToday: Bool = false,
        remainingSeconds: Int? = nil,
        targetEndDate: Date? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.durationMinutes = durationMinutes
        self.isCompletedToday = isCompletedToday
        self.remainingSeconds = remainingSeconds
        self.targetEndDate = targetEndDate
    }
    
    // Hashable conformance (use id)
    static func == (lhs: Activity, rhs: Activity) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Main Screen

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var activities: [Activity]
    
    @State private var activeActivity: Activity? = nil           // current timer screen
    @State private var pendingStartActivity: Activity? = nil     // for pre-start confirmation
    @State private var showStartConfirmation = false
    @State private var showActiveTimerAlert = false
    @State private var showingAddTimerSheet = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedActivities) { activity in
                    ActivityRow(
                        activity: activity,
                        remainingSeconds: remainingSeconds(for: activity),
                        onStartTapped: { startTapped(activity) },
                        onStreakTapped: { streakTapped(activity) },
                        onDeleteTapped: { deleteActivity(activity) }
                    )
                }
            }
            .navigationTitle("Timers")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddTimerSheet = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
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
            .sheet(isPresented: $showingAddTimerSheet) {
                AddActivitySheet()
            }
        }
    }
    
    // Sorted so unfinished timers appear first, completed at the bottom
    private var sortedActivities: [Activity] {
        activities.sorted { lhs, rhs in
            switch (lhs.isCompletedToday, rhs.isCompletedToday) {
            case (true, true):
                return lhs.name < rhs.name
            case (true, false):
                return false   // completed goes after not-completed
            case (false, true):
                return true    // not-completed goes before completed
            case (false, false):
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
    private func deleteActivity(_ activity: Activity) {
        cancelNotification(for: activity)
        modelContext.delete(activity)
    }
    
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
        // Determine how much time is left for this activity
        let secondsLeft = remainingSeconds(for: activity)
        
        // Set a new absolute end date based on "now + secondsLeft"
        let endDate = Date().addingTimeInterval(TimeInterval(secondsLeft))
        
        activity.isCompletedToday = false
        activity.targetEndDate = endDate
        activity.remainingSeconds = nil
        
        scheduleNotification(for: activity, endDate: endDate)
        activeActivity = activity
    }
    
    private func markActivityCompletedToday(_ activity: Activity) {
        activity.isCompletedToday = true
        activity.remainingSeconds = nil
        activity.targetEndDate = nil
        cancelNotification(for: activity)
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        activity.isCompletedToday = false
        activity.remainingSeconds = nil
        activity.targetEndDate = nil
        cancelNotification(for: activity)
    }
    
    private func saveRemainingTime(for activity: Activity, seconds: Int) {
        activity.remainingSeconds = seconds
        activity.targetEndDate = nil   // not running while paused
        activity.isCompletedToday = false
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
    let onDeleteTapped: () -> Void
    
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDeleteTapped()
            } label: {
                Text("Delete")
            }
        }
    }
    
    private var statusText: String {
        if activity.isCompletedToday {
            return "Completed today"
        } else if remainingSeconds < activity.durationMinutes {
            return "In progress"
        } else {
            return "Not started"
        }
    }
    
    private var formattedRemaining: String {
        let minutes = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Add Timer Sheet

struct AddActivitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var name: String = ""
    @State private var durationText: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Timer") {
                    TextField("Name", text: $name)
                    
                    TextField("Duration (seconds for now)", text: $durationText)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("New Timer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
    
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard Int(durationText) ?? 0 > 0 else { return false }
        return true
    }
    
    private func save() {
        guard let seconds = Int(durationText), seconds > 0 else { return }
        let activity = Activity(name: name.trimmingCharacters(in: .whitespaces), durationMinutes: seconds)
        modelContext.insert(activity)
        dismiss()
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
            Text("Did you actually do “\(activity.name)” for \(activity.durationMinutes) seconds?")
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
            // running -> paused
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
        // Save remaining time, keep status as in-progress
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





#Preview {
    ContentView()
}
