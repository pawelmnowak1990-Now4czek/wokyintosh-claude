import AppKit
import Foundation

enum MediaAction: String {
    case previous
    case playPause
    case next
}

enum MediaPlayerApp: String {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }
}

enum MediaControl {
    /// Komenda AppleScript dla danej akcji i odtwarzacza.
    static func script(action: MediaAction, player: MediaPlayerApp) -> String {
        let command: String
        switch action {
        case .previous: command = "previous track"
        case .playPause: command = "playpause"
        case .next: command = "next track"
        }
        return "tell application \"\(player.rawValue)\" to \(command)"
    }

    /// Mapowanie nazwy akcji przysłanej ze strony. Cokolwiek spoza listy
    /// jest odrzucane, więc strona nie może wykonać dowolnego AppleScriptu.
    static func action(from raw: String) -> MediaAction? {
        switch raw {
        case "previous": return .previous
        case "playpause": return .playPause
        case "next": return .next
        default: return nil
        }
    }

    /// Odtwarzacz, do którego trafi komenda: Spotify ma pierwszeństwo,
    /// tak samo jak przy odczycie Now Playing.
    static func activePlayer() -> MediaPlayerApp? {
        for player in [MediaPlayerApp.spotify, .music] where
            !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty {
            return player
        }
        return nil
    }

    @discardableResult
    static func perform(_ action: MediaAction) -> Bool {
        guard let player = activePlayer() else { return false }
        guard let script = NSAppleScript(source: script(action: action, player: player)) else { return false }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            NSLog("Wokyintosh: komenda odtwarzacza nie powiodła się: \(error)")
            return false
        }
        return true
    }
}
