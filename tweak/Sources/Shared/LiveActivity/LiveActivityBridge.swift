// ActivityKit is Swift only, so LiveActivity.x reaches it through this class.
import ActivityKit
import Foundation
import os

@available(iOS 17.0, *)
@objc(SGLiveActivityBridge)
public final class SGLiveActivityBridge: NSObject {
    private static let log = Logger(subsystem: "spotifyglass", category: "live activity")

    private static var current: Activity<SGLyricsAttributes>? {
        Activity<SGLyricsAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    @objc public static var isShowing: Bool { current != nil }

    // The showing activity has been given up on by the system: its state, or a
    // stale date already past. Pausing from Control Center or another device
    // never wakes this process to send the dismissal moment, so staleness is
    // the only evidence the end already happened (Batch 53).
    @objc public static var isStale: Bool {
        guard let activity = current else { return false }
        if activity.activityState == .stale { return true }
        if let staleDate = activity.content.staleDate { return staleDate < Date() }
        return false
    }

    // Updates and ends go out one at a time in the order asked for, since ActivityKit applies
    // concurrent ones in whatever order they finish. An update still waiting gives way to a newer one.
    private enum Change: Sendable {
        case update(String, ActivityContent<SGLyricsAttributes.ContentState>)
        case end([String])
    }

    private struct Pending: Sendable {
        var changes: [Change] = []
        var sending = false
    }

    private static let pending = OSAllocatedUnfairLock(initialState: Pending())

    private static func queue(_ change: Change) {
        let start = pending.withLock { pending in
            if case .update(let id, _) = change, case .update(let waiting, _)? = pending.changes.last, waiting == id {
                pending.changes.removeLast()
            }
            // An update that arrives after an end was queued for the same
            // activity is the newer word (Batch 93): a quick resume used
            // to queue its update behind the pending end, the end landed,
            // and the update then looked up a dead id and vanished — the
            // card stayed gone until the app was opened. The end gives
            // way for that id; ends for other ids stand.
            if case .update(let id, _) = change {
                pending.changes = pending.changes.compactMap { waiting in
                    if case .end(var ids) = waiting, ids.contains(id) {
                        ids.removeAll { $0 == id }
                        return ids.isEmpty ? nil : Change.end(ids)
                    }
                    return waiting
                }
            }
            pending.changes.append(change)
            if pending.sending { return false }
            pending.sending = true
            return true
        }
        if start { Task { await send() } }
    }

    private static func send() async {
        while let change = pending.withLock({ pending -> Change? in
            if pending.changes.isEmpty {
                pending.sending = false
                return nil
            }
            return pending.changes.removeFirst()
        }) {
            let activities = Activity<SGLyricsAttributes>.activities
            switch change {
            case .update(let id, let content):
                await activities.first { $0.id == id }?.update(content)
            case .end(let ids):
                for activity in activities where ids.contains(activity.id) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    // A new activity can only be requested while the app is in the foreground; an update works from the background.
    // One call per new state. View and tab are SGLiveActivityView's and SGLiveActivityTab's values;
    // titles, artists and URIs pair up by index, the tracks up next; timerEnd is nil without a timer.
    @objc public static func show(view: Int, paused: Bool, line: String, nextLine: String,
                                  titles: [String], artists: [String], uris: [String],
                                  tab: Int, title: String, artist: String, shuffle: Bool, repeatMode: Int,
                                  timerEnd: Date?, timerEndOfTrack: Bool,
                                  positionSec: Double, durationSec: Double, dismissAt: Date?, tint: Int) {
        let tracks = titles.indices.map {
            SGLyricsAttributes.Track(title: titles[$0], artist: artists[$0], uri: uris[$0])
        }
        let state = SGLyricsAttributes.ContentState(
            view: SGLyricsAttributes.View(rawValue: view) ?? .lyrics, paused: paused,
            line: line, nextLine: nextLine, tracks: tracks,
            tab: SGLyricsAttributes.Tab(rawValue: tab) ?? .controls, title: title, artist: artist,
            shuffle: shuffle, repeatMode: repeatMode, timerEnd: timerEnd, timerEndOfTrack: timerEndOfTrack,
            positionSec: positionSec, durationSec: durationSec, sentAt: Date(), dismissAt: dismissAt,
            tint: tint)
        // The stale horizon (personal fork): while a paused player's idle end is armed
        // it is the stale date, so the system itself marks the card stale at the very
        // moment it should end — the app, suspended, cannot. Otherwise a rolling
        // 5 minutes: updates land every line change while anything plays (and the
        // fingerprint now carries a coarse position, so even a long instrumental
        // refreshes it), so the date is only ever reached when the process is
        // gone — the app closed, the phone rebooted — and then the system marks
        // the card stale within minutes instead of presenting its last line as
        // live for hours, and the widget retires a stale card on sight.
        let content = ActivityContent(state: state, staleDate: dismissAt ?? Date(timeIntervalSinceNow: 5 * 60))
        if let activity = current {
            queue(.update(activity.id, content))
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("[spotifyglass] live activity: activities are off for this app")
            return
        }
        do {
            let activity = try Activity.request(attributes: SGLyricsAttributes(), content: content, pushType: nil)
            log.notice("[spotifyglass] live activity: started \(activity.id, privacy: .public)")
        } catch {
            log.error("[spotifyglass] live activity: request failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Named now, so an activity requested after this call is not ended with them.
    @objc public static func end() {
        queue(.end(Activity<SGLyricsAttributes>.activities.map(\.id)))
    }
}
