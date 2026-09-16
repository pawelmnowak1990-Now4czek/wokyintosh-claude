import Foundation

/// Rekord z pliku stanu sesji Claude Code (~/.claude/sessions/<pid>.json).
/// Format jest nieudokumentowany, więc wszystkie pola poza pid są opcjonalne
/// i nieznane wartości po prostu nie są liczone.
struct ClaudeProbe: Decodable, Equatable {
    let pid: Int32
    let kind: String?
    let status: String?
    let startedAt: Double?
    let updatedAt: Double?
    let statusUpdatedAt: Double?
}

/// To, co trafia do warstwy widoku jako JSON.
struct ClaudeSnapshot: Encodable, Equatable {
    let available: Bool
    let attention: Int
    let waiting: Int
    let finished: Int
    let busy: Int

    static let unavailable = ClaudeSnapshot(
        available: false, attention: 0, waiting: 0, finished: 0, busy: 0
    )
}

enum ClaudeLogic {
    /// Sesja, która zmieniła status na idle szybciej niż po tylu milisekundach
    /// od startu, nigdy nie pracowała — to świeżo otwarte okno.
    static let minimumWorkMilliseconds: Double = 10_000

    static func classify(
        probes: [ClaudeProbe],
        nowMilliseconds now: Double,
        windowSeconds: Double,
        isAlive: (Int32) -> Bool
    ) -> ClaudeSnapshot {
        var waiting = 0
        var finished = 0
        var busy = 0

        for probe in probes {
            guard probe.kind == "interactive", isAlive(probe.pid) else { continue }
            guard let status = probe.status, let statusUpdatedAt = probe.statusUpdatedAt else { continue }

            switch status {
            case "waiting":
                waiting += 1

            case "busy", "shell":
                // anthropics/claude-code#87131: po zaparkowaniu tury status
                // zostaje na busy na zawsze. Widać to po tym, że ostatni zapis
                // pliku nie ustawiał statusu.
                if let updatedAt = probe.updatedAt, updatedAt > statusUpdatedAt { continue }
                busy += 1

            case "idle":
                let ageSeconds = (now - statusUpdatedAt) / 1000
                let workedAtAll = statusUpdatedAt - (probe.startedAt ?? statusUpdatedAt) > minimumWorkMilliseconds
                if ageSeconds >= 0, ageSeconds <= windowSeconds, workedAtAll { finished += 1 }

            default:
                break
            }
        }

        return ClaudeSnapshot(
            available: true,
            attention: waiting + finished,
            waiting: waiting,
            finished: finished,
            busy: busy
        )
    }
}

/// Czyta pliki stanu sesji Claude Code. Tylko odczyt, nic nie zapisuje.
final class ClaudeMonitor {
    private let directory: URL
    private let windowSeconds: Double
    private let isAlive: (Int32) -> Bool
    private let decoder = JSONDecoder()

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        windowSeconds: Double = ClaudeMonitor.configuredWindowSeconds(),
        isAlive: @escaping (Int32) -> Bool = ClaudeMonitor.processIsAlive
    ) {
        self.directory = directory
        self.windowSeconds = windowSeconds
        self.isAlive = isAlive
    }

    /// Okno "skończyła niedawno". Zmiana bez rekompilacji:
    /// defaults write com.pawelnowak.wokyintosh ClaudeFinishedWindowMinutes 20
    static func configuredWindowSeconds() -> Double {
        let stored = UserDefaults.standard.object(forKey: "ClaudeFinishedWindowMinutes") as? NSNumber
        let minutes = stored?.doubleValue ?? 15
        return max(1, minutes) * 60
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func snapshot(nowMilliseconds now: Double = Date().timeIntervalSince1970 * 1000) -> ClaudeSnapshot {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return .unavailable
        }

        let jsonNames = names.filter { $0.hasSuffix(".json") }
        var probes: [ClaudeProbe] = []

        for name in jsonNames {
            guard
                let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                let probe = try? decoder.decode(ClaudeProbe.self, from: data)
            else { continue }
            probes.append(probe)
        }

        if probes.isEmpty && !jsonNames.isEmpty { return .unavailable }

        return ClaudeLogic.classify(
            probes: probes,
            nowMilliseconds: now,
            windowSeconds: windowSeconds,
            isAlive: isAlive
        )
    }
}
