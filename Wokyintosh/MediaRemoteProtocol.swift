import Foundation

/// Stan jednego odtwarzacza z linii `state` pomocnika MediaRemote.
struct MRPlayer: Equatable {
    let bundle: String
    let name: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let rate: Double
    /// Sekundy od 1970-01-01; chwila, której dotyczy `elapsed`.
    let timestamp: Double
    let artworkId: String
}

/// Bajty okładki z linii `artwork`.
struct MRArtwork: Equatable {
    let bundle: String
    let artworkId: String
    let mime: String
    let data: Data
}

/// Komendy, które pomocnik przyjmuje. Nic spoza tej listy nie trafia do MediaRemote.
enum MRCommand: String {
    case togglePlayPause
    case nextTrack
    case previousTrack
}

/// Wynik komendy wysłanej do pomocnika (sekcja 8 specu). Rozróżnia realne odrzucenie
/// (bezpieczne do powtórki przez AppleScript) od timeoutu (MediaRemote mogła już wykonać
/// komendę, więc powtórka zdublowałaby akcję).
enum HelperCommandResult: Equatable {
    /// `ack` z `ok:true`.
    case ok
    /// `ack` z `ok:false`, komenda niewysyłalna (brak wejścia / bundle spoza obecnych
    /// odtwarzaczy / błąd zapisu) albo oczekujące komendy unieważnione przez koniec pomocnika.
    case rejected
    /// Brak `ack` w czasie `ackTimeout`.
    case timedOut
}

enum HelperMessage: Equatable {
    case hello(version: Int)
    case state([MRPlayer])
    case artwork(MRArtwork)
    case ack(cmd: String, bundle: String, ok: Bool)
    case error(reason: String, symbol: String)
}

/// Format wymiany z pomocnikiem, sekcja 5 specu.
enum MediaRemoteProtocol {
    static let maxLineBytes = 4 * 1024 * 1024

    /// Zwraca nil dla linii uszkodzonej, za długiej albo nieznanego typu.
    static func parse(line: Data) -> HelperMessage? {
        guard
            !line.isEmpty,
            line.count <= maxLineBytes,
            let object = try? JSONSerialization.jsonObject(with: line),
            let json = object as? [String: Any],
            let type = json["type"] as? String
        else { return nil }

        switch type {
        case "hello":
            return .hello(version: int(json["version"]))
        case "state":
            let raw = json["players"] as? [[String: Any]] ?? []
            return .state(raw.compactMap(player))
        case "artwork":
            let bundle = string(json["bundle"])
            let artworkId = string(json["artworkId"])
            guard
                !bundle.isEmpty,
                !artworkId.isEmpty,
                let data = Data(base64Encoded: string(json["data"])),
                !data.isEmpty
            else { return nil }
            let mime = string(json["mime"])
            return .artwork(MRArtwork(
                bundle: bundle,
                artworkId: artworkId,
                mime: mime.isEmpty ? "image/jpeg" : mime,
                data: data
            ))
        case "ack":
            return .ack(cmd: string(json["cmd"]), bundle: string(json["bundle"]), ok: json["ok"] as? Bool ?? false)
        case "error":
            return .error(reason: string(json["reason"]), symbol: string(json["symbol"]))
        default:
            return nil
        }
    }

    static func encode(command: MRCommand, bundle: String) -> Data {
        let object = ["cmd": command.rawValue, "bundle": bundle]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func command(for action: MediaAction) -> MRCommand {
        switch action {
        case .previous: return .previousTrack
        case .playPause: return .togglePlayPause
        case .next: return .nextTrack
        }
    }

    private static func player(_ json: [String: Any]) -> MRPlayer? {
        let bundle = string(json["bundle"])
        guard !bundle.isEmpty else { return nil }
        return MRPlayer(
            bundle: bundle,
            name: string(json["name"]),
            title: string(json["title"]),
            artist: string(json["artist"]),
            album: string(json["album"]),
            duration: double(json["duration"]),
            elapsed: double(json["elapsed"]),
            rate: double(json["rate"]),
            timestamp: double(json["timestamp"]),
            artworkId: string(json["artworkId"])
        )
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
    private static func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}
