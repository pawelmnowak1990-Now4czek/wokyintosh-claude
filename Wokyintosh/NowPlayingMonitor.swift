import AppKit
import Foundation

struct NowPlayingData: Codable, Equatable {
    let playing: Bool
    let app: String
    let track: String
    let artist: String
    let duration: Double
    let position: Double
    let state: String
    let artworkURL: String

    enum CodingKeys: String, CodingKey {
        case playing, app, track, artist, duration, position, state
        case artworkURL = "artwork_url"
    }

    static let empty = NowPlayingData(
        playing: false, app: "", track: "", artist: "",
        duration: 0, position: 0, state: "stopped", artworkURL: ""
    )
}

final class NowPlayingMonitor {
    private let helper: MediaRemoteHelper?
    private let clock: () -> Date
    private let selectionLock = NSLock()
    private var selectedBundle: String?
    private var artworkCache: [String: String] = [:]

    init(helper: MediaRemoteHelper? = nil, clock: @escaping () -> Date = Date.init) {
        self.helper = helper
        self.clock = clock
    }

    /// AppleScript sklejając liczbę z tekstem używa separatora dziesiętnego
    /// z ustawień systemu, więc poza locale amerykańskim dostajemy
    /// "214,740997314453". Double(_:) czyta tylko kropkę i zwracał nil,
    /// przez co czas i długość utworu były zerowe, a pasek postępu stał w miejscu.
    static func parseNumber(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(trimmed) { return value }
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Najpierw systemowe Now Playing z pomocnika, przy braku świeżych danych AppleScript (sekcja 9 specu).
    func snapshot() -> NowPlayingData {
        mediaRemoteSnapshot() ?? appleScriptSnapshot()
    }

    /// Komenda z przycisku: przez pomocnika do wybranego odtwarzacza, a gdy się nie da,
    /// AppleScript dla Spotify i Music (sekcja 8 specu). `completion` na `completionQueue`.
    func perform(_ action: MediaAction, completionQueue: DispatchQueue = .main, completion: @escaping () -> Void) {
        let viaAppleScript = {
            DispatchQueue.main.async {
                MediaControl.perform(action)
                completionQueue.async(execute: completion)
            }
        }
        guard let helper, let bundle = currentSelection(), helper.freshPlayers() != nil else {
            viaAppleScript()
            return
        }
        helper.send(MediaRemoteProtocol.command(for: action), bundle: bundle) { ok in
            if ok {
                completionQueue.async(execute: completion)
            } else if NowPlayingSelection.shouldFallBackToAppleScript(bundle: bundle) {
                viaAppleScript()
            } else {
                NSLog("Wokyintosh: \(bundle) nie przyjął komendy \(action.rawValue)")
                completionQueue.async(execute: completion)
            }
        }
    }

    private func mediaRemoteSnapshot() -> NowPlayingData? {
        guard
            let helper,
            let players = helper.freshPlayers(),
            let player = NowPlayingSelection.choose(players: players, previousBundle: currentSelection())
        else {
            updateSelection(nil)
            return nil
        }
        updateSelection(player)
        let url = NowPlayingSelection.artworkURL(
            for: player,
            hasArtwork: helper.artwork(id: player.artworkId) != nil,
            musicLookup: { self.artworkURL(track: player.title, artist: player.artist) }
        )
        return NowPlayingSelection.nowPlayingData(for: player, now: clock().timeIntervalSince1970, artworkURL: url)
    }

    private func currentSelection() -> String? {
        selectionLock.lock()
        defer { selectionLock.unlock() }
        return selectedBundle
    }

    /// Zapamiętuje wybrane źródło i loguje zmianę, żeby dało się ją sprawdzić bez patrzenia na ekran.
    private func updateSelection(_ player: MRPlayer?) {
        selectionLock.lock()
        let changed = selectedBundle != player?.bundle
        selectedBundle = player?.bundle
        selectionLock.unlock()
        if changed {
            NSLog("Wokyintosh: Now Playing źródło \(player.map { "\($0.name) (\($0.bundle))" } ?? "AppleScript")")
        }
    }

    private func appleScriptSnapshot() -> NowPlayingData {
        if isRunning(bundleID: "com.spotify.client"),
           let spotify = spotifySnapshot() {
            return spotify
        }

        if isRunning(bundleID: "com.apple.Music"),
           let music = musicSnapshot() {
            return music
        }

        return .empty
    }

    private func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    private func spotifySnapshot() -> NowPlayingData? {
        let script = """
        tell application "Spotify"
            if player state is playing or player state is paused then
                set t to name of current track
                set a to artist of current track
                set d to duration of current track / 1000
                set p to player position
                set s to player state as text
                try
                    set u to artwork url of current track
                on error
                    set u to ""
                end try
                return t & "|||RD|||" & a & "|||RD|||" & d & "|||RD|||" & p & "|||RD|||" & s & "|||RD|||" & u
            end if
        end tell
        return ""
        """

        guard let result = runAppleScript(script), !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "|||RD|||")
        guard parts.count == 6 else { return nil }

        return NowPlayingData(
            playing: true,
            app: "Spotify",
            track: parts[0],
            artist: parts[1],
            duration: NowPlayingMonitor.parseNumber(parts[2]),
            position: NowPlayingMonitor.parseNumber(parts[3]),
            state: parts[4],
            artworkURL: parts[5]
        )
    }

    private func musicSnapshot() -> NowPlayingData? {
        let script = """
        tell application "Music"
            if player state is playing or player state is paused then
                set t to name of current track
                set a to artist of current track
                set d to duration of current track
                set p to player position
                set s to player state as text
                return t & "|||RD|||" & a & "|||RD|||" & d & "|||RD|||" & p & "|||RD|||" & s
            end if
        end tell
        return ""
        """

        guard let result = runAppleScript(script), !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "|||RD|||")
        guard parts.count == 5 else { return nil }

        let track = parts[0]
        let artist = parts[1]

        return NowPlayingData(
            playing: true,
            app: "Music",
            track: track,
            artist: artist,
            duration: NowPlayingMonitor.parseNumber(parts[2]),
            position: NowPlayingMonitor.parseNumber(parts[3]),
            state: parts[4],
            artworkURL: artworkURL(track: track, artist: artist)
        )
    }

    private func artworkURL(track: String, artist: String) -> String {
        let key = "\(artist.lowercased())|\(track.lowercased())"
        if let cached = artworkCache[key] { return cached }

        let semaphore = DispatchSemaphore(value: 0)
        var resultURL = ""

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(track)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components.url else { return "" }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [[String: Any]],
                let first = results.first,
                var art = first["artworkUrl100"] as? String
            else { return }

            art = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            resultURL = art
        }.resume()

        _ = semaphore.wait(timeout: .now() + 2.5)
        artworkCache[key] = resultURL
        return resultURL
    }
}
