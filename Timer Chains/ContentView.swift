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
                        isCompletedToday: isCompletedToday(activity),
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
            let lhsDone = isCompletedToday(lhs)
            let rhsDone = isCompletedToday(rhs)
            
            switch (lhsDone, rhsDone) {
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
            return max(activity.durationMinutes * 60, 0)
            // U For Testing 
//            return max(activity.durationMinutes, 0)
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
    
    private func isCompletedToday(_ activity: Activity) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return completions.contains { completion in
            completion.activity.id == activity.id && completion.date == today
        }
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Insert a completion record for today if it doesn't exist
        if !completions.contains(where: { $0.activity.id == activity.id && $0.date == today }) {
            let completion = ActivityCompletion(activity: activity, date: today)
            modelContext.insert(completion)
        }
        
        // Clear timer-related state on the stored Activity
        if let existing = activities.first(where: { $0.id == activity.id }) {
            existing.remainingSeconds = nil
            existing.targetEndDate = nil
        }
        
        cancelNotification(for: activity)
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        // Don't touch completion history
        if let existing = activities.first(where: { $0.id == activity.id }) {
            existing.remainingSeconds = nil
            existing.targetEndDate = nil
        }
        cancelNotification(for: activity)
    }
    
    private func saveRemainingTime(for activity: Activity, seconds: Int) {
        if let existing = activities.first(where: { $0.id == activity.id }) {
            existing.remainingSeconds = seconds
            existing.targetEndDate = nil   // not running while paused
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
    let isCompletedToday: Bool
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
        if isCompletedToday {
            return "Completed today"
        } else if remainingSeconds < activity.durationMinutes * 60 {
            // Less time left than the original duration → started/paused
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
                    
                    TextField("Duration (minutes)", text: $durationText)
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
        guard let minutes = Int(durationText), minutes > 0 else { return }
        let activity = Activity(
            name: name.trimmingCharacters(in: .whitespaces),
            durationMinutes: minutes
        )
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
                ToolbarItem(placement: .topBarLeading) {
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
            Text("Did you actually do “\(activity.name)” for \(activity.durationMinutes) minutes?")
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
    
    /// All days from first completion up to today (or just today if none).
    private var allDays: [Date] {
        // If no completions, show just today
        guard !completions.isEmpty else {
            return [today]
        }
        
        // Earliest completion date (normalized to start-of-day)
        let earliest = completions
            .map { calendar.startOfDay(for: $0.date) }
            .min() ?? today
        
        var days: [Date] = []
        var day = earliest
        
        while day <= today {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        
        return days
    }
    
    /// Chunk allDays into rows of up to 7 days each.
    private var rows: [[Date]] {
        let chunkSize = 7
        var result: [[Date]] = []
        let days = allDays
        
        var index = 0
        while index < days.count {
            let end = min(index + chunkSize, days.count)
            result.append(Array(days[index..<end]))
            index = end
        }
        
        return result
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Text(activity.name)
                .font(.title2)
                .multilineTextAlignment(.center)
            
            Text("Current streak: \(streakCount) day\(streakCount == 1 ? "" : "s")")
                .font(.headline)
            
            // Full-history grid, scrollable vertically, with connectors
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        rowView(for: row)
                            .padding(.horizontal)
                        
                        // Curved connector from this row to the next, if needed
                        if index < rows.count - 1 {
                            interRowConnector(
                                previousRow: row,
                                nextRow: rows[index + 1]
                            )
                            .padding(.horizontal)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("Streak")
        .onAppear {
            loadCompletions()
        }
    }
    
    // MARK: - Row + Cells
    
    private func rowView(for row: [Date]) -> some View {
        // Constants to keep sizing consistent
        let dotSize: CGFloat = 24
        let connectorWidth: CGFloat = 16
        
        return HStack(spacing: 0) {
            ForEach(0..<row.count, id: \.self) { index in
                let day = row[index]
                let isDone = completionDatesSet.contains(day)
                
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .strokeBorder(lineWidth: 2)
                            .frame(width: dotSize, height: dotSize)
                            .opacity(isDone ? 1.0 : 0.3)
                        
                        if isDone {
                            Circle()
                                .frame(width: dotSize - 6, height: dotSize - 6)
                        }
                    }
                    
                    Text(dateLabel(for: day))
                        .font(.caption2)
                }
                .frame(width: dotSize + 4) // a little breathing room
                
                // Horizontal connector to the next day in the same row
                if index < row.count - 1 {
                    let nextDay = row[index + 1]
                    let nextIsDone = completionDatesSet.contains(nextDay)
                    let isConsecutive = isNextDay(day, nextDay)
                    let shouldConnect = isDone && nextIsDone && isConsecutive
                    
                    Rectangle()
                        .frame(width: connectorWidth, height: 2)
                        .opacity(shouldConnect ? 1.0 : 0.1)
                }
            }
        }
    }
    
    /// Curved connector between the last dot of previousRow and the first dot of nextRow
    @ViewBuilder
    private func interRowConnector(previousRow: [Date], nextRow: [Date]) -> some View {
        if let last = previousRow.last,
           let first = nextRow.first {
            
            let lastDone = completionDatesSet.contains(last)
            let firstDone = completionDatesSet.contains(first)
            let consecutive = isNextDay(last, first)
            let shouldConnect = lastDone && firstDone && consecutive
            
            if shouldConnect {
                RowWrapConnectorView()
            } else {
                EmptyView()
            }
        } else {
            // No last/first day — nothing to connect
            EmptyView()
        }
    }
    
    // MARK: - Data loading & helpers
    
    private func loadCompletions() {
        let descriptor = FetchDescriptor<ActivityCompletion>()
        
        if let results = try? modelContext.fetch(descriptor) {
            completions = results.filter { $0.activity.id == activity.id }
        }
    }
    
    /// Format as M/D with no leading zeros on either.
    private func dateLabel(for date: Date) -> String {
        let comps = calendar.dateComponents([.month, .day], from: date)
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        return "\(month)/\(day)"
    }
    
    /// True if `b` is exactly one day after `a`.
    private func isNextDay(_ a: Date, _ b: Date) -> Bool {
        let startA = calendar.startOfDay(for: a)
        let startB = calendar.startOfDay(for: b)
        guard let next = calendar.date(byAdding: .day, value: 1, to: startA) else {
            return false
        }
        return calendar.isDate(startB, inSameDayAs: next)
    }
}

// MARK: - Row wrap curved connector

struct RowWrapConnectorView: View {
    private let lineWidth: CGFloat = 2.0
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            Path { path in
                // Start near the right side, top
                let start = CGPoint(x: width - 30, y: 0)
                // End near the left side, bottom
                let end = CGPoint(x: 30, y: height)
                // Control point below mid to create a nice curve
                let control = CGPoint(x: width / 2, y: height + 16)
                
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }
            .stroke(lineWidth: lineWidth)
        }
        .frame(height: 32) // height of the curved connector space
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
