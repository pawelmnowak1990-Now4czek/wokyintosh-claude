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
