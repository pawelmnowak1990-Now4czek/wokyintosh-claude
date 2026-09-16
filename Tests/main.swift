import Foundation

var failures = 0
var checks = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(label): otrzymano \(actual), oczekiwano \(expected)")
    }
}

func assertClose(_ actual: Double, _ expected: Double, _ label: String, tolerance: Double = 0.05) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL \(label): otrzymano \(actual), oczekiwano \(expected) ±\(tolerance)")
    }
}

func finishTests() -> Never {
    print(failures == 0 ? "OK: \(checks) sprawdzeń" : "\(failures) z \(checks) sprawdzeń nie przeszło")
    exit(failures == 0 ? 0 : 1)
}

// CPU: kolejność wartości jest taka jak w host_cpu_load_info,
// czyli [user, system, idle, nice].
assertClose(
    SystemMonitor.cpuPercent(previous: [100, 50, 800, 50], current: [200, 100, 1600, 100]),
    20.0,
    "cpu: normalna różnica"
)
assertClose(
    SystemMonitor.cpuPercent(previous: [UInt32.max - 10, 0, 0, 0], current: [9, 0, 100, 0]),
    16.666,
    "cpu: przekręcenie licznika"
)
assertClose(
    SystemMonitor.cpuPercent(previous: [5, 5, 5, 5], current: [5, 5, 5, 5]),
    0.0,
    "cpu: brak zmian"
)

// RAM: liczby z tego Maca z 2026-09-15 (strona 16 KiB, 16 GiB pamięci).
// internal 336758, purgeable 6404, wired 142265, compressor 263200 stron.
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 336_758, purgeablePages: 6_404,
        wiredPages: 142_265, compressorPages: 263_200,
        pageSize: 16_384, totalBytes: 17_179_869_184
    ),
    70.17,
    "ram: wzór jak w Monitorze aktywności",
    tolerance: 0.1
)
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 10, purgeablePages: 999,
        wiredPages: 0, compressorPages: 0,
        pageSize: 16_384, totalBytes: 17_179_869_184
    ),
    0.0,
    "ram: purgeable większe od internal nie daje ujemnego wyniku"
)
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 1, purgeablePages: 0,
        wiredPages: 0, compressorPages: 0,
        pageSize: 16_384, totalBytes: 0
    ),
    0.0,
    "ram: zerowa pamięć całkowita"
)

// Klasyfikacja sesji Claude Code. Czas w milisekundach, jak w plikach stanu.
let now: Double = 1_800_000_000_000
let minute: Double = 60_000

func probe(
    pid: Int32 = 100,
    kind: String = "interactive",
    status: String,
    startedAgo: Double = 60 * minute,
    statusAgo: Double = 0,
    updatedAgo: Double? = nil
) -> ClaudeProbe {
    ClaudeProbe(
        pid: pid,
        kind: kind,
        status: status,
        startedAt: now - startedAgo,
        updatedAt: now - (updatedAgo ?? statusAgo),
        statusUpdatedAt: now - statusAgo
    )
}

func classify(_ probes: [ClaudeProbe], alive: Bool = true) -> ClaudeSnapshot {
    ClaudeLogic.classify(
        probes: probes,
        nowMilliseconds: now,
        windowSeconds: 15 * 60,
        isAlive: { _ in alive }
    )
}

assertEqual(
    classify([probe(status: "waiting")]),
    ClaudeSnapshot(available: true, attention: 1, waiting: 1, finished: 0, busy: 0),
    "sesja czekająca na odpowiedź"
)
assertEqual(
    classify([probe(status: "idle", statusAgo: 5 * minute)]),
    ClaudeSnapshot(available: true, attention: 1, waiting: 0, finished: 1, busy: 0),
    "sesja skończona w oknie 15 minut"
)
assertEqual(
    classify([probe(status: "idle", statusAgo: 40 * minute)]),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "sesja skończona poza oknem"
)
assertEqual(
    classify([probe(status: "idle", startedAgo: 5_000, statusAgo: 3_000)]),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "świeżo otwarta sesja, która nigdy nie pracowała"
)
assertEqual(
    classify([probe(status: "busy"), probe(pid: 101, status: "shell")]),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 2),
    "busy i shell liczą się jako praca"
)
assertEqual(
    classify([probe(status: "busy", statusAgo: 30 * minute, updatedAgo: 10 * minute)]),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "zawieszony busy (updatedAt nowszy niż statusUpdatedAt) jest pomijany"
)
assertEqual(
    classify([probe(status: "waiting")], alive: false),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "martwy proces jest pomijany"
)
assertEqual(
    classify([probe(kind: "background", status: "waiting")]),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "sesje inne niż interactive są pomijane"
)
assertEqual(
    classify([probe(status: "waiting"), probe(pid: 101, status: "idle", statusAgo: 2 * minute), probe(pid: 102, status: "busy")]),
    ClaudeSnapshot(available: true, attention: 2, waiting: 1, finished: 1, busy: 1),
    "mieszanka stanów sumuje się poprawnie"
)

// Odczyt katalogu: pliki zapisujemy do katalogu tymczasowego, nigdy do ~/.claude.
let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("wokyintosh-tests-\(UUID().uuidString)")
try! fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

func writeProbe(_ name: String, _ json: String) {
    try! json.write(to: sandbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

writeProbe("100.json", """
{"pid":100,"kind":"interactive","status":"waiting","startedAt":\(now - 60 * minute),"updatedAt":\(now),"statusUpdatedAt":\(now)}
""")
writeProbe("101.json", "{ to nie jest json")
writeProbe("102.key", "klucz, nie json")

let monitor = ClaudeMonitor(directory: sandbox, windowSeconds: 15 * 60, isAlive: { _ in true })
assertEqual(
    monitor.snapshot(nowMilliseconds: now),
    ClaudeSnapshot(available: true, attention: 1, waiting: 1, finished: 0, busy: 0),
    "odczyt katalogu: uszkodzony plik i plik .key są pomijane"
)

let missing = ClaudeMonitor(
    directory: sandbox.appendingPathComponent("nie-ma-takiego"),
    windowSeconds: 15 * 60,
    isAlive: { _ in true }
)
assertEqual(missing.snapshot(nowMilliseconds: now), ClaudeSnapshot.unavailable, "brak katalogu daje available=false")

let emptyDir = sandbox.appendingPathComponent("pusty")
try! fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
assertEqual(
    ClaudeMonitor(directory: emptyDir, windowSeconds: 15 * 60, isAlive: { _ in true }).snapshot(nowMilliseconds: now),
    ClaudeSnapshot(available: true, attention: 0, waiting: 0, finished: 0, busy: 0),
    "pusty katalog to zero sesji, nie brak danych"
)

let brokenOnly = sandbox.appendingPathComponent("uszkodzone")
try! fm.createDirectory(at: brokenOnly, withIntermediateDirectories: true)
try! "{ nie json".write(to: brokenOnly.appendingPathComponent("200.json"), atomically: true, encoding: .utf8)
assertEqual(
    ClaudeMonitor(directory: brokenOnly, windowSeconds: 15 * 60, isAlive: { _ in true }).snapshot(nowMilliseconds: now),
    ClaudeSnapshot.unavailable,
    "same uszkodzone pliki dają available=false"
)

try? fm.removeItem(at: sandbox)

finishTests()
