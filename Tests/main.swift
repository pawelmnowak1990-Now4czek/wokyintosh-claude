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

// Liczby z AppleScript. Przy locale innym niż amerykańskie (u nas en_PL)
// AppleScript skleja liczby z przecinkiem, np. "214,740997314453".
assertClose(NowPlayingMonitor.parseNumber("214,740997314453"), 214.741, "muzyka: liczba z przecinkiem", tolerance: 0.001)
assertClose(NowPlayingMonitor.parseNumber("17.427000045776"), 17.427, "muzyka: liczba z kropką", tolerance: 0.001)
assertClose(NowPlayingMonitor.parseNumber(" 42 "), 42.0, "muzyka: liczba ze spacjami")
assertClose(NowPlayingMonitor.parseNumber(""), 0.0, "muzyka: pusty tekst")
assertClose(NowPlayingMonitor.parseNumber("brak"), 0.0, "muzyka: tekst bez liczby")

// Sterowanie odtwarzaniem: budowanie komend i mapowanie akcji ze strony.
assertEqual(
    MediaControl.script(action: .next, player: .spotify),
    "tell application \"Spotify\" to next track",
    "sterowanie: następny w Spotify"
)
assertEqual(
    MediaControl.script(action: .previous, player: .music),
    "tell application \"Music\" to previous track",
    "sterowanie: poprzedni w Music"
)
assertEqual(
    MediaControl.script(action: .playPause, player: .music),
    "tell application \"Music\" to playpause",
    "sterowanie: pauza/odtwarzanie w Music"
)
assertEqual(MediaControl.action(from: "next"), MediaAction.next, "sterowanie: akcja next ze strony")
assertEqual(MediaControl.action(from: "playpause"), MediaAction.playPause, "sterowanie: akcja playpause ze strony")
assertEqual(MediaControl.action(from: "previous"), MediaAction.previous, "sterowanie: akcja previous ze strony")
assertEqual(MediaControl.action(from: "rm -rf"), nil, "sterowanie: nieznana akcja jest odrzucana")

// Protokół pomocnika MediaRemote: jedna linia JSON na wiadomość.
func helperLine(_ text: String) -> Data { Data(text.utf8) }

assertEqual(MediaRemoteProtocol.parse(line: helperLine(#"{"type":"hello","version":1}"#)), HelperMessage.hello(version: 1), "protokół: hello")
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"state","players":[{"bundle":"company.thebrowser.dia","name":"Dia","title":"Film","artist":"Kanał","album":"","duration":4083.08,"elapsed":3048,"rate":1,"timestamp":1789553794.5,"artworkId":"7ec2"}]}"#)),
    HelperMessage.state([MRPlayer(bundle: "company.thebrowser.dia", name: "Dia", title: "Film", artist: "Kanał", album: "", duration: 4083.08, elapsed: 3048, rate: 1, timestamp: 1789553794.5, artworkId: "7ec2")]),
    "protokół: state z pełnym odtwarzaczem"
)
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"state","players":[{"bundle":"com.apple.Music","title":"Song"},{"title":"bez bundle"}]}"#)),
    HelperMessage.state([MRPlayer(bundle: "com.apple.Music", name: "", title: "Song", artist: "", album: "", duration: 0, elapsed: 0, rate: 0, timestamp: 0, artworkId: "")]),
    "protokół: braki to zera i puste teksty, odtwarzacz bez bundle pominięty"
)
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"artwork","bundle":"com.apple.Music","artworkId":"a1","mime":"image/png","data":"AQID"}"#)),
    HelperMessage.artwork(MRArtwork(bundle: "com.apple.Music", artworkId: "a1", mime: "image/png", data: Data([1, 2, 3]))),
    "protokół: artwork"
)
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"artwork","bundle":"com.apple.Music","artworkId":"a1","data":"AQID"}"#)),
    HelperMessage.artwork(MRArtwork(bundle: "com.apple.Music", artworkId: "a1", mime: "image/jpeg", data: Data([1, 2, 3]))),
    "protokół: artwork bez mime to image/jpeg"
)
assertEqual(MediaRemoteProtocol.parse(line: helperLine(#"{"type":"artwork","bundle":"x","artworkId":"a1","data":"%%%"}"#)), nil, "protokół: artwork z uszkodzonym base64 pominięty")
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"ack","cmd":"togglePlayPause","bundle":"company.thebrowser.dia","ok":true}"#)),
    HelperMessage.ack(cmd: "togglePlayPause", bundle: "company.thebrowser.dia", ok: true),
    "protokół: ack"
)
assertEqual(
    MediaRemoteProtocol.parse(line: helperLine(#"{"type":"error","reason":"missing-symbol","symbol":"MRMediaRemoteGetNowPlayingClients"}"#)),
    HelperMessage.error(reason: "missing-symbol", symbol: "MRMediaRemoteGetNowPlayingClients"),
    "protokół: error"
)
assertEqual(MediaRemoteProtocol.parse(line: helperLine("{ to nie json")), nil, "protokół: uszkodzona linia")
assertEqual(MediaRemoteProtocol.parse(line: helperLine(#"{"type":"cos-nowego"}"#)), nil, "protokół: nieznany typ")
assertEqual(MediaRemoteProtocol.parse(line: Data(repeating: 0x20, count: MediaRemoteProtocol.maxLineBytes + 1)), nil, "protokół: linia ponad 4 MB")
assertEqual(
    String(decoding: MediaRemoteProtocol.encode(command: .togglePlayPause, bundle: "company.thebrowser.dia"), as: UTF8.self),
    "{\"bundle\":\"company.thebrowser.dia\",\"cmd\":\"togglePlayPause\"}\n",
    "protokół: kodowanie komendy"
)
assertEqual(MediaRemoteProtocol.command(for: .previous), MRCommand.previousTrack, "protokół: poprzedni")
assertEqual(MediaRemoteProtocol.command(for: .playPause), MRCommand.togglePlayPause, "protokół: play/pauza")
assertEqual(MediaRemoteProtocol.command(for: .next), MRCommand.nextTrack, "protokół: następny")

// Wybór odtwarzacza, pozycja i okładka (sekcje 6 i 7 specu).
let diaBundle = "company.thebrowser.dia"
let musicBundle = "com.apple.Music"

func mrPlayer(_ bundle: String, title: String = "Tytuł", rate: Double = 0, timestamp: Double = 100,
              elapsed: Double = 10, duration: Double = 200, artworkId: String = "", name: String = "App") -> MRPlayer {
    MRPlayer(bundle: bundle, name: name, title: title, artist: "Artysta", album: "", duration: duration,
             elapsed: elapsed, rate: rate, timestamp: timestamp, artworkId: artworkId)
}

assertEqual(NowPlayingSelection.choose(players: [mrPlayer(musicBundle, timestamp: 500), mrPlayer(diaBundle, rate: 1, timestamp: 100)], previousBundle: nil)?.bundle, diaBundle, "wybór: grający wygrywa ze świeższą pauzą")
assertEqual(NowPlayingSelection.choose(players: [mrPlayer(musicBundle, rate: 1, timestamp: 100), mrPlayer(diaBundle, rate: 1, timestamp: 200)], previousBundle: musicBundle)?.bundle, diaBundle, "wybór: z dwóch grających świeższy")
assertEqual(NowPlayingSelection.choose(players: [mrPlayer(musicBundle, timestamp: 300), mrPlayer(diaBundle, timestamp: 200)], previousBundle: nil)?.bundle, musicBundle, "wybór: sama pauza, ostatnio aktywny")
assertEqual(NowPlayingSelection.choose(players: [mrPlayer(musicBundle, rate: 1, timestamp: 100), mrPlayer(diaBundle, rate: 1, timestamp: 100)], previousBundle: diaBundle)?.bundle, diaBundle, "wybór: remis zostaje przy poprzednim")
assertEqual(NowPlayingSelection.choose(players: [mrPlayer(musicBundle, rate: 1, timestamp: 100), mrPlayer(diaBundle, rate: 1, timestamp: 100)], previousBundle: nil)?.bundle, musicBundle, "wybór: remis bez poprzedniego bierze pierwszy")
assertEqual(NowPlayingSelection.choose(players: [mrPlayer(diaBundle, title: "   ", rate: 1)], previousBundle: nil), nil, "wybór: odtwarzacz bez tytułu pominięty")
assertEqual(NowPlayingSelection.choose(players: [], previousBundle: nil), nil, "wybór: pusta lista")

assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 1, timestamp: 1000, elapsed: 50), now: 1012), 62, "pozycja: gra i dolicza czas")
assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 0, timestamp: 1000, elapsed: 50), now: 1012), 50, "pozycja: pauza stoi")
assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 2, timestamp: 1000, elapsed: 190, duration: 200), now: 1012), 200, "pozycja: obcięta do długości")
assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 1, timestamp: 1000, elapsed: 50), now: 990), 50, "pozycja: zegar przed timestamp")
assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 1, timestamp: 1000, elapsed: 50, duration: 0), now: 1100), 150, "pozycja: zerowa długość bez obcinania")
assertClose(NowPlayingSelection.position(of: mrPlayer(diaBundle, rate: 1, timestamp: 0, elapsed: 50), now: 1_789_553_794), 50, "pozycja: brak timestamp nie dolicza")

assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer(diaBundle, artworkId: "7ec2"), hasArtwork: true, musicLookup: { "https://itunes" }), "wokyintosh-art://artwork/7ec2", "okładka: z magazynu")
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer(musicBundle, artworkId: "a1"), hasArtwork: false, musicLookup: { "https://itunes" }), "https://itunes", "okładka: Music bez bajtów idzie do iTunes")
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer(diaBundle, artworkId: "7ec2"), hasArtwork: false, musicLookup: { "https://itunes" }), "", "okładka: inne źródło bez bajtów")
assertEqual(ArtworkURL.artworkId(from: URL(string: ArtworkURL.make(artworkId: "a/b c"))!), "a/b c", "okładka: identyfikator ze znakami specjalnymi przechodzi przez adres")
assertEqual(ArtworkURL.artworkId(from: URL(string: "wokyintosh-art://artwork/7ec2014f5eb8fe62")!), "7ec2014f5eb8fe62", "okładka: zwykły identyfikator")
assertEqual(ArtworkURL.artworkId(from: URL(string: "https://example.com/artwork/x")!), nil, "okładka: obcy schemat")

assertEqual(
    NowPlayingSelection.nowPlayingData(for: mrPlayer(diaBundle, title: "Film", rate: 1, timestamp: 1000, elapsed: 50, duration: 4083, name: "Dia"), now: 1010, artworkURL: ""),
    NowPlayingData(playing: true, app: "Dia", track: "Film", artist: "Artysta", duration: 4083, position: 60, state: "playing", artworkURL: ""),
    "mapowanie: grający film z Dii"
)
assertEqual(NowPlayingSelection.nowPlayingData(for: mrPlayer(musicBundle, name: ""), now: 1010, artworkURL: "x").app, musicBundle, "mapowanie: pusta nazwa daje bundle")
assertEqual(NowPlayingSelection.nowPlayingData(for: mrPlayer(musicBundle), now: 1010, artworkURL: "x").state, "paused", "mapowanie: rate 0 to pauza")
assertEqual(NowPlayingSelection.shouldFallBackToAppleScript(bundle: musicBundle), true, "zapas: Music")
assertEqual(NowPlayingSelection.shouldFallBackToAppleScript(bundle: "com.spotify.client"), true, "zapas: Spotify")
assertEqual(NowPlayingSelection.shouldFallBackToAppleScript(bundle: diaBundle), false, "zapas: Dia bez AppleScript")

// Polityka restartów pomocnika (sekcja 9 specu).
var restartPolicy = HelperRestartPolicy()
assertEqual(restartPolicy.record(.exitedAfterState), 1, "restart: pierwsza przerwa 1 s")
assertEqual(restartPolicy.record(.exitedAfterState), 2, "restart: druga przerwa 2 s")
for _ in 0..<4 { _ = restartPolicy.record(.exitedAfterState) }
assertEqual(restartPolicy.record(.exitedAfterState), 60, "restart: przerwa dochodzi do 60 s")
assertEqual(restartPolicy.record(.exitedAfterState), 60, "restart: przerwa zostaje na 60 s")
restartPolicy.recordState()
assertEqual(restartPolicy.record(.startFailure), 1, "restart: state zeruje przerwę")
assertEqual(restartPolicy.record(.startFailure), 2, "restart: druga porażka startu")
assertEqual(restartPolicy.record(.startFailure), nil, "restart: trzecia porażka startu wyłącza")
assertEqual(restartPolicy.permanentlyDisabled, true, "restart: wyłączony na stałe")
assertEqual(restartPolicy.record(.exitedAfterState), nil, "restart: wyłączony nie wraca")

var unsupportedPolicy = HelperRestartPolicy()
assertEqual(unsupportedPolicy.record(.unsupported), nil, "restart: kod 3 wyłącza od razu")
var noPerlPolicy = HelperRestartPolicy()
assertEqual(noPerlPolicy.record(.launchFailed), nil, "restart: brak perla wyłącza od razu")

var resetPolicy = HelperRestartPolicy()
_ = resetPolicy.record(.startFailure)
_ = resetPolicy.record(.startFailure)
resetPolicy.recordState()
assertEqual(resetPolicy.record(.startFailure), 1, "restart: state zeruje licznik porażek")
assertEqual(resetPolicy.consecutiveStartFailures, 1, "restart: licznik porażek liczy od nowa")

assertEqual(HelperRestartPolicy.outcome(exitCode: 3, sawState: true), .unsupported, "restart: kod 3 to brak wsparcia")
assertEqual(HelperRestartPolicy.outcome(exitCode: 2, sawState: false), .startFailure, "restart: kod 2 przed state")
assertEqual(HelperRestartPolicy.outcome(exitCode: -1, sawState: false), .startFailure, "restart: zabity przed state")
assertEqual(HelperRestartPolicy.outcome(exitCode: 0, sawState: true), .exitedAfterState, "restart: wyjście po state")

// Nadzór pomocnika na udawanych procesach zsh (bez MediaRemote).
let helperSandbox = FileManager.default.temporaryDirectory.appendingPathComponent("wokyintosh-helper-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: helperSandbox, withIntermediateDirectories: true)
let fastTiming = MediaRemoteHelper.Timing(helloTimeout: 1, freshness: 1, silenceLimit: 3, killGrace: 0.5, ackTimeout: 0.5)

func fakeHelper(_ name: String, _ script: String, arguments: [String] = []) -> MediaRemoteHelper {
    let url = helperSandbox.appendingPathComponent(name)
    try! script.write(to: url, atomically: true, encoding: .utf8)
    return MediaRemoteHelper(
        launch: .init(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: [url.path] + arguments),
        timing: fastTiming
    )
}

func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

func sendAndWait(_ helper: MediaRemoteHelper, _ command: MRCommand, _ bundle: String) -> Bool? {
    let done = DispatchSemaphore(value: 0)
    var result: Bool?
    helper.send(command, bundle: bundle) { ok in
        result = ok
        done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
    return result
}

func launchCount(_ file: URL) -> Int {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
}

let missingLaunch = MediaRemoteHelper(launch: nil, timing: fastTiming)
missingLaunch.start()
assertEqual(waitUntil(1) { missingLaunch.isPermanentlyDisabled }, true, "nadzór: brak plików pomocnika wyłącza od razu")

let fakeWorkingScript = #"""
zmodload zsh/system
print -r -- '{"type":"hello","version":1}'
print -r -- '{"type":"artwork","bundle":"company.thebrowser.dia","artworkId":"a1","mime":"image/jpeg","data":"AQID"}'
while true; do
  print -r -- '{"type":"state","players":[{"bundle":"company.thebrowser.dia","name":"Dia","title":"Film","rate":1,"timestamp":1000,"artworkId":"a1"}]}'
  sysread -t 0.2 -i 0 chunk
  rc=$?
  (( rc == 5 )) && exit 0
  if (( rc == 0 )) && [[ $chunk == *togglePlayPause* ]]; then
    print -r -- '{"type":"ack","cmd":"togglePlayPause","bundle":"company.thebrowser.dia","ok":true}'
  fi
done
"""#

let workingHelper = fakeHelper("fake-ok.zsh", fakeWorkingScript)
workingHelper.start()
assertEqual(waitUntil(3) { workingHelper.freshPlayers() != nil }, true, "nadzór: świeży stan z procesu")
assertEqual(workingHelper.freshPlayers()?.first?.title, "Film", "nadzór: odtwarzacz ze stanu")
assertEqual(workingHelper.freshPlayers(now: Date().addingTimeInterval(10)), nil, "nadzór: stary stan jest nieświeży")
assertEqual(workingHelper.artwork(id: "a1")?.data, Data([1, 2, 3]), "nadzór: okładka w magazynie")
assertEqual(workingHelper.artwork(id: "inna"), nil, "nadzór: nieznana okładka")
assertEqual(sendAndWait(workingHelper, .togglePlayPause, "company.thebrowser.dia"), true, "nadzór: ack ok z procesu")
assertEqual(sendAndWait(workingHelper, .nextTrack, "company.thebrowser.dia"), false, "nadzór: brak ack w czasie to porażka")
assertEqual(sendAndWait(workingHelper, .togglePlayPause, "nie.ma.takiego"), false, "nadzór: odtwarzacz spoza stanu odrzucony")
workingHelper.stop()
assertEqual(workingHelper.freshPlayers(), nil, "nadzór: po stop brak stanu")

let unsupportedHelper = fakeHelper("fake-exit3.zsh", #"""
print -r -- '{"type":"error","reason":"missing-symbol","symbol":"X"}'
exit 3
"""#)
unsupportedHelper.start()
assertEqual(waitUntil(2) { unsupportedHelper.isPermanentlyDisabled }, true, "nadzór: kod 3 wyłącza")

let crashingHelper = fakeHelper("fake-crash.zsh", "exit 2\n")
crashingHelper.start()
assertEqual(waitUntil(6) { crashingHelper.isPermanentlyDisabled }, true, "nadzór: 3 porażki startu wyłączają")

let restartCounter = helperSandbox.appendingPathComponent("restarts.txt")
let restartingHelper = fakeHelper("fake-restart.zsh", #"""
if [[ -s "$1" ]]; then
  print -r -- start >> "$1"
  print -r -- '{"type":"hello","version":1}'
  exec sleep 30
else
  print -r -- start >> "$1"
  print -r -- '{"type":"hello","version":1}'
  print -r -- '{"type":"artwork","bundle":"company.thebrowser.dia","artworkId":"a1","mime":"image/jpeg","data":"AQID"}'
  print -r -- '{"type":"state","players":[{"bundle":"company.thebrowser.dia","name":"Dia","title":"Film","rate":0,"timestamp":1000,"artworkId":"a1"}]}'
  exit 0
fi
"""#, arguments: [restartCounter.path])
restartingHelper.start()
assertEqual(waitUntil(4) { launchCount(restartCounter) >= 2 }, true, "nadzór: restart po zakończeniu")
assertEqual(waitUntil(2) { restartingHelper.freshPlayers() == nil }, true, "nadzór: po zakończeniu procesu brak stanu")
assertEqual(restartingHelper.artwork(id: "a1"), nil, "nadzór: po zakończeniu procesu brak okładki")
restartingHelper.stop()

let silentCounter = helperSandbox.appendingPathComponent("silent.txt")
let silentHelper = fakeHelper("fake-silent.zsh", #"""
print -r -- start >> "$1"
exec sleep 30
"""#, arguments: [silentCounter.path])
silentHelper.start()
assertEqual(waitUntil(4) { launchCount(silentCounter) >= 2 }, true, "nadzór: brak hello kończy i restartuje proces")
silentHelper.stop()

try? FileManager.default.removeItem(at: helperSandbox)

// Kafelek Now Playing na danych z pomocnika (ścieżka bez AppleScript).
try! FileManager.default.createDirectory(at: helperSandbox, withIntermediateDirectories: true)
let tileHelper = fakeHelper("fake-tile.zsh", fakeWorkingScript)
tileHelper.start()
_ = waitUntil(3) { tileHelper.freshPlayers() != nil }
let tileMonitor = NowPlayingMonitor(helper: tileHelper, clock: { Date(timeIntervalSince1970: 1010) })
assertEqual(
    tileMonitor.snapshot(),
    NowPlayingData(playing: true, app: "Dia", track: "Film", artist: "", duration: 0, position: 10, state: "playing", artworkURL: "wokyintosh-art://artwork/a1"),
    "kafelek: dane z pomocnika i okładka z magazynu"
)
let tileCommandDone = DispatchSemaphore(value: 0)
tileMonitor.perform(.playPause, completionQueue: .global()) { tileCommandDone.signal() }
assertEqual(tileCommandDone.wait(timeout: .now() + 3) == .success, true, "kafelek: komenda przez pomocnika kończy się completion")
tileHelper.stop()
try? FileManager.default.removeItem(at: helperSandbox)

finishTests()
