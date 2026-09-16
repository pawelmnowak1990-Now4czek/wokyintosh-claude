import Foundation

/// Adresy okładek podawanych stronie przez `ArtworkSchemeHandler`.
enum ArtworkURL {
    static let scheme = "wokyintosh-art"
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func make(artworkId: String) -> String {
        let encoded = artworkId.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(scheme)://artwork/\(encoded)"
    }

    /// Identyfikator czytany z surowego adresu, bo `URL.path` zamieniłby `%2F` na ukośnik.
    static func artworkId(from url: URL) -> String? {
        let prefix = "\(scheme)://artwork/"
        let raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }
        let id = String(raw.dropFirst(prefix.count)).removingPercentEncoding ?? ""
        return id.isEmpty ? nil : id
    }
}

/// Decyzje kafelka Now Playing na danych z MediaRemote (sekcje 6–8 specu).
enum NowPlayingSelection {
    static let musicBundle = "com.apple.Music"
    private static let appleScriptBundles: Set<String> = ["com.spotify.client", musicBundle]

    static func choose(players: [MRPlayer], previousBundle: String?) -> MRPlayer? {
        let candidates = players.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let playing = candidates.filter { $0.rate > 0 }
        let pool = playing.isEmpty ? candidates : playing
        guard let newest = pool.map(\.timestamp).max() else { return nil }
        let tied = pool.filter { $0.timestamp == newest }
        if let previousBundle, let previous = tied.first(where: { $0.bundle == previousBundle }) {
            return previous
        }
        return tied.first
    }

    /// MediaRemote podaje pozycję z chwili `timestamp`, więc dla grającego dokładamy czas od tamtej chwili.
    static func position(of player: MRPlayer, now: Double) -> Double {
        var value = player.elapsed
        if player.rate > 0, player.timestamp > 0 {
            value += max(0, now - player.timestamp) * player.rate
        }
        value = max(0, value)
        if player.duration > 0 {
            value = min(player.duration, value)
        }
        return value
    }

    static func artworkURL(for player: MRPlayer, hasArtwork: Bool, musicLookup: () -> String) -> String {
        if hasArtwork, !player.artworkId.isEmpty {
            return ArtworkURL.make(artworkId: player.artworkId)
        }
        if player.bundle == musicBundle {
            return musicLookup()
        }
        return ""
    }

    static func nowPlayingData(for player: MRPlayer, now: Double, artworkURL: String) -> NowPlayingData {
        NowPlayingData(
            playing: true,
            app: player.name.isEmpty ? player.bundle : player.name,
            track: player.title,
            artist: player.artist,
            duration: player.duration,
            position: position(of: player, now: now),
            state: player.rate > 0 ? "playing" : "paused",
            artworkURL: artworkURL
        )
    }

    /// Komendę, której pomocnik nie przyjął, powtarzamy przez AppleScript tylko tam, gdzie AppleScript działa.
    static func shouldFallBackToAppleScript(bundle: String) -> Bool {
        appleScriptBundles.contains(bundle)
    }
}
