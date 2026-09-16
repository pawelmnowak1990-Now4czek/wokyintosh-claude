# Kafelek Claude w Wokyintoshu — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork Wokyintosha pokazuje na ekranie Wokyis kafelek z liczbą sesji Claude Code wymagających uwagi, animowany gdy Claude pracuje, plus cztery poprawki (RAM, CPU, okno na właściwym ekranie, autostart).

**Architecture:** Natywna aplikacja AppKit + WKWebView. Swift zbiera dane i wysyła je do strony przez `evaluateJavaScript`, HTML/CSS/JS tylko rysuje. Nowy `ClaudeMonitor.swift` czyta pliki stanu sesji Claude Code z `~/.claude/sessions/*.json` na własnym timerze 2 s, niezależnie od `SystemMonitor`. Logika (klasyfikacja sesji, wzory RAM i CPU) siedzi w czystych funkcjach bez AppKit, żeby dało się je testować bez uruchamiania aplikacji.

**Tech Stack:** Swift 5 (Apple Command Line Tools, bez Xcode), AppKit, WebKit, CoreLocation, ServiceManagement, zwykły HTML/CSS/JS bez bibliotek.

**Spec:** `docs/superpowers/specs/2026-09-16-wokyintosh-claude-tile-design.md`

## Global Constraints

- macOS 13.0+, target `$(uname -m)-apple-macos13.0`, build wyłącznie przez Apple Command Line Tools.
- Zero zależności zewnętrznych: bez SPM, bez npm, bez CDN. Tylko frameworki systemowe.
- Aplikacja nie zapisuje niczego w `~/.claude`. Katalog sesji jest tylko do odczytu.
- Żadnych nowych połączeń sieciowych.
- Teksty w interfejsie po angielsku, jak reszta aplikacji. Komentarze i commity na `feature/claude-tile` po polsku, commity na `main` po angielsku (idą do PR do oryginału).
- Commity bez linii `Co-Authored-By`.
- Grafika 1-bitowa, kolory wyłącznie ze zmiennych `--ink`, `--paper`, `--paper2`, `--white`.
- `LICENSE` i nota copyright Salara Farahaniego zostają nietknięte (wymóg MIT).
- Animacja gwiazdki: wariant B (gwiazda ↔ znak „X”), 600 ms na klatkę. Miganie odwróconej liczby: 2 s.
- Domyślne okno „skończyła niedawno”: 15 minut, klucz `UserDefaults` `ClaudeFinishedWindowMinutes`.
- Praca na gałęzi `feature/claude-tile`, poza zadaniem 10.

**Doprecyzowanie względem specu:** pakiet `updateClaude` zamiast flagi `working: Bool` wysyła licznik `busy: Int` (liczba pracujących sesji). Dzięki temu podpis „N working” ze specu ma skąd wziąć liczbę, a animacja włącza się przy `busy > 0`.

---

### Task 1: Szkielet testów i poprawka licznika CPU

**Files:**
- Create: `Tests/main.swift`
- Create: `Run Tests.command`
- Modify: `Wokyintosh/SystemMonitor.swift:36-66`

**Interfaces:**
- Consumes: nic.
- Produces: `SystemMonitor.cpuPercent(previous:current:) -> Double` (statyczna, czysta), `assertEqual(_:_:_:)` i `finishTests()` w `Tests/main.swift`.

- [ ] **Step 1: Write the failing test**

Utwórz `Tests/main.swift`:

```swift
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

finishTests()
```

Utwórz `Run Tests.command`:

```bash
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"
OUT="$(mktemp -d)/logic-tests"

echo "Kompilacja testów…"
xcrun swiftc -sdk "$SDK" -target "$TARGET" \
  "Tests/main.swift" \
  "Wokyintosh/SystemMonitor.swift" \
  -o "$OUT"

echo "Uruchamianie…"
"$OUT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x "Run Tests.command" && "./Run Tests.command"`
Expected: błąd kompilacji, `type 'SystemMonitor' has no member 'cpuPercent'`.

- [ ] **Step 3: Write minimal implementation**

W `Wokyintosh/SystemMonitor.swift` dodaj czystą funkcję wewnątrz `final class SystemMonitor` (nad `cpuUsage()`):

```swift
    /// Procent zajętości CPU z dwóch odczytów liczników jądra.
    /// Kolejność wartości: [user, system, idle, nice] (jak CPU_STATE_*).
    /// Odejmowanie zawijające (&-) daje poprawny wynik również wtedy,
    /// gdy 32-bitowy licznik przekręci się (po ok. 50 dniach pracy).
    static func cpuPercent(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }

        let user = UInt64(current[Int(CPU_STATE_USER)] &- previous[Int(CPU_STATE_USER)])
        let system = UInt64(current[Int(CPU_STATE_SYSTEM)] &- previous[Int(CPU_STATE_SYSTEM)])
        let idle = UInt64(current[Int(CPU_STATE_IDLE)] &- previous[Int(CPU_STATE_IDLE)])
        let nice = UInt64(current[Int(CPU_STATE_NICE)] &- previous[Int(CPU_STATE_NICE)])

        let total = Double(user + system + idle + nice)
        guard total > 0 else { return 0 }

        return max(0, min(100, Double(user + system + nice) / total * 100))
    }
```

Podmień końcówkę `cpuUsage()` (od `let user = current[...]` do `return max(...)`) na:

```swift
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return 0 }

        return SystemMonitor.cpuPercent(previous: previous, current: current)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `"./Run Tests.command"`
Expected: `OK: 3 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add "Run Tests.command" Tests/main.swift Wokyintosh/SystemMonitor.swift
git commit -m "fix: licznik CPU odporny na przekręcenie liczników jądra"
```

---

### Task 2: Poprawka liczenia RAM

**Files:**
- Modify: `Wokyintosh/SystemMonitor.swift:68-91`
- Modify: `Tests/main.swift`

**Interfaces:**
- Consumes: `assertClose` z zadania 1.
- Produces: `SystemMonitor.memoryPercent(internalPages:purgeablePages:wiredPages:compressorPages:pageSize:totalBytes:) -> Double`.

- [ ] **Step 1: Write the failing test**

W `Tests/main.swift`, przed `finishTests()`, dodaj:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `"./Run Tests.command"`
Expected: błąd kompilacji, `type 'SystemMonitor' has no member 'memoryPercent'`.

- [ ] **Step 3: Write minimal implementation**

W `Wokyintosh/SystemMonitor.swift` dodaj obok `cpuPercent`:

```swift
    /// Procent zajętej pamięci liczony tak, jak "Użyta pamięć" w Monitorze aktywności:
    /// pamięć aplikacji (internal bez purgeable) + wired + skompresowana.
    /// Stron `inactive` i `active` nie wliczamy, bo to głównie cache plików,
    /// który system oddaje od ręki.
    static func memoryPercent(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64
    ) -> Double {
        guard totalBytes > 0 else { return 0 }

        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let used = (appPages + wiredPages + compressorPages) * pageSize

        return max(0, min(100, Double(used) / Double(totalBytes) * 100))
    }
```

Podmień w `memoryUsage()` blok od `let pageSize = UInt64(vm_kernel_page_size)` do `return max(...)` na:

```swift
        return SystemMonitor.memoryPercent(
            internalPages: UInt64(vmStats.internal_page_count),
            purgeablePages: UInt64(vmStats.purgeable_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressorPages: UInt64(vmStats.compressor_page_count),
            pageSize: UInt64(vm_kernel_page_size),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `"./Run Tests.command"`
Expected: `OK: 6 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Tests/main.swift Wokyintosh/SystemMonitor.swift
git commit -m "fix: RAM liczony jak w Monitorze aktywności zamiast zawyżonych ~95%"
```

---

### Task 3: Klasyfikacja sesji Claude Code

**Files:**
- Create: `Wokyintosh/ClaudeMonitor.swift`
- Modify: `Tests/main.swift`
- Modify: `Run Tests.command`

**Interfaces:**
- Consumes: `assertEqual`, `finishTests` z zadania 1.
- Produces: `ClaudeProbe` (Decodable), `ClaudeSnapshot` (Encodable, Equatable), `ClaudeLogic.classify(probes:nowMilliseconds:windowSeconds:isAlive:) -> ClaudeSnapshot`.

- [ ] **Step 1: Write the failing test**

W `Run Tests.command` dopisz nowy plik do listy kompilowanych, po `SystemMonitor.swift`:

```bash
  "Wokyintosh/ClaudeMonitor.swift" \
```

W `Tests/main.swift`, przed `finishTests()`, dodaj:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `"./Run Tests.command"`
Expected: błąd kompilacji, `cannot find 'ClaudeProbe' in scope`.

- [ ] **Step 3: Write minimal implementation**

Utwórz `Wokyintosh/ClaudeMonitor.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `"./Run Tests.command"`
Expected: `OK: 15 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/ClaudeMonitor.swift Tests/main.swift "Run Tests.command"
git commit -m "feat: klasyfikacja sesji Claude Code z plików stanu"
```

---

### Task 4: Odczyt katalogu sesji

**Files:**
- Modify: `Wokyintosh/ClaudeMonitor.swift`
- Modify: `Tests/main.swift`

**Interfaces:**
- Consumes: `ClaudeProbe`, `ClaudeSnapshot`, `ClaudeLogic.classify` z zadania 3.
- Produces: `ClaudeMonitor(directory:windowSeconds:isAlive:)` (wszystkie trzy z wartościami domyślnymi), `ClaudeMonitor.snapshot(nowMilliseconds:) -> ClaudeSnapshot`, `ClaudeMonitor.configuredWindowSeconds() -> Double`, `ClaudeMonitor.processIsAlive(_:) -> Bool`.

- [ ] **Step 1: Write the failing test**

W `Tests/main.swift`, przed `finishTests()`, dodaj:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `"./Run Tests.command"`
Expected: błąd kompilacji, `cannot find 'ClaudeMonitor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Dopisz na końcu `Wokyintosh/ClaudeMonitor.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `"./Run Tests.command"`
Expected: `OK: 19 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/ClaudeMonitor.swift Tests/main.swift
git commit -m "feat: odczyt katalogu sesji Claude Code z obsługą braku danych"
```

---

### Task 5: Podpięcie do mostka i buildu

**Files:**
- Modify: `Wokyintosh/NativeBridge.swift:1-45`
- Modify: `Build Wokyintosh.command:60-75`

**Interfaces:**
- Consumes: `ClaudeMonitor`, `ClaudeSnapshot` z zadania 4.
- Produces: wywołanie `window.WokyintoshNative.updateClaude(<json>)` co 2 s.

- [ ] **Step 1: Dodaj nowy plik do skryptu budującego**

W `Build Wokyintosh.command`, w liście plików przekazywanych do `swiftc`, po linii z `SystemMonitor.swift` dodaj:

```bash
  "$SRC/ClaudeMonitor.swift" \
```

- [ ] **Step 2: Rozszerz mostek**

W `Wokyintosh/NativeBridge.swift` dodaj pole obok pozostałych monitorów:

```swift
    private let claude = ClaudeMonitor()
```

oraz timer obok pozostałych:

```swift
    private var claudeTimer: Timer?
```

W `start()`, po `pushWeather()`, dodaj `pushClaude()`, a po definicji `weatherTimer`:

```swift
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pushClaude()
        }
```

W bloku dodającym timery do pętli:

```swift
        RunLoop.main.add(claudeTimer!, forMode: .common)
```

W `stop()`:

```swift
        claudeTimer?.invalidate()
```

Oraz nowa metoda obok `pushNowPlaying()`:

```swift
    private func pushClaude() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let data = self.claude.snapshot()
            self.send(function: "window.WokyintoshNative.updateClaude", payload: data)
        }
    }
```

- [ ] **Step 3: Zbuduj i sprawdź, że dane lecą do strony**

Run: `"./Build Wokyintosh.command"`
Expected: build przechodzi, aplikacja się uruchamia. W konsoli (`Console.app`, filtr `Wokyintosh`) nie ma błędów JavaScriptu o braku `updateClaude` — strona jeszcze jej nie definiuje, więc `evaluateJavaScript` po prostu nic nie robi.

- [ ] **Step 4: Sprawdź, że testy dalej przechodzą**

Run: `"./Run Tests.command"`
Expected: `OK: 19 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/NativeBridge.swift "Build Wokyintosh.command"
git commit -m "feat: mostek wysyła stan sesji Claude co 2 sekundy"
```

---

### Task 6: Kafelek w interfejsie

**Files:**
- Modify: `Wokyintosh/Resources/index.html:22-36`
- Modify: `Wokyintosh/Resources/style.css` (dopisanie na końcu pliku)
- Modify: `Wokyintosh/Resources/app.js:55-64`

**Interfaces:**
- Consumes: pakiet `updateClaude` z zadania 5: `{available, attention, waiting, finished, busy}`.
- Produces: elementy `#claude-star`, `#claude-count`, `#claude-caption`.

- [ ] **Step 1: Dodaj kafelek do HTML**

W `Wokyintosh/Resources/index.html`, między zamknięciem `</section>` bloku `time-block` a otwarciem `<section class="weather-card classic-box">`, wstaw:

```html
    <section class="claude-card classic-box">
      <div class="eyebrow">Claude</div>
      <div class="claude-row">
        <svg id="claude-star" class="claude-star" viewBox="-1 -1 13 13" aria-hidden="true">
          <g class="star-a">
            <rect x="5" y="0" width="1" height="3"/><rect x="4" y="3" width="3" height="1"/>
            <rect x="3" y="4" width="5" height="1"/><rect x="0" y="5" width="11" height="1"/>
            <rect x="3" y="6" width="5" height="1"/><rect x="4" y="7" width="3" height="1"/>
            <rect x="5" y="8" width="1" height="3"/>
          </g>
          <g class="star-b">
            <rect x="4" y="4" width="3" height="3"/>
            <rect x="1" y="1" width="1" height="1"/><rect x="2" y="2" width="1" height="1"/><rect x="3" y="3" width="1" height="1"/>
            <rect x="9" y="1" width="1" height="1"/><rect x="8" y="2" width="1" height="1"/><rect x="7" y="3" width="1" height="1"/>
            <rect x="3" y="7" width="1" height="1"/><rect x="2" y="8" width="1" height="1"/><rect x="1" y="9" width="1" height="1"/>
            <rect x="7" y="7" width="1" height="1"/><rect x="8" y="8" width="1" height="1"/><rect x="9" y="9" width="1" height="1"/>
          </g>
        </svg>
        <div id="claude-count" class="claude-count">--</div>
      </div>
      <div id="claude-caption" class="claude-caption">starting…</div>
    </section>
```

- [ ] **Step 2: Dodaj style na końcu `style.css`**

```css


/* Kafelek sesji Claude Code w nagłówku. */
.top{grid-template-columns:1fr 16vw 25.5vw}
.claude-card{display:flex;flex-direction:column;justify-content:center;padding:2.4vh 1.1vw}
.claude-row{display:flex;align-items:center;justify-content:space-between;gap:.7vw;margin-top:.9vh}
.claude-star{width:6vh;height:6vh;flex:0 0 auto;shape-rendering:crispEdges;fill:var(--ink)}
.claude-count{font-size:min(7.2vh,4vw);line-height:1;font-weight:700;padding:0 .3vw}
.claude-caption{margin-top:1.5vh;font-size:min(2.1vh,1.2vw);font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.star-b{opacity:0}
.claude-star.working .star-a{animation:claudeStarA 1.2s steps(1,end) infinite}
.claude-star.working .star-b{animation:claudeStarB 1.2s steps(1,end) infinite}
.claude-count.waiting{animation:claudeBlink 2s steps(1,end) infinite}
@keyframes claudeStarA{0%{opacity:1}50%{opacity:0}100%{opacity:0}}
@keyframes claudeStarB{0%{opacity:0}50%{opacity:1}100%{opacity:1}}
@keyframes claudeBlink{0%{background:var(--ink);color:var(--paper)}50%{background:transparent;color:var(--ink)}100%{background:transparent;color:var(--ink)}}
```

- [ ] **Step 3: Obsłuż pakiet w `app.js`**

W `window.WokyintoshNative`, po metodzie `updateSystem`, dodaj:

```js
  updateClaude(d){
    const star=$('claude-star'),count=$('claude-count'),cap=$('claude-caption');
    if(!d||d.available===false){
      count.textContent='?';count.classList.remove('waiting');
      star.classList.remove('working');cap.textContent='no data';return;
    }
    const w=Number(d.waiting||0),f=Number(d.finished||0),b=Number(d.busy||0);
    const a=Number(d.attention||0)||w+f;
    count.textContent=String(a);
    count.classList.toggle('waiting',w>0);
    star.classList.toggle('working',b>0);
    if(a>0){cap.textContent=w>0?`${w} waiting · ${f} done`:`${f} done`}
    else{cap.textContent=b>0?`${b} working`:'all quiet'}
  },
```

- [ ] **Step 4: Sprawdź składnię i zbuduj**

Run: `node --check Wokyintosh/Resources/app.js && "./Build Wokyintosh.command"`
Expected: `node --check` nic nie wypisuje, build przechodzi, aplikacja startuje.

Sprawdź na żywo, na tej maszynie:
1. Kafelek stoi między zegarem a pogodą i ma tę samą ramkę co reszta.
2. Przy pracującej drugiej sesji Claude Code gwiazdka miga, a podpis mówi `N working`.
3. Po zakończeniu odpowiedzi w drugiej sesji licznik rośnie, a podpis pokazuje `N done`.
4. `defaults write com.salarfarahani.wokyintosh ClaudeFinishedWindowMinutes 1`, restart aplikacji: skończona sesja znika z licznika po minucie. Potem `defaults delete com.salarfarahani.wokyintosh ClaudeFinishedWindowMinutes`.

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/Resources/index.html Wokyintosh/Resources/style.css Wokyintosh/Resources/app.js
git commit -m "feat: kafelek Claude w nagłówku dashboardu"
```

---

### Task 7: Okno na ekranie Wokyis

**Files:**
- Modify: `Wokyintosh/AppDelegate.swift:1-75`

**Interfaces:**
- Consumes: nic.
- Produces: `DashboardWindow` (NSWindow, `canBecomeKey == true`), `AppDelegate.dockScreen() -> NSScreen?`.

- [ ] **Step 1: Dodaj klasę okna i wyszukiwanie ekranu**

Na końcu `Wokyintosh/AppDelegate.swift`, poza klasą `AppDelegate`:

```swift
/// Okno bez ramki musi umieć zostać oknem kluczowym, inaczej Cmd+Q nie działa.
final class DashboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

W `AppDelegate`:

```swift
    /// Ekran dokowanego wyświetlacza: najpierw po nazwie, potem po rozdzielczości.
    private func dockScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let named = screens.first(where: { $0.localizedName == "Wokyis" }) { return named }
        return screens.first(where: { $0.frame.width == 1280 && $0.frame.height == 720 })
    }
```

- [ ] **Step 2: Użyj go przy tworzeniu okna**

W `applicationDidFinishLaunching`, podmień blok od `guard let screen = NSScreen.main ?? NSScreen.screens.first else` do `window.orderFrontRegardless()` na:

```swift
        let dock = dockScreen()

        guard let screen = dock ?? NSScreen.main ?? NSScreen.screens.first else {
            showFatal("No display is available.")
            return
        }

        let frame: NSRect
        let style: NSWindow.StyleMask

        if dock != nil {
            frame = screen.frame
            style = [.borderless]
        } else {
            let visible = screen.visibleFrame
            let width = min(1180.0, visible.width * 0.88)
            let height = min(664.0, visible.height * 0.84)
            frame = NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
            style = [.titled, .closable, .miniaturizable, .resizable]
        }

        window = DashboardWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.title = "Wokyintosh"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(
            calibratedRed: 0.87,
            green: 0.84,
            blue: 0.77,
            alpha: 1.0
        )
        window.contentView = webView
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Bez activate(ignoringOtherApps:) — przy autostarcie dashboard
        // nie ma wyrywać użytkownika z pracy na głównym monitorze.
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
```

Dodaj metodę:

```swift
    @objc private func screensChanged() {
        guard let dock = dockScreen() else { return }
        window.setFrame(dock.frame, display: true)
    }
```

- [ ] **Step 3: Zbuduj i sprawdź**

Run: `"./Build Wokyintosh.command"`
Expected: build przechodzi. Okno pojawia się na ekranie Wokyis, bez ramki, na całej powierzchni, a fokus zostaje tam, gdzie był.

Sprawdź też: odłączenie i podłączenie wyświetlacza (albo `sudo pmset sleepnow` i wybudzenie) wraca oknem na Wokyis, Cmd+Q zamyka aplikację.

- [ ] **Step 4: Sprawdź, że testy dalej przechodzą**

Run: `"./Run Tests.command"`
Expected: `OK: 19 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/AppDelegate.swift
git commit -m "feat: okno ustawia się samo na ekranie Wokyis"
```

---

### Task 8: Autostart po zalogowaniu

**Files:**
- Modify: `Wokyintosh/AppDelegate.swift` (menu + rejestracja)
- Modify: `Build Wokyintosh.command` (framework + instalacja)

**Interfaces:**
- Consumes: `AppDelegate.buildMainMenu()`.
- Produces: pozycja menu „Open at Login”, instalacja do `/Applications/Wokyintosh.app`.

- [ ] **Step 1: Dodaj rejestrację i przełącznik w menu**

W `Wokyintosh/AppDelegate.swift`, na górze pliku:

```swift
import ServiceManagement
```

W `buildMainMenu()`, przed pozycją „Quit Wokyintosh”:

```swift
        let loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        appMenu.addItem(loginItem)
        appMenu.addItem(NSMenuItem.separator())
```

Nowe metody w `AppDelegate`:

```swift
    /// Rejestracja autostartu działa tylko dla aplikacji zainstalowanej
    /// w /Applications. Uruchomiona z build/ albo z Pobranych trafia do
    /// tymczasowej kopii (App Translocation) i rejestracja nie ma sensu.
    private func registerLoginItemIfPossible() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Wokyintosh: nie udało się zarejestrować autostartu: \(error)")
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Wokyintosh: przełączenie autostartu nie powiodło się: \(error)")
        }
    }
```

W `applicationDidFinishLaunching`, na końcu metody:

```swift
        registerLoginItemIfPossible()
```

- [ ] **Step 2: Dodaj framework i instalację do skryptu budującego**

W `Build Wokyintosh.command`, do listy frameworków `swiftc` dopisz:

```bash
  -framework ServiceManagement \
```

Przed blokiem `echo "Opening Wokyintosh…"` wstaw:

```bash
# Instalacja do /Applications — autostart nie zadziała z build/ ani z Pobranych,
# bo macOS uruchamia takie kopie z katalogu tymczasowego (App Translocation).
if [ "${INSTALL:-1}" = "1" ]; then
  echo "Instalowanie do /Applications…"
  pkill -x Wokyintosh 2>/dev/null || true
  rm -rf "/Applications/Wokyintosh.app"
  /usr/bin/ditto "$APP" "/Applications/Wokyintosh.app"
  APP="/Applications/Wokyintosh.app"
fi
```

- [ ] **Step 3: Zbuduj, zainstaluj i sprawdź rejestrację**

Run: `"./Build Wokyintosh.command"`
Expected: build przechodzi, aplikacja ląduje w `/Applications` i stamtąd startuje.

Run: `sfltool dumpbtm 2>/dev/null | grep -i wokyintosh || echo "brak wpisu"`
Expected: wpis o Wokyintoshu. **Jeśli go nie ma, to znana niewiadoma ze specu**: podpis ad-hoc nie wystarcza. Wtedy zapisz wynik w `README.md` w sekcji o autostarcie i dodaj aplikację ręcznie w Ustawieniach → Ogólne → Rzeczy otwierane przy logowaniu.

- [ ] **Step 4: Sprawdź, że testy dalej przechodzą**

Run: `"./Run Tests.command"`
Expected: `OK: 19 sprawdzeń`

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/AppDelegate.swift "Build Wokyintosh.command"
git commit -m "feat: autostart po zalogowaniu i instalacja do /Applications"
```

---

### Task 9: Tożsamość forka

**Files:**
- Modify: `Wokyintosh/Info.plist:11-12,27-28`
- Modify: `Wokyintosh/Resources/index.html:86-89`
- Modify: `README.md`

**Interfaces:**
- Consumes: nic.
- Produces: identyfikator `com.pawelnowak.wokyintosh`.

- [ ] **Step 1: Zmień identyfikator i notę copyright**

W `Wokyintosh/Info.plist`:

```xml
	<key>CFBundleIdentifier</key>
	<string>com.pawelnowak.wokyintosh</string>
```

```xml
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Salar Farahani · fork © 2026 Paweł Nowak</string>
```

- [ ] **Step 2: Zmień stopkę aplikacji**

W `Wokyintosh/Resources/index.html` podmień pierwszy `<span>` stopki na:

```html
    <span>Wokyintosh · fork by Paweł Nowak · based on Wokyintosh by Salar Farahani</span>
```

- [ ] **Step 3: Opisz fork w README**

Na początku `README.md`, zaraz po nagłówku projektu, wstaw:

```markdown
> **To jest fork.** Oryginał: [SalarFarahani/Wokyintosh](https://github.com/SalarFarahani/Wokyintosh),
> licencja MIT, autor Salar Farahani. Zmiany w tym forku:
>
> - kafelek z liczbą sesji Claude Code, które czekają na odpowiedź lub właśnie skończyły pracę,
> - RAM liczony jak w Monitorze aktywności (oryginał wliczał cache plików i pokazywał ~95%),
> - licznik CPU odporny na przekręcenie 32-bitowych liczników jądra,
> - okno samo ustawia się na wyświetlaczu doku Wokyis,
> - autostart po zalogowaniu,
> - identyfikator aplikacji `com.pawelnowak.wokyintosh`, żeby nie kolidować z oryginałem.
```

- [ ] **Step 4: Zbuduj i sprawdź**

Run: `"./Build Wokyintosh.command" && defaults read /Applications/Wokyintosh.app/Contents/Info CFBundleIdentifier`
Expected: `com.pawelnowak.wokyintosh`, stopka w aplikacji pokazuje oba nazwiska.

Uwaga: po zmianie identyfikatora klucz `UserDefaults` czyta się z nowej domeny, więc okno „skończyła niedawno” ustawia się teraz przez `defaults write com.pawelnowak.wokyintosh ClaudeFinishedWindowMinutes 20`.

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/Info.plist Wokyintosh/Resources/index.html README.md
git commit -m "chore: tożsamość forka - identyfikator, stopka i README"
```

---

### Task 10: Gałąź `main` pod PR do oryginału

**Files:**
- Modify: `Tests/main.swift` (wersja na `main`, bez testów kafelka)
- Cherry-pick: commity z zadań 1 i 2

**Interfaces:**
- Consumes: commity „fix: licznik CPU…” i „fix: RAM…”.
- Produces: gałąź `main` z dwiema poprawkami, gotowa na PR.

- [ ] **Step 1: Przenieś poprawki na main**

```bash
CPU=$(git log feature/claude-tile --format=%H --grep="licznik CPU odporny")
RAM=$(git log feature/claude-tile --format=%H --grep="RAM liczony jak")
git checkout main
git cherry-pick -n "$CPU" "$RAM"
```

- [ ] **Step 2: Usuń z `Tests/main.swift` wszystko poza testami CPU i RAM**

Na `main` nie ma `ClaudeMonitor.swift`, więc testy kafelka nie skompilują się. Zostaw w pliku tylko pomocnicze `assertEqual`, `assertClose`, `finishTests` oraz sekcje CPU i RAM. W `Run Tests.command` usuń linię z `ClaudeMonitor.swift`.

- [ ] **Step 3: Uruchom testy**

Run: `"./Run Tests.command"`
Expected: `OK: 6 sprawdzeń`

- [ ] **Step 4: Commit po angielsku (idzie do oryginału)**

```bash
git add -A
git commit -m "fix: correct RAM usage formula and wrap-safe CPU counters

RAM was counting inactive pages (mostly file cache macOS reclaims on
demand), which pinned the meter near 95%. Now it reports app memory
plus wired plus compressed, matching Activity Monitor.

CPU tick deltas used unchecked subtraction on 32-bit kernel counters,
which traps when they wrap after roughly 50 days of uptime."
```

- [ ] **Step 5: Wróć na gałąź roboczą**

```bash
git checkout feature/claude-tile
```

PR do oryginału (`gh pr create --repo SalarFarahani/Wokyintosh`) dopiero po jawnej zgodzie Pawła — to publiczna akcja w cudzym repozytorium.

---

## Weryfikacja końcowa

- [ ] `"./Run Tests.command"` przechodzi na obu gałęziach.
- [ ] RAM w aplikacji zgadza się z „Użytą pamięcią” w Monitorze aktywności w granicach ok. 1 punktu procentowego.
- [ ] Praca w drugiej sesji Claude Code animuje gwiazdkę, zakończenie podbija licznik, po 15 minutach licznik spada.
- [ ] Prośba o zgodę na narzędzie w drugiej sesji ustawia odwróconą, migającą liczbę (niewiadoma ze specu — jeśli nie zadziała, zapisz obserwację w README i rozważ dołożenie hooka `Notification`).
- [ ] Wskazanie `ClaudeMonitor` na nieistniejący katalog daje `?` i `no data`, bez crasha.
- [ ] Okno startuje na Wokyis, bez ramki, po wybudzeniu wraca na miejsce, nie kradnie fokusu.
- [ ] Po restarcie Maca aplikacja startuje sama (albo w README stoi, że trzeba ją dodać ręcznie).
