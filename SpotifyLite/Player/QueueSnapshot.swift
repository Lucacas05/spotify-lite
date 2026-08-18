import Foundation

/// One upcoming queue row. Identity includes occurrence so the same track can
/// appear more than once without SwiftUI reusing the wrong row.
struct QueueRowItem: Identifiable, Equatable {
    let id: String
    let track: Track
    let occurrence: Int

    static func == (lhs: QueueRowItem, rhs: QueueRowItem) -> Bool {
        lhs.id == rhs.id && lhs.occurrence == rhs.occurrence && lhs.track.uri == rhs.track.uri
    }

    static func rows(from tracks: [Track]) -> [QueueRowItem] {
        var counts: [String: Int] = [:]
        return tracks.map { track in
            let key = track.id ?? track.uri
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1
            return QueueRowItem(id: "\(key)#\(occurrence)", track: track, occurrence: occurrence)
        }
    }
}

/// Derived flags for `QueueView`. Distinguishes "not loaded", "loaded empty",
/// and "failed with cached rows" so a refresh error cannot look like an empty queue.
struct QueuePresentation: Equatable {
    let rows: [QueueRowItem]
    let isLoading: Bool
    let error: String?
    let hasLoadedSuccessfully: Bool

    var showsInitialSpinner: Bool {
        rows.isEmpty && isLoading && !hasLoadedSuccessfully
    }

    /// Empty only after Spotify successfully returned no upcoming tracks.
    var showsEmptyState: Bool {
        rows.isEmpty && hasLoadedSuccessfully
    }

    var showsFailedEmpty: Bool {
        rows.isEmpty && error != nil && !hasLoadedSuccessfully
    }

    var showsRows: Bool {
        !rows.isEmpty
    }

    var showsInlineError: Bool {
        error != nil && !showsInitialSpinner
    }

    var refreshEnabled: Bool {
        !isLoading
    }
}

/// Catalog rows play and expose "Play next". Queue rows are inspect-only:
/// Spotify owns order, and activating a queue row must not start a one-URI play.
enum TrackRowBehavior: Equatable {
    case catalog
    case queue

    var showsPlayNextAction: Bool { self == .catalog }
    var activatesPlayback: Bool { self == .catalog }

    var playNextAccessibilityLabel: String? {
        showsPlayNextAction ? "Play next" : nil
    }
}

/// Monotonic queue snapshot with coalesced refreshes and generation checks.
struct QueueRefreshState {
    private(set) var currentlyPlaying: Track?
    private(set) var upcoming: [Track] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var hasLoadedSuccessfully = false
    private(set) var generation = 0
    private var inFlightGeneration: Int?

    var rows: [QueueRowItem] {
        QueueRowItem.rows(from: upcoming)
    }

    var presentation: QueuePresentation {
        QueuePresentation(
            rows: rows,
            isLoading: isLoading,
            error: lastError,
            hasLoadedSuccessfully: hasLoadedSuccessfully
        )
    }

    /// Starts a fetch generation. Returns `nil` when a request is already in
    /// flight and the caller asked to coalesce instead of forcing a newer one.
    mutating func beginRefresh(force: Bool) -> Int? {
        if !force, inFlightGeneration != nil {
            return nil
        }
        generation += 1
        inFlightGeneration = generation
        isLoading = true
        return generation
    }

    mutating func applySuccess(generation: Int, response: QueueResponse) {
        guard generation == inFlightGeneration else { return }
        currentlyPlaying = response.currentlyPlaying
        upcoming = response.queue
        lastError = nil
        hasLoadedSuccessfully = true
        isLoading = false
        inFlightGeneration = nil
    }

    mutating func applyFailure(generation: Int, message: String) {
        guard generation == inFlightGeneration else { return }
        lastError = message
        isLoading = false
        inFlightGeneration = nil
    }

    mutating func cancel(generation: Int) {
        guard generation == inFlightGeneration else { return }
        isLoading = false
        inFlightGeneration = nil
    }

    /// Keep the queue mirror aligned with an optimistic skip. This is not a
    /// local queue editor: Spotify still owns order, and a failed next reverts.
    mutating func applyOptimisticSkipForward() {
        guard let next = upcoming.first else { return }
        currentlyPlaying = next
        upcoming.removeFirst()
    }
}
