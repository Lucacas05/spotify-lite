import Foundation

struct Paging<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
    let total: Int
}

struct SpotifyImage: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct SimplifiedPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let images: [SpotifyImage]?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Artist: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(name) }
}

struct Album: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let images: [SpotifyImage]?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(name) }
}

struct Track: Decodable, Identifiable {
    let id: String?
    let name: String
    let uri: String
    let durationMs: Int
    let artists: [Artist]
    let album: Album?

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var artworkURL: URL? {
        guard let images = album?.images, !images.isEmpty else { return nil }
        // The smallest ≥ 64 px is enough for lists.
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= 64 } ?? sorted.last).flatMap { URL(string: $0.url) }
    }
    var durationFormatted: String {
        let seconds = durationMs / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Liked Songs item: wraps the track, which can be null
/// (deleted or local tracks).
struct TrackItem: Decodable {
    let track: Track?
}

/// Paginated playlist entry. The current API uses the "item" key both in
/// the initial detail and in /playlists/{id}/items.
struct PlaylistEntry: Decodable {
    let item: Track?
}

struct PlaylistDetailResponse: Decodable {
    let items: Paging<PlaylistEntry>
}

struct Device: Decodable, Identifiable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let volumePercent: Int?
}

struct DevicesResponse: Decodable {
    let devices: [Device]
}

struct PlaybackContext: Decodable {
    let uri: String?
    let type: String?
}

struct PlaybackState: Decodable {
    let device: Device?
    let isPlaying: Bool
    let progressMs: Int?
    let item: Track?
    let shuffleState: Bool?
    let context: PlaybackContext?

    func isPlayingPlaylist(id: String) -> Bool {
        context?.uri == "spotify:playlist:\(id)"
    }

    /// Liked Songs uses `spotify:user:{id}:collection`, not a playlist URI.
    var isPlayingLikedSongs: Bool {
        guard let uri = context?.uri else { return context?.type == "collection" }
        return uri.hasSuffix(":collection") && !uri.contains(":collection:")
    }

    func isCurrentTrack(_ track: Track) -> Bool {
        if let currentID = item?.id, let trackID = track.id {
            return currentID == trackID
        }
        return item?.uri == track.uri
    }
}

struct SearchResponse: Decodable {
    let tracks: Paging<Track>?
}

struct QueueResponse: Decodable {
    let currentlyPlaying: Track?
    let queue: [Track]
}

struct AlbumDetailResponse: Decodable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    let artists: [Artist]
    let releaseDate: String?
    let totalTracks: Int
    let uri: String
    let tracks: Paging<Track>
}

struct ArtistDetailResponse: Decodable {
    struct Followers: Decodable { let total: Int }

    let id: String
    let name: String
    let images: [SpotifyImage]?
    let followers: Followers?
}

struct ArtistTopTracksResponse: Decodable {
    let tracks: [Track]
}
