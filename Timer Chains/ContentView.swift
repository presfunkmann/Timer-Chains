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
}

enum ActivityStatus {
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
    
    @State private var activeActivity: Activity? = nil           // current running timer
    @State private var pendingStartActivity: Activity? = nil     // for pre-start confirmation
    @State private var showStartConfirmation = false
    @State private var showActiveTimerAlert = false
    
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
                Text("Start \(activity.durationMinutes)-minute timer for “\(activity.name)” now?")
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
                        markActivityNotStarted(activity)
                        activeActivity = nil
                    }
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func startTapped(_ activity: Activity) {
        if activeActivity != nil {
            // A timer is already running
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
        updateStatus(for: activity, to: .inProgress)
        activeActivity = activity
    }
    
    private func markActivityCompletedToday(_ activity: Activity) {
        updateStatus(for: activity, to: .completedToday)
    }
    
    private func markActivityNotStarted(_ activity: Activity) {
        updateStatus(for: activity, to: .notStarted)
    }
    
    private func updateStatus(for activity: Activity, to newStatus: ActivityStatus) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index].status = newStatus
        }
    }
}

// MARK: - Row View

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

// MARK: - Timer Screen

struct TimerView: View {
    let activity: Activity
    let onFinish: (Bool) -> Void      // true = user confirmed they did it
    let onCancel: () -> Void
    
    @State private var remainingSeconds: Int
    @State private var isRunning: Bool = true
    @State private var timer: Timer?
    @State private var showCompletionConfirm = false
    
    init(activity: Activity, onFinish: @escaping (Bool) -> Void, onCancel: @escaping () -> Void) {
        self.activity = activity
        self.onFinish = onFinish
        self.onCancel = onCancel
        _remainingSeconds = State(initialValue: activity.durationMinutes * 60)
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
        .navigationBarBackButtonHidden(true) // must cancel or finish
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
    
    private var formattedTime: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

//// MARK: - Preview
//
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}



#Preview {
    ContentView()
}
