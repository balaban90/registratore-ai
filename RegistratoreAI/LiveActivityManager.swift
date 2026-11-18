import Foundation
import ActivityKit

/// Mostra registrazione e lavorazione nella Dynamic Island e nella schermata di blocco.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?
    /// Registrazione a cui si riferisce l'attività durante la lavorazione.
    private var recordingID: UUID?

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: - Registrazione

    func recordingStarted(title: String) {
        endImmediately()
        guard enabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            phase: .recording, timerStart: .now, pausedElapsed: 0, status: "Registrazione in corso", progress: nil)
        activity = try? Activity.request(attributes: RecordingActivityAttributes(title: title),
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    func recordingPaused(elapsed: Double) {
        update(.init(phase: .paused, timerStart: .now, pausedElapsed: elapsed, status: "In pausa", progress: nil))
    }

    func recordingResumed(elapsed: Double) {
        update(.init(phase: .recording, timerStart: Date.now.addingTimeInterval(-elapsed), pausedElapsed: 0,
                     status: "Registrazione in corso", progress: nil))
    }

    func recordingDiscarded() { endImmediately() }

    // MARK: - Lavorazione

    func processing(_ recording: Recording, status: String, progress: Double?, window: ClosedRange<Date>? = nil) {
        let state = RecordingActivityAttributes.ContentState(
            phase: .processing, timerStart: .now, pausedElapsed: 0, status: status, progress: progress,
            progressStart: window?.lowerBound, progressEnd: window?.upperBound)
        if activity == nil || (recordingID != nil && recordingID != recording.id) {
            guard enabled, activity == nil else {
                // Un'altra registrazione occupa già l'attività: aggiorna solo se è la stessa.
                if recordingID == recording.id { update(state) }
                return
            }
            activity = try? Activity.request(attributes: RecordingActivityAttributes(title: recording.title),
                                             content: ActivityContent(state: state, staleDate: nil))
            recordingID = recording.id
            return
        }
        recordingID = recording.id
        update(state)
    }

    func finished(_ recording: Recording, success: Bool) {
        guard let activity, recordingID == nil || recordingID == recording.id else { return }
        let state = RecordingActivityAttributes.ContentState(
            phase: .done, timerStart: .now, pausedElapsed: 0,
            status: success ? "Pronta: \(recording.title)" : "Da completare: apri l'app", progress: 1)
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(8))) }
        self.activity = nil
        recordingID = nil
    }

    /// Chiude subito l'attività di una registrazione eliminata durante la lavorazione.
    func dismiss(_ id: UUID) {
        guard recordingID == id else { return }
        endImmediately()
    }

    // MARK: -

    private func update(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endImmediately() {
        if let activity {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        // Eventuali attività rimaste da una sessione precedente.
        for old in Activity<RecordingActivityAttributes>.activities where old.id != activity?.id {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        recordingID = nil
    }
}
