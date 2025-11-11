//
//  ContentView.swift
//  Timer Chains
//
//  Created by Preston Mann on 11/10/25.
//

import SwiftUI
import SwiftData
import UserNotifications

// MARK: - SwiftData Models

@Model
final class Activity: Identifiable, Hashable {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Currently treated as **seconds** for testing.
    var durationMinutes: Int
    /// Whether this activity has a completion entry for *today*.
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
    
    // Hashable via id
    static func == (lhs: Activity, rhs: Activity) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// One "I completed this activity on this calendar day" record.
@Model
final class ActivityCompletion {
    @Attribute(.unique) var id: UUID
    var activity: Activity
    /// Always stored as startOfDay in the current calendar.
    var date: Date
    
    init(activity: Activity, date: Date) {
        self.id = UUID()
        let calendar = Calendar.current
        self.activity = activity
        self.date = calendar.startOfDay(for: date)
    }
}

// MARK: - Main Screen

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var activities: [Activity]
    @Query private var completions: [ActivityCompletion]
    
    @State private var activeActivity: Activity? = nil           // current timer screen
    @State private var pendingStartActivity: Activity? = nil     // for pre-start confirmation
    @State private var showStartConfirmation = false
    @State private var showActiveTimerAlert = false
    @State private var showingAddTimerSheet = false
    @State private var streakActivity: Activity? = nil           // for streak sheet
    
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
                syncCompletedTodayFromCompletions()
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
                        // paused; save remaining time but keep in-progress
                        saveRemainingTime(for: activity, seconds: secondsLeft)
                        cancelNotification(for: activity)
                        activeActivity = nil
                    }
                )
            }
            .sheet(isPresented: $showingAddTimerSheet) {
                AddActivitySheet()
            }
            .sheet(item: $streakActivity) { activity in
                StreakView(activity: activity)
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
        streakActivity = activity
    }
    
    private func deleteActivity(_ activity: Activity) {
        cancelNotification(for: activity)
        modelContext.delete(activity)
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
        // Record completion for today (normalized to start-of-day)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Avoid duplicate completion entries for the same (activity, date)
        if !completions.contains(where: { $0.activity.id == activity.id && $0.date == today }) {
            let completion = ActivityCompletion(activity: activity, date: today)
            modelContext.insert(completion)
        }
        
        activity.isCompletedToday = true
        activity.remainingSeconds = nil
        activity.targetEndDate = nil
        cancelNotification(for: activity)
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        // Do not touch existing completions here (so past days are preserved)
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
    
    /// Sync isCompletedToday flags from the completions table for the current date.
    private func syncCompletedTodayFromCompletions() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        for activity in activities {
            let hasToday = completions.contains { completion in
                completion.activity.id == activity.id && completion.date == today
            }
            activity.isCompletedToday = hasToday
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: {
                onDeleteTapped()
            }) {
                Text("Delete")
            }
        }
    }
    
    private var statusText: String {
        if activity.isCompletedToday {
            return "Completed today"
        } else if remainingSeconds < activity.durationMinutes {
            // There is less time left than the original duration,
            // so the user has started (or paused) this timer.
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

// MARK: - Streak View

struct StreakView: View {
    let activity: Activity
    
    @Environment(\.modelContext) private var modelContext
    @State private var completions: [ActivityCompletion] = []
    
    private var calendar: Calendar { Calendar.current }
    
    private var today: Date {
        calendar.startOfDay(for: Date())
    }
    
    private var completionDatesSet: Set<Date> {
        Set(completions.map { calendar.startOfDay(for: $0.date) })
    }
    
    /// Number of consecutive days ending today with a completion.
    private var streakCount: Int {
        var count = 0
        var day = today
        
        while completionDatesSet.contains(day) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: prev)
        }
        
        return count
    }
    
    /// Last 14 days (including today), oldest -> newest.
    private var last14Days: [Date] {
        (0..<14).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
        .map { calendar.startOfDay(for: $0) }
        .sorted()
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Text(activity.name)
                .font(.title2)
                .multilineTextAlignment(.center)
            
            Text("Current streak: \(streakCount) day\(streakCount == 1 ? "" : "s")")
                .font(.headline)
            
            // Simple chain visualization for last 14 days
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(last14Days, id: \.self) { day in
                        let isDone = completionDatesSet.contains(day)
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .strokeBorder(lineWidth: 2)
                                    .frame(width: 24, height: 24)
                                    .opacity(isDone ? 1.0 : 0.4)
                                
                                if isDone {
                                    Circle()
                                        .frame(width: 18, height: 18)
                                }
                            }
                            
                            Text(shortDayLabel(for: day))
                                .font(.caption2)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("Streak")
        .onAppear {
            loadCompletions()
        }
    }
    
    private func loadCompletions() {
        let descriptor = FetchDescriptor<ActivityCompletion>()
        
        if let results = try? modelContext.fetch(descriptor) {
            // Only keep completions for this activity
            completions = results.filter { $0.activity.id == activity.id }
        }
    }

    
    private func shortDayLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "E" // Mon, Tue, etc.
        return formatter.string(from: date)
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
