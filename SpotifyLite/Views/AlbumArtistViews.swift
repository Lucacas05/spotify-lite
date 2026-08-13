import SwiftUI

struct AlbumDetailView: View {
    let albumID: String
    let albumName: String
    var player: PlayerStore

    @State private var album: AlbumDetailResponse?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ErrorStateView(title: "No se pudo cargar el álbum", message: error) {
                    Task { await load() }
                }
            } else if let album {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .bottom, spacing: 20) {
                            RemoteArtwork(url: artworkURL(album.images), size: 180)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("ÁLBUM")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(album.name)
                                    .font(.largeTitle.bold())
                                Text(album.artists.map(\.name).joined(separator: ", "))
                                    .font(.title3)
                                Text([album.releaseDate, "\(album.totalTracks) canciones"]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task { await player.play(contextURI: album.uri) }
                                } label: {
                                    Label("Reproducir", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                        }
                        .padding(.horizontal, 20)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(album.tracks.items.enumerated()), id: \.offset) { _, track in
                                TrackRow(track: track, player: player, showAlbumLink: false) {
                                    Task { await player.play(contextURI: album.uri, trackURI: track.uri) }
                                }
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            } else {
                ProgressView("Cargando álbum…")
            }
        }
        .navigationTitle(album?.name ?? albumName)
        .task(id: albumID) { await load() }
    }

    private func load() async {
        do {
            album = try await SpotifyClient.shared.get("albums/\(albumID)")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ArtistDetailView: View {
    let artistID: String
    let artistName: String
    var player: PlayerStore

    @State private var artist: ArtistDetailResponse?
    @State private var tracks: [Track] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ErrorStateView(title: "No se pudo cargar el artista", message: error) {
                    Task { await load() }
                }
            } else if let artist {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .bottom, spacing: 20) {
                            RemoteArtwork(url: artworkURL(artist.images), size: 180)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 8) {
                                Text("ARTISTA")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(artist.name)
                                    .font(.largeTitle.bold())
                                if let followers = artist.followers?.total {
                                    Text("\(followers.formatted()) seguidores")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        Text("Canciones populares")
                            .font(.title2.bold())
                            .padding(.horizontal, 20)
                        if tracks.isEmpty {
                            ContentUnavailableView("Sin canciones disponibles", systemImage: "music.note")
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                                    TrackRow(track: track, player: player) {
                                        Task { await player.play(trackURI: track.uri) }
                                    }
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            } else {
                ProgressView("Cargando artista…")
            }
        }
        .navigationTitle(artist?.name ?? artistName)
        .task(id: artistID) { await load() }
    }

    private func load() async {
        do {
            async let artistRequest: ArtistDetailResponse = SpotifyClient.shared.get("artists/\(artistID)")
            async let tracksRequest: ArtistTopTracksResponse = SpotifyClient.shared.get("artists/\(artistID)/top-tracks")
            artist = try await artistRequest
            tracks = try await tracksRequest.tracks
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RemoteArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reintentar", action: retry)
        }
    }
}

private func artworkURL(_ images: [SpotifyImage]?) -> URL? {
    guard let image = images?.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) else { return nil }
    return URL(string: image.url)
}
