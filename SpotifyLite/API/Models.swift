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
        // La más pequeña ≥ 64 px basta para listas.
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= 64 } ?? sorted.last).flatMap { URL(string: $0.url) }
    }
    var durationFormatted: String {
        let seconds = durationMs / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Item de Liked Songs: envuelve el track, que puede ser null
/// (tracks eliminados o locales).
struct TrackItem: Decodable {
    let track: Track?
}

/// Elemento paginado de playlist. La API actual usa la clave "item" tanto en
/// el detalle inicial como en /playlists/{id}/items.
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

struct PlaybackState: Decodable {
    let device: Device?
    let isPlaying: Bool
    let progressMs: Int?
    let item: Track?
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
