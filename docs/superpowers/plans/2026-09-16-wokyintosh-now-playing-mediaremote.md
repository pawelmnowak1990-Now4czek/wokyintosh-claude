# Systemowe Now Playing w Wokyintoshu — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kafelek Now Playing pokazuje i steruje tym, co faktycznie gra na Macu (także YouTube w Dii), z danych systemowego MediaRemote, a przy każdej awarii wraca do obecnego AppleScript dla Spotify i Music.

**Architecture:** Biblioteka Objective-C `NowPlayingHelper.dylib` ładowana przez `/usr/bin/perl` (tylko procesy Apple dostają dane MediaRemote) co sekundę wypisuje stan odtwarzaczy jako JSON Lines i przyjmuje komendy na stdin. W aplikacji `MediaRemoteHelper` nadzoruje proces, `MediaRemoteProtocol` parsuje linie, `NowPlayingSelection` wybiera źródło i dolicza pozycję, a `ArtworkSchemeHandler` podaje okładki stronie przez schemat `wokyintosh-art`. Cała logika decyzyjna jest w czystych typach testowanych w `Run Tests.command`.

**Tech Stack:** Swift 5 i clang z Apple Command Line Tools (bez Xcode), AppKit, WebKit, Foundation, prywatny framework MediaRemote (dlopen/dlsym), systemowy perl (DynaLoader), zsh do skryptów testowych.

**Spec:** `docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md`

## Global Constraints

- macOS 13.0+, target `$(uname -m)-apple-macos13.0`, build wyłącznie przez Apple Command Line Tools.
- Zero zależności zewnętrznych i żadnych nowych połączeń sieciowych (wyszukiwanie okładek w iTunes już istnieje).
- Pomocnik uruchamiany wyłącznie jako `/usr/bin/perl <Helper/nowplaying-helper.pl> <Helper/NowPlayingHelper.dylib>`.
- Protokół dokładnie jak w sekcji 5 specu: typy `hello`, `state`, `artwork`, `ack`, `error`; komendy `togglePlayPause`, `nextTrack`, `previousTrack`.
- Progi z sekcji 9 specu: świeży stan < 5 s, `hello` w 5 s, cisza 15 s → SIGTERM, po 2 s SIGKILL, 3 porażki startu z rzędu → trwały zapas, kod 3 → trwały zapas, przerwy 1, 2, 4, 8, 16, 32, 60 s, `ack` w 1 s, okładka ≤ 2 MB, linia ≤ 4 MB.
- Wartości komend MediaRemote: `togglePlayPause` = 2, `nextTrack` = 4, `previousTrack` = 5.
- Teksty w interfejsie po angielsku, komentarze i commity po polsku, commity bez linii `Co-Authored-By`.
- Praca na gałęzi `feature/now-playing-mediaremote`. Bez `git push` bez jawnej zgody Pawła.
- `MediaControl.swift` zostaje czystą ścieżką AppleScript.

**Doprecyzowania względem specu (wpisane do specu przed tym planem):**
- Pomocnik jest w Objective-C (`Helper/NowPlayingHelper.m`), nie w czystym C, żeby JSON w obie strony robił `NSJSONSerialization` zamiast ręcznego parsera. Ładuje się tak samo przez DynaLoader. Foundation może dołożyć 1–2 MB; test wycieku w zadaniu 10 sprawdza próg 15 MB.
- Sygnatury z deasemblacji (sekcja 3 specu): `ForClient(client, origin, Boolean includeArtwork, queue, block(CFDictionaryRef, void *))`, `SendCommandToClient(uint32_t command, CFDictionaryRef options, origin, client, uint32_t appOptions, queue, block(uint32_t error, CFArrayRef statuses)) -> Boolean`.
- Okładka: pomocnik odpytuje co sekundę bez flagi okładki, a z flagą tylko raz, gdy zmieni się `artworkId`; linia `artwork` wychodzi przed linią `state`.
- Po zakończeniu procesu pomocnika aplikacja od razu czyści stan (zamiast czekać 5 s na nieświeżość), więc kafelek przechodzi na AppleScript natychmiast.
- `NativeBridge` zatrzymuje poprzedni bridge przy ponownym `didFinish`, żeby przeładowanie strony nie uruchomiło drugiego pomocnika.
- Aplikacja loguje (NSLog) zmianę wybranego źródła i wynik ładowania okładki ze schematu `wokyintosh-art`, żeby dało się to sprawdzić bez patrzenia na ekran.

---

### Task 1: Spike — komendy i okładka na żywo

Kod tego zadania jest jednorazowy i leży w katalogu tymczasowym, nie w repo. Do repo trafia tylko wynik w sekcji 12 specu.

**Files:**
- Create (tymczasowo): `$TMPDIR/wokyintosh-spike/spike.m`
- Modify: `docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md` (sekcja 12)

**Interfaces:**
- Consumes: sygnatury z sekcji 3 specu.
- Produces: rozstrzygnięcia używane w zadaniu 5: czy `statuses` przy sukcesie zawiera same zera typu `NSNumber` (wtedy zostaje `statusesOK`) oraz czy flaga okładki daje `kMRMediaRemoteNowPlayingInfoArtworkData`.

- [ ] **Step 1: Poproś Pawła o warunki testu**

Napisz do Pawła: „Do spike'a potrzebuję filmu grającego na YouTube w Dii i Music na pauzie. Wyślę dwa razy play/pauza do Dii (film zatrzyma się i ruszy) oraz następny i poprzedni utwór do Music (wróci na ten sam utwór). Mogę?". Czekaj na zgodę. Komendy `nextTrack` do Dii nie wysyłaj bez osobnej zgody, bo może przełączyć film.

- [ ] **Step 2: Zapisz sondę**

```bash
mkdir -p "$TMPDIR/wokyintosh-spike"
cat > "$TMPDIR/wokyintosh-spike/spike.m" <<'OBJC'
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>

typedef void (^ClientsBlock)(CFArrayRef);
typedef void (^InfoBlock)(CFDictionaryRef, void *);
typedef void (^CommandBlock)(uint32_t, CFArrayRef);

__attribute__((constructor)) static void spike(void) {
    @autoreleasepool {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        void (*getClients)(dispatch_queue_t, ClientsBlock) = dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
        CFTypeRef (*origin)(void) = dlsym(mr, "MRMediaRemoteGetLocalOrigin");
        void (*info)(CFTypeRef, CFTypeRef, Boolean, dispatch_queue_t, InfoBlock) = dlsym(mr, "MRMediaRemoteGetNowPlayingInfoForClient");
        CFStringRef (*bundleOf)(CFTypeRef) = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
        Boolean (*send)(uint32_t, CFDictionaryRef, CFTypeRef, CFTypeRef, uint32_t, dispatch_queue_t, CommandBlock) = dlsym(mr, "MRMediaRemoteSendCommandToClient");
        dispatch_queue_t q = dispatch_queue_create("spike", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        NSString *mode = @(getenv("SPIKE") ?: "clients");
        NSString *wanted = @(getenv("BUNDLE") ?: "");
        __block NSArray *clients = @[];
        getClients(q, ^(CFArrayRef list) { clients = [(__bridge NSArray *)list copy] ?: @[]; dispatch_semaphore_signal(s); });
        dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        for (id client in clients) {
            NSString *bundle = (__bridge NSString *)bundleOf((__bridge CFTypeRef)client);
            if (wanted.length && ![bundle isEqualToString:wanted]) continue;
            if ([mode isEqualToString:@"command"]) {
                uint32_t cmd = (uint32_t)atoi(getenv("CMD") ?: "2");
                Boolean accepted = send(cmd, NULL, origin(), (__bridge CFTypeRef)client, 0, q, ^(uint32_t error, CFArrayRef statuses) {
                    NSArray *list = (__bridge NSArray *)statuses;
                    NSMutableArray *kinds = [NSMutableArray array];
                    for (id item in list) [kinds addObject:[NSString stringWithFormat:@"%@=%@", NSStringFromClass([item class]), item]];
                    printf("%s cmd=%u error=%u statuses=[%s]\n", bundle.UTF8String, cmd, error, [[kinds componentsJoinedByString:@", "] UTF8String]);
                    dispatch_semaphore_signal(s);
                });
                printf("%s wywołanie zwróciło %d\n", bundle.UTF8String, accepted);
                if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) printf("%s brak odpowiedzi w 5 s\n", bundle.UTF8String);
                continue;
            }
            BOOL artwork = [mode isEqualToString:@"artwork"];
            info((__bridge CFTypeRef)client, origin(), artwork, q, ^(CFDictionaryRef raw, void *unused) {
                NSDictionary *d = (__bridge NSDictionary *)raw;
                id data = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                printf("%s tytuł=\"%s\" rate=%s artworkId=%s okładka=%lu B mime=%s\n", bundle.UTF8String,
                       [[d[@"kMRMediaRemoteNowPlayingInfoTitle"] description] UTF8String],
                       [[d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] description] UTF8String],
                       [[d[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] description] UTF8String],
                       [data isKindOfClass:[NSData class]] ? (unsigned long)[data length] : 0UL,
                       [[d[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"] description] UTF8String]);
                dispatch_semaphore_signal(s);
            });
            if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC))) printf("%s brak danych w 8 s\n", bundle.UTF8String);
        }
        fflush(stdout);
        exit(0);
    }
}
OBJC
xcrun clang -fobjc-arc -fblocks -dynamiclib -framework Foundation "$TMPDIR/wokyintosh-spike/spike.m" -o "$TMPDIR/wokyintosh-spike/spike.dylib"
cat > "$TMPDIR/wokyintosh-spike/run.sh" <<'SH'
#!/bin/zsh
exec /usr/bin/perl -e 'alarm 30; use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();' "$TMPDIR/wokyintosh-spike/spike.dylib"
SH
chmod +x "$TMPDIR/wokyintosh-spike/run.sh"
```

Każde wywołanie sondy poniżej to `"$TMPDIR/wokyintosh-spike/run.sh"` ze zmiennymi środowiskowymi przed nim (skrócone w krokach jako `SPIKE_RUN`).

Expected: kompilacja bez błędów (ostrzeżenia o `dlsym` bez rzutowania są dopuszczalne).

- [ ] **Step 3: Stan i okładki**

```bash
SPIKE_RUN="$TMPDIR/wokyintosh-spike/run.sh"
SPIKE=clients "$SPIKE_RUN"
SPIKE=artwork BUNDLE=company.thebrowser.dia "$SPIKE_RUN"
SPIKE=artwork BUNDLE=com.apple.Music "$SPIKE_RUN"
```

Expected: linia dla Dii z `rate=1` i tytułem filmu, linia dla Music z `rate=0`. W trybie `artwork` zanotuj `okładka=… B` i `mime=` dla obu.

- [ ] **Step 4: Play/pauza w Dii**

```bash
SPIKE_RUN="$TMPDIR/wokyintosh-spike/run.sh"
SPIKE=command CMD=2 BUNDLE=company.thebrowser.dia "$SPIKE_RUN"
sleep 2; SPIKE=clients BUNDLE=company.thebrowser.dia "$SPIKE_RUN"
SPIKE=command CMD=2 BUNDLE=company.thebrowser.dia "$SPIKE_RUN"
sleep 2; SPIKE=clients BUNDLE=company.thebrowser.dia "$SPIKE_RUN"
```

Expected: po pierwszej komendzie `rate=0`, po drugiej `rate=1`. Zanotuj `error=` i `statuses=[…]` z obu odpowiedzi.

- [ ] **Step 5: Następny i poprzedni w Music**

```bash
SPIKE_RUN="$TMPDIR/wokyintosh-spike/run.sh"
SPIKE=clients BUNDLE=com.apple.Music "$SPIKE_RUN"
SPIKE=command CMD=4 BUNDLE=com.apple.Music "$SPIKE_RUN"
sleep 2; SPIKE=clients BUNDLE=com.apple.Music "$SPIKE_RUN"
SPIKE=command CMD=5 BUNDLE=com.apple.Music "$SPIKE_RUN"
sleep 2; SPIKE=clients BUNDLE=com.apple.Music "$SPIKE_RUN"
```

Expected: tytuł zmienia się po `CMD=4` i wraca do pierwotnego po `CMD=5`. Zanotuj `error=` i `statuses=`.

- [ ] **Step 6: Wpisz wynik do sekcji 12 specu i rozstrzygnij zadanie 5**

Na końcu sekcji 12 specu dopisz blok (wartości z kroków 3–5):

```markdown
**Wynik spike'a (RRRR-MM-DD):**
- Dia: play/pauza działa: tak/nie; `error` = …; `statuses` = ….
- Music: następny/poprzedni działa: tak/nie; `error` = …; `statuses` = ….
- Okładka z flagą: Dia … B (`mime`), Music … B (`mime`).
- Decyzja dla pomocnika: `ok` = `error == 0 && statusesOK(statuses)` albo `ok` = `error == 0` (uzasadnienie).
```

Reguła decyzji: jeśli przy komendach, które zadziałały (zmienił się `rate` albo tytuł), `statuses` było puste albo zawierało wyłącznie `NSNumber=0` (klasa `__NSCFNumber`), zostaje `error == 0 && statusesOK(statuses)`. W każdym innym przypadku zadanie 5 używa wersji `ok = (error == 0)`, pokazanej w kroku 3 zadania 5.

Jeśli play/pauza w Dii nie zadziałała albo okładka ma 0 B, niczego w planie nie zmieniaj: projekt ma na to zapas (sekcje 7 i 8 specu). Tylko zapisz wynik.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md
git commit -m "docs: wynik spike'a komend i okładek MediaRemote"
```

### Task 2: Protokół pomocnika

**Files:**
- Create: `Wokyintosh/MediaRemoteProtocol.swift`
- Modify: `Run Tests.command` (lista plików)
- Test: `Tests/main.swift` (nowy blok przed `finishTests()`)

**Interfaces:**
- Consumes: `MediaAction` z `Wokyintosh/MediaControl.swift` (`.previous`, `.playPause`, `.next`).
- Produces:
  - `struct MRPlayer: Equatable` z polami `bundle, name, title, artist, album: String`, `duration, elapsed, rate, timestamp: Double`, `artworkId: String` (inicjalizator memberwise w tej kolejności),
  - `struct MRArtwork: Equatable { bundle, artworkId, mime: String; data: Data }`,
  - `enum MRCommand: String { togglePlayPause, nextTrack, previousTrack }`,
  - `enum HelperMessage: Equatable { hello(version: Int), state([MRPlayer]), artwork(MRArtwork), ack(cmd: String, bundle: String, ok: Bool), error(reason: String, symbol: String) }`,
  - `MediaRemoteProtocol.maxLineBytes: Int` (4 MB), `MediaRemoteProtocol.parse(line: Data) -> HelperMessage?`, `MediaRemoteProtocol.encode(command: MRCommand, bundle: String) -> Data` (JSON z posortowanymi kluczami + `\n`), `MediaRemoteProtocol.command(for: MediaAction) -> MRCommand`.

- [ ] **Step 1: Dopisz plik do testów**

W `Run Tests.command` dodaj linię po `"Wokyintosh/MediaControl.swift" \`:

```zsh
  "Wokyintosh/MediaRemoteProtocol.swift" \
```

- [ ] **Step 2: Napisz testy**

W `Tests/main.swift` bezpośrednio przed `finishTests()` wstaw:

```swift
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
```

- [ ] **Step 3: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: błąd kompilacji `error opening input file 'Wokyintosh/MediaRemoteProtocol.swift'`.

- [ ] **Step 4: Napisz implementację**

`Wokyintosh/MediaRemoteProtocol.swift`:

```swift
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
```

- [ ] **Step 5: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 46 sprawdzeń` (31 dotychczasowych + 15 nowych).

- [ ] **Step 6: Commit**

```bash
git add Wokyintosh/MediaRemoteProtocol.swift Tests/main.swift "Run Tests.command"
git commit -m "feat: protokół wymiany z pomocnikiem MediaRemote"
```

### Task 3: Wybór odtwarzacza, pozycja i adres okładki

**Files:**
- Create: `Wokyintosh/NowPlayingSelection.swift`
- Modify: `Wokyintosh/NowPlayingMonitor.swift:4` (`NowPlayingData` dostaje `Equatable`)
- Modify: `Run Tests.command`
- Test: `Tests/main.swift`

**Interfaces:**
- Consumes: `MRPlayer` (zadanie 2), `NowPlayingData(playing:app:track:artist:duration:position:state:artworkURL:)` z `NowPlayingMonitor.swift`.
- Produces:
  - `enum ArtworkURL { static let scheme = "wokyintosh-art"; static func make(artworkId: String) -> String; static func artworkId(from: URL) -> String? }`,
  - `NowPlayingSelection.choose(players: [MRPlayer], previousBundle: String?) -> MRPlayer?`,
  - `NowPlayingSelection.position(of: MRPlayer, now: Double) -> Double`,
  - `NowPlayingSelection.artworkURL(for: MRPlayer, hasArtwork: Bool, musicLookup: () -> String) -> String`,
  - `NowPlayingSelection.nowPlayingData(for: MRPlayer, now: Double, artworkURL: String) -> NowPlayingData`,
  - `NowPlayingSelection.shouldFallBackToAppleScript(bundle: String) -> Bool`,
  - `NowPlayingSelection.musicBundle = "com.apple.Music"`.

- [ ] **Step 1: Dopisz plik do testów**

W `Run Tests.command` dodaj po `"Wokyintosh/MediaRemoteProtocol.swift" \`:

```zsh
  "Wokyintosh/NowPlayingSelection.swift" \
```

- [ ] **Step 2: Napisz testy**

W `Tests/main.swift` przed `finishTests()`:

```swift
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
```

- [ ] **Step 3: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: błąd kompilacji `error opening input file 'Wokyintosh/NowPlayingSelection.swift'`.

- [ ] **Step 4: Dodaj `Equatable` do `NowPlayingData`**

W `Wokyintosh/NowPlayingMonitor.swift` zmień linię 4:

```swift
struct NowPlayingData: Codable {
```

na:

```swift
struct NowPlayingData: Codable, Equatable {
```

- [ ] **Step 5: Napisz implementację**

`Wokyintosh/NowPlayingSelection.swift`:

```swift
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
```

- [ ] **Step 6: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 71 sprawdzeń`.

- [ ] **Step 7: Commit**

```bash
git add Wokyintosh/NowPlayingSelection.swift Wokyintosh/NowPlayingMonitor.swift Tests/main.swift "Run Tests.command"
git commit -m "feat: wybór odtwarzacza, doliczanie pozycji i adres okładki"
```

### Task 4: Polityka restartów pomocnika

**Files:**
- Create: `Wokyintosh/MediaRemoteHelper.swift` (na razie tylko `HelperRestartPolicy`; klasę nadzoru dopisuje zadanie 6)
- Modify: `Run Tests.command`
- Test: `Tests/main.swift`

**Interfaces:**
- Consumes: nic.
- Produces: `struct HelperRestartPolicy` z `enum Outcome: Equatable { launchFailed, unsupported, startFailure, exitedAfterState }`, `mutating func record(_: Outcome) -> TimeInterval?` (przerwa przed restartem albo nil = wyłączyć), `mutating func recordState()`, `private(set) var permanentlyDisabled: Bool`, `private(set) var consecutiveStartFailures: Int`, `static func outcome(exitCode: Int32, sawState: Bool) -> Outcome` (kod `-1` oznacza zabicie sygnałem).

- [ ] **Step 1: Dopisz plik do testów**

W `Run Tests.command` dodaj po `"Wokyintosh/NowPlayingSelection.swift" \`:

```zsh
  "Wokyintosh/MediaRemoteHelper.swift" \
```

- [ ] **Step 2: Napisz testy**

W `Tests/main.swift` przed `finishTests()`:

```swift
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
```

- [ ] **Step 3: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: błąd kompilacji `error opening input file 'Wokyintosh/MediaRemoteHelper.swift'`.

- [ ] **Step 4: Napisz implementację**

`Wokyintosh/MediaRemoteHelper.swift`:

```swift
import Foundation

/// Polityka restartów pomocnika MediaRemote z sekcji 9 specu. Czysta logika, bez procesów.
struct HelperRestartPolicy {
    enum Outcome: Equatable {
        /// `/usr/bin/perl` nie istnieje albo proces się nie uruchomił.
        case launchFailed
        /// Kod wyjścia 3: brak symbolu MediaRemote.
        case unsupported
        /// Brak `hello` w 5 s, kod 2 albo koniec przed pierwszym `state`.
        case startFailure
        /// Koniec albo zabicie po co najmniej jednym `state`.
        case exitedAfterState
    }

    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
    static let maxStartFailures = 3

    private(set) var permanentlyDisabled = false
    private(set) var consecutiveStartFailures = 0
    private var delayIndex = 0

    /// Przerwa przed kolejnym startem albo nil, gdy pomocnik zostaje wyłączony do restartu aplikacji.
    mutating func record(_ outcome: Outcome) -> TimeInterval? {
        guard !permanentlyDisabled else { return nil }
        switch outcome {
        case .launchFailed, .unsupported:
            permanentlyDisabled = true
            return nil
        case .startFailure:
            consecutiveStartFailures += 1
            if consecutiveStartFailures >= Self.maxStartFailures {
                permanentlyDisabled = true
                return nil
            }
        case .exitedAfterState:
            break
        }
        let delay = Self.delays[min(delayIndex, Self.delays.count - 1)]
        delayIndex += 1
        return delay
    }

    /// Pierwszy `state` po starcie zeruje licznik porażek i przerwę.
    mutating func recordState() {
        consecutiveStartFailures = 0
        delayIndex = 0
    }

    /// `exitCode` -1 oznacza zakończenie sygnałem.
    static func outcome(exitCode: Int32, sawState: Bool) -> Outcome {
        if exitCode == 3 { return .unsupported }
        return sawState ? .exitedAfterState : .startFailure
    }
}
```

- [ ] **Step 5: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 88 sprawdzeń`.

- [ ] **Step 6: Commit**

```bash
git add Wokyintosh/MediaRemoteHelper.swift Tests/main.swift "Run Tests.command"
git commit -m "feat: polityka restartów pomocnika MediaRemote"
```

### Task 5: Pomocnik MediaRemote i smoke test

**Files:**
- Create: `Helper/NowPlayingHelper.m`
- Create: `Helper/nowplaying-helper.pl`
- Create: `Tests/helper-smoke.command`

**Interfaces:**
- Consumes: protokół z sekcji 5 specu, sygnatury z sekcji 3 specu, decyzja o `ok` z zadania 1.
- Produces: `NowPlayingHelper.dylib` budowany poleceniem `xcrun clang -O2 -fobjc-arc -fblocks -dynamiclib -framework Foundation Helper/NowPlayingHelper.m -o <out>`; uruchamiany jako `/usr/bin/perl Helper/nowplaying-helper.pl <dylib>`; kody wyjścia 0 (zamknięte wejście), 2 (biblioteka się nie załadowała), 3 (brak symbolu).

- [ ] **Step 1: Napisz smoke test**

`Tests/helper-smoke.command`:

```zsh
#!/bin/zsh
# Smoke test pomocnika Now Playing na prawdziwym MediaRemote (sekcja 11.3 specu).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
PID=""
cleanup() {
  exec 3>&- || true
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Kompilacja pomocnika…"
xcrun clang -O2 -fobjc-arc -fblocks -dynamiclib -framework Foundation \
  Helper/NowPlayingHelper.m -o "$WORK/NowPlayingHelper.dylib"

mkfifo "$WORK/in"
/usr/bin/perl Helper/nowplaying-helper.pl "$WORK/NowPlayingHelper.dylib" < "$WORK/in" > "$WORK/out" 2> "$WORK/err" &
PID=$!
exec 3> "$WORK/in"

sleep 5
print -r -- '{"cmd":"togglePlayPause","bundle":"nie.ma.takiego"}' >&3
sleep 1

/usr/bin/python3 - "$WORK/out" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
messages = []
for number, line in enumerate(lines, 1):
    try:
        messages.append(json.loads(line))
    except ValueError:
        sys.exit(f"FAIL: linia {number} to nie JSON: {line[:80]}")
if not messages or messages[0].get("type") != "hello":
    sys.exit("FAIL: pierwsza linia to nie hello")
states = [m for m in messages if m.get("type") == "state"]
if len(states) < 3:
    sys.exit(f"FAIL: tylko {len(states)} linii state w 5 s")
acks = [m for m in messages if m.get("type") == "ack" and m.get("bundle") == "nie.ma.takiego"]
if not acks or acks[0].get("ok") is not False:
    sys.exit("FAIL: brak ack z ok:false dla nieistniejącego odtwarzacza")
players = states[-1].get("players", [])
print(f"OK: hello, {len(states)} x state, ack ok:false; odtwarzacze teraz: {[p.get('bundle') for p in players]}")
PY

exec 3>&-
for i in {1..20}; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: pomocnik nie zakończył się w 2 s po zamknięciu wejścia"
  exit 1
fi
CODE=0
wait "$PID" || CODE=$?
PID=""
if [ "$CODE" != "0" ]; then
  echo "FAIL: kod wyjścia $CODE zamiast 0"
  cat "$WORK/err"
  exit 1
fi
echo "OK: zamknięcie wejścia kończy pomocnika kodem 0"
```

Run: `chmod +x Tests/helper-smoke.command && ./Tests/helper-smoke.command`
Expected: błąd `no such file or directory: Helper/NowPlayingHelper.m`.

- [ ] **Step 2: Napisz starter perl**

`Helper/nowplaying-helper.pl`:

```perl
# Starter pomocnika Now Playing Wokyintosha.
# Systemowy perl jest podpisany przez Apple, więc MediaRemote odpowiada
# bibliotece załadowanej do jego procesu. Pętla pomocnika działa w konstruktorze
# biblioteki i nie wraca; wyjście z tego skryptu oznacza błąd ładowania.
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV;
unless (defined $library) {
    print STDERR "nowplaying-helper: brak ścieżki do biblioteki\n";
    exit 2;
}
DynaLoader::dl_load_file($library, 0) or do {
    print STDERR "nowplaying-helper: ", DynaLoader::dl_error(), "\n";
    exit 2;
};
exit 2;
```

- [ ] **Step 3: Napisz pomocnika**

`Helper/NowPlayingHelper.m`:

```objc
// Pomocnik Now Playing dla Wokyintosha.
// Od macOS 15.4 MediaRemote odpowiada tylko procesom Apple, dlatego ta biblioteka
// jest ładowana do /usr/bin/perl (nowplaying-helper.pl). Protokół: sekcja 5 specu
// docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (^MRClientsBlock)(CFArrayRef clients);
typedef void (^MRInfoBlock)(CFDictionaryRef info, void *unused);
typedef void (^MRCommandBlock)(uint32_t error, CFArrayRef statuses);

static void (*MRGetClients)(dispatch_queue_t, MRClientsBlock);
static CFTypeRef (*MRGetLocalOrigin)(void);
static void (*MRGetInfoForClient)(CFTypeRef client, CFTypeRef origin, Boolean includeArtwork, dispatch_queue_t, MRInfoBlock);
static CFStringRef (*MRClientBundle)(CFTypeRef);
static CFStringRef (*MRClientDisplayName)(CFTypeRef);
static Boolean (*MRSendCommandToClient)(uint32_t command, CFDictionaryRef options, CFTypeRef origin, CFTypeRef client, uint32_t appOptions, dispatch_queue_t, MRCommandBlock);

static const uint32_t kCommandTogglePlayPause = 2;
static const uint32_t kCommandNextTrack = 4;
static const uint32_t kCommandPreviousTrack = 5;
static const NSUInteger kMaxArtworkBytes = 2 * 1024 * 1024;
static const int64_t kCallTimeout = 3 * NSEC_PER_SEC;

static dispatch_queue_t mrQueue;
static NSLock *outputLock;
static NSLock *clientsLock;
static NSDictionary<NSString *, id> *latestClients;
static NSMutableDictionary<NSString *, NSString *> *sentArtworkIds;

static NSString *InfoKey(NSString *name) {
    return [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name];
}

static void WriteLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    [outputLock lock];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    [outputLock unlock];
}

static void *RequireSymbol(void *handle, const char *name) {
    void *symbol = handle ? dlsym(handle, name) : NULL;
    if (!symbol) {
        WriteLine(@{@"type": @"error", @"reason": @"missing-symbol", @"symbol": @(name)});
        _exit(3);
    }
    return symbol;
}

static NSString *StringValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static double NumberValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

static double DateValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSDate class]] ? [value timeIntervalSince1970] : 0;
}

static NSArray *CopyClients(void) {
    __block NSArray *result = @[];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetClients(mrQueue, ^(CFArrayRef clients) {
        if (clients) result = [(__bridge NSArray *)clients copy];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kCallTimeout)) != 0) return @[];
    return result;
}

static NSDictionary *CopyInfo(id client, BOOL includeArtwork) {
    __block NSDictionary *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetInfoForClient((__bridge CFTypeRef)client, MRGetLocalOrigin(), includeArtwork, mrQueue, ^(CFDictionaryRef info, void *unused) {
        if (info) result = [(__bridge NSDictionary *)info copy];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kCallTimeout)) != 0) return nil;
    return result;
}

static void SendArtwork(id client, NSString *bundle, NSString *artworkId) {
    NSDictionary *info = CopyInfo(client, YES);
    id data = info[InfoKey(@"ArtworkData")];
    if (![data isKindOfClass:[NSData class]] || [data length] == 0 || [data length] > kMaxArtworkBytes) return;
    NSString *mime = StringValue(info, @"ArtworkMIMEType");
    WriteLine(@{
        @"type": @"artwork",
        @"bundle": bundle,
        @"artworkId": artworkId,
        @"mime": mime.length > 0 ? mime : @"image/jpeg",
        @"data": [data base64EncodedStringWithOptions:0],
    });
}

static void PollOnce(void) {
    NSMutableArray *players = [NSMutableArray array];
    NSMutableDictionary *clientsByBundle = [NSMutableDictionary dictionary];
    for (id client in CopyClients()) {
        NSString *bundle = (__bridge NSString *)MRClientBundle((__bridge CFTypeRef)client);
        if (bundle.length == 0) continue;
        clientsByBundle[bundle] = client;

        NSDictionary *info = CopyInfo(client, NO);
        NSString *title = StringValue(info, @"Title");
        if ([title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) continue;

        NSString *name = (__bridge NSString *)MRClientDisplayName((__bridge CFTypeRef)client) ?: @"";
        NSString *artworkId = StringValue(info, @"ArtworkIdentifier");
        // Okładka tylko przy nowym identyfikatorze i przed linią state, żeby aplikacja miała bajty,
        // zanim zobaczy identyfikator. Nieudana próba też jest zapamiętana, bez ponawiania co sekundę.
        if (artworkId.length > 0 && ![sentArtworkIds[bundle] isEqualToString:artworkId]) {
            sentArtworkIds[bundle] = artworkId;
            SendArtwork(client, bundle, artworkId);
        }

        [players addObject:@{
            @"bundle": bundle,
            @"name": name,
            @"title": title,
            @"artist": StringValue(info, @"Artist"),
            @"album": StringValue(info, @"Album"),
            @"duration": @(NumberValue(info, @"Duration")),
            @"elapsed": @(NumberValue(info, @"ElapsedTime")),
            @"rate": @(NumberValue(info, @"PlaybackRate")),
            @"timestamp": @(DateValue(info, @"Timestamp")),
            @"artworkId": artworkId,
        }];
    }
    [clientsLock lock];
    latestClients = clientsByBundle;
    [clientsLock unlock];
    WriteLine(@{@"type": @"state", @"players": players});
}

static BOOL StatusesOK(CFArrayRef statuses) {
    for (id status in (__bridge NSArray *)statuses) {
        if ([status isKindOfClass:[NSNumber class]] && [status unsignedIntValue] != 0) return NO;
    }
    return YES;
}

static void WriteAck(NSString *cmd, NSString *bundle, BOOL ok) {
    WriteLine(@{@"type": @"ack", @"cmd": cmd, @"bundle": bundle, @"ok": @(ok)});
}

static void HandleCommand(NSData *line) {
    id json = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = [json[@"cmd"] isKindOfClass:[NSString class]] ? json[@"cmd"] : @"";
    NSString *bundle = [json[@"bundle"] isKindOfClass:[NSString class]] ? json[@"bundle"] : @"";

    uint32_t command;
    if ([cmd isEqualToString:@"togglePlayPause"]) command = kCommandTogglePlayPause;
    else if ([cmd isEqualToString:@"nextTrack"]) command = kCommandNextTrack;
    else if ([cmd isEqualToString:@"previousTrack"]) command = kCommandPreviousTrack;
    else { WriteAck(cmd, bundle, NO); return; }

    [clientsLock lock];
    id client = latestClients[bundle];
    [clientsLock unlock];
    if (!client) { WriteAck(cmd, bundle, NO); return; }

    Boolean accepted = MRSendCommandToClient(command, NULL, MRGetLocalOrigin(), (__bridge CFTypeRef)client, 0, mrQueue, ^(uint32_t error, CFArrayRef statuses) {
        WriteAck(cmd, bundle, error == 0 && StatusesOK(statuses));
    });
    if (!accepted) WriteAck(cmd, bundle, NO);
}

static void *ReadCommands(void *unused) {
    char *buffer = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&buffer, &capacity, stdin)) > 0) {
        @autoreleasepool {
            HandleCommand([NSData dataWithBytes:buffer length:(NSUInteger)length]);
        }
    }
    // Wejście zamknięte: aplikacja skończyła albo padła. _exit omija destruktory perla.
    fflush(stdout);
    _exit(0);
    return NULL;
}

__attribute__((constructor))
static void RunHelper(void) {
    @autoreleasepool {
        outputLock = [NSLock new];
        clientsLock = [NSLock new];
        latestClients = @{};
        sentArtworkIds = [NSMutableDictionary dictionary];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        MRGetClients = RequireSymbol(mr, "MRMediaRemoteGetNowPlayingClients");
        MRGetLocalOrigin = RequireSymbol(mr, "MRMediaRemoteGetLocalOrigin");
        MRGetInfoForClient = RequireSymbol(mr, "MRMediaRemoteGetNowPlayingInfoForClient");
        MRClientBundle = RequireSymbol(mr, "MRNowPlayingClientGetBundleIdentifier");
        MRClientDisplayName = RequireSymbol(mr, "MRNowPlayingClientGetDisplayName");
        MRSendCommandToClient = RequireSymbol(mr, "MRMediaRemoteSendCommandToClient");

        mrQueue = dispatch_queue_create("wokyintosh.nowplaying.mediaremote", DISPATCH_QUEUE_SERIAL);
        WriteLine(@{@"type": @"hello", @"version": @1});

        pthread_t reader;
        pthread_create(&reader, NULL, ReadCommands, NULL);
        pthread_detach(reader);
    }
    for (;;) {
        @autoreleasepool {
            PollOnce();
        }
        sleep(1);
    }
}
```

Jeśli zadanie 1 rozstrzygnęło `ok = (error == 0)`, zamień w `HandleCommand` linię:

```objc
        WriteAck(cmd, bundle, error == 0 && StatusesOK(statuses));
```

na:

```objc
        WriteAck(cmd, bundle, error == 0);
```

i usuń funkcję `StatusesOK`.

- [ ] **Step 4: Uruchom smoke test**

Run: `./Tests/helper-smoke.command`
Expected:
```
OK: hello, 5 x state, ack ok:false; odtwarzacze teraz: [...]
OK: zamknięcie wejścia kończy pomocnika kodem 0
```
(liczba linii `state` 4–6, lista odtwarzaczy zależy od tego, co gra).

- [ ] **Step 5: Sprawdź komendę na żywo**

Tylko gdy Paweł ma film w Dii i zgodził się w zadaniu 1. W jednym poleceniu:

```bash
WORK="$(mktemp -d)"; xcrun clang -O2 -fobjc-arc -fblocks -dynamiclib -framework Foundation Helper/NowPlayingHelper.m -o "$WORK/h.dylib"
( sleep 3; printf '%s\n' '{"cmd":"togglePlayPause","bundle":"company.thebrowser.dia"}'; sleep 3; printf '%s\n' '{"cmd":"togglePlayPause","bundle":"company.thebrowser.dia"}'; sleep 3 ) | /usr/bin/perl Helper/nowplaying-helper.pl "$WORK/h.dylib" | grep -E '"ack"|company.thebrowser.dia' | cut -c1-160
rm -rf "$WORK"
```

Expected: dwie linie `ack` z `"ok":true`, a w liniach `state` dla Dii `"rate":0` między komendami i `"rate":1` po drugiej.

- [ ] **Step 6: Commit**

```bash
git add Helper/NowPlayingHelper.m Helper/nowplaying-helper.pl Tests/helper-smoke.command
git commit -m "feat: pomocnik MediaRemote ładowany przez systemowy perl"
```

### Task 6: Nadzór nad procesem pomocnika

**Files:**
- Modify: `Wokyintosh/MediaRemoteHelper.swift` (dopisanie klasy pod `HelperRestartPolicy`)
- Test: `Tests/main.swift`

**Interfaces:**
- Consumes: `HelperRestartPolicy` (zadanie 4), `MediaRemoteProtocol`, `MRPlayer`, `MRArtwork`, `MRCommand` (zadanie 2).
- Produces:
  - `final class MediaRemoteHelper` z `init(launch: Launch?, timing: Timing = Timing())`,
  - `struct MediaRemoteHelper.Launch { executable: URL; arguments: [String]; static func bundled(in: Bundle = .main) -> Launch? }` (szuka `Contents/Resources/Helper/nowplaying-helper.pl` i `NowPlayingHelper.dylib`),
  - `struct MediaRemoteHelper.Timing { helloTimeout = 5, freshness = 5, silenceLimit = 15, killGrace = 2, ackTimeout = 1 }`,
  - `func start()`, `func stop()` (blokuje do 1 s),
  - `func freshPlayers(now: Date = Date()) -> [MRPlayer]?`,
  - `func artwork(id: String) -> MRArtwork?`,
  - `func send(_: MRCommand, bundle: String, completion: @escaping (Bool) -> Void)` (completion na kolejce globalnej),
  - `var isPermanentlyDisabled: Bool`,
  - w `Tests/main.swift` (dla zadania 7): `helperSandbox: URL`, `fakeHelper(_:_:arguments:) -> MediaRemoteHelper`, `waitUntil(_:_:) -> Bool`, `fakeWorkingScript: String`.

Po przeglądzie (runda poprawek 1): zakończenie procesu jest obsługiwane dopiero po końcu jego wyjścia (albo po 1 s), a test restartu sprawdza brak stanu i okładki po wyjściu — kod w repo jest źródłem prawdy dla tych fragmentów. Testy tego zadania uruchamiają krótkie skrypty zsh udające pomocnika i wydłużają `Run Tests.command` o około 12 s.

- [ ] **Step 1: Napisz testy**

W `Tests/main.swift` przed `finishTests()`:

```swift
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
print -r -- start >> "$1"
print -r -- '{"type":"hello","version":1}'
print -r -- '{"type":"state","players":[]}'
sleep 0.3
exit 0
"""#, arguments: [restartCounter.path])
restartingHelper.start()
assertEqual(waitUntil(4) { launchCount(restartCounter) >= 2 }, true, "nadzór: restart po zakończeniu")
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
```

- [ ] **Step 2: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: błąd kompilacji `cannot find 'MediaRemoteHelper' in scope`.

- [ ] **Step 3: Napisz implementację**

Na końcu `Wokyintosh/MediaRemoteHelper.swift` (pod `HelperRestartPolicy`) dopisz:

```swift
/// Nadzór nad pomocnikiem MediaRemote: proces, ostatni stan, okładki, komendy i restarty.
/// Cały stan żyje na prywatnej kolejce; publiczne metody są bezpieczne z każdego wątku.
final class MediaRemoteHelper {
    struct Launch {
        let executable: URL
        let arguments: [String]

        /// Pomocnik z paczki aplikacji uruchamiany przez systemowego perla.
        static func bundled(in bundle: Bundle = .main) -> Launch? {
            guard let resources = bundle.resourceURL else { return nil }
            let script = resources.appendingPathComponent("Helper/nowplaying-helper.pl")
            let library = resources.appendingPathComponent("Helper/NowPlayingHelper.dylib")
            let files = FileManager.default
            guard files.fileExists(atPath: script.path), files.fileExists(atPath: library.path) else { return nil }
            return Launch(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: [script.path, library.path])
        }
    }

    struct Timing {
        var helloTimeout: TimeInterval = 5
        var freshness: TimeInterval = 5
        var silenceLimit: TimeInterval = 15
        var killGrace: TimeInterval = 2
        var ackTimeout: TimeInterval = 1
    }

    private struct PendingAck {
        let id: UUID
        let cmd: String
        let bundle: String
        let completion: (Bool) -> Void
    }

    private let launch: Launch?
    private let timing: Timing
    private let queue = DispatchQueue(label: "wokyintosh.mediaremote-helper")

    private var policy = HelperRestartPolicy()
    private var running = false
    private var generation = 0
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var startedAt = Date.distantPast
    private var lastLineAt = Date.distantPast
    private var sawHello = false
    private var sawState = false
    private var players: [MRPlayer] = []
    private var lastStateAt: Date?
    private var artworks: [String: MRArtwork] = [:]
    private var pendingAcks: [PendingAck] = []
    private var watchdog: DispatchSourceTimer?

    init(launch: Launch?, timing: Timing = Timing()) {
        self.launch = launch
        self.timing = timing
    }

    var isPermanentlyDisabled: Bool {
        queue.sync { policy.permanentlyDisabled }
    }

    func start() {
        // Zapis do potoku martwego pomocnika nie może zabić aplikacji sygnałem.
        signal(SIGPIPE, SIG_IGN)
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.launchProcess()
        }
    }

    /// Zamyka wejście pomocnika (sam wtedy wychodzi), czeka do 1 s, potem SIGTERM.
    func stop() {
        let finished: Process? = queue.sync {
            running = false
            generation += 1
            watchdog?.cancel()
            watchdog = nil
            failPendingAcks()
            clearState()
            try? input?.close()
            input = nil
            let current = process
            process = nil
            return current
        }
        guard let finished else { return }
        let deadline = Date().addingTimeInterval(1)
        while finished.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if finished.isRunning {
            finished.terminate()
        }
    }

    /// Odtwarzacze z ostatniego `state`, jeśli przyszedł mniej niż `freshness` sekund temu.
    func freshPlayers(now: Date = Date()) -> [MRPlayer]? {
        queue.sync {
            guard let lastStateAt, now.timeIntervalSince(lastStateAt) < timing.freshness else { return nil }
            return players
        }
    }

    func artwork(id: String) -> MRArtwork? {
        guard !id.isEmpty else { return nil }
        return queue.sync { artworks.values.first { $0.artworkId == id } }
    }

    /// Komenda tylko do odtwarzacza z ostatniego stanu. `completion(true)` wyłącznie po `ack`
    /// z `ok:true` w czasie `ackTimeout`; wołane na kolejce globalnej.
    func send(_ command: MRCommand, bundle: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let input = self.input, self.players.contains(where: { $0.bundle == bundle }) else {
                DispatchQueue.global(qos: .userInitiated).async { completion(false) }
                return
            }
            let pending = PendingAck(id: UUID(), cmd: command.rawValue, bundle: bundle, completion: completion)
            self.pendingAcks.append(pending)
            do {
                try input.write(contentsOf: MediaRemoteProtocol.encode(command: command, bundle: bundle))
            } catch {
                self.resolveAck(id: pending.id, ok: false)
                return
            }
            self.queue.asyncAfter(deadline: .now() + self.timing.ackTimeout) {
                self.resolveAck(id: pending.id, ok: false)
            }
        }
    }

    private func launchProcess() {
        guard running, process == nil, !policy.permanentlyDisabled else { return }
        guard let launch else {
            _ = policy.record(.launchFailed)
            NSLog("Wokyintosh: brak plików pomocnika Now Playing, zostaje AppleScript")
            return
        }

        generation += 1
        let current = generation
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.receive(chunk, generation: current) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationReason == .exit ? finished.terminationStatus : -1
            self?.queue.async { self?.handleExit(code: code, generation: current) }
        }

        buffer = Data()
        sawHello = false
        sawState = false
        startedAt = Date()
        lastLineAt = startedAt

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            _ = policy.record(.launchFailed)
            NSLog("Wokyintosh: pomocnik Now Playing nie wystartował (\(error)), zostaje AppleScript")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        startWatchdog(generation: current)
    }

    private func receive(_ chunk: Data, generation current: Int) {
        guard current == generation, !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
        // Linia ponad limit i tak nie przejdzie parsowania; nie trzymamy jej w pamięci.
        if buffer.count > MediaRemoteProtocol.maxLineBytes {
            buffer.removeAll()
        }
    }

    private func handle(line: Data) {
        lastLineAt = Date()
        guard let message = MediaRemoteProtocol.parse(line: line) else { return }
        switch message {
        case .hello:
            sawHello = true
        case .state(let current):
            players = current
            lastStateAt = Date()
            if !sawState {
                sawState = true
                policy.recordState()
            }
            let present = Set(current.map(\.bundle))
            artworks = artworks.filter { present.contains($0.key) }
        case .artwork(let artwork):
            artworks[artwork.bundle] = artwork
        case .ack(let cmd, let bundle, let ok):
            if let pending = pendingAcks.first(where: { $0.cmd == cmd && $0.bundle == bundle }) {
                resolveAck(id: pending.id, ok: ok)
            }
        case .error(let reason, let symbol):
            NSLog("Wokyintosh: pomocnik Now Playing zgłosił \(reason) \(symbol)")
        }
    }

    private func startWatchdog(generation current: Int) {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.checkHealth(generation: current)
        }
        watchdog = timer
        timer.resume()
    }

    private func checkHealth(generation current: Int) {
        guard current == generation, let process else { return }
        let now = Date()
        let helloMissing = !sawHello && now.timeIntervalSince(startedAt) >= timing.helloTimeout
        let silent = now.timeIntervalSince(lastLineAt) >= timing.silenceLimit
        guard helloMissing || silent else { return }

        watchdog?.cancel()
        watchdog = nil
        NSLog("Wokyintosh: pomocnik Now Playing \(helloMissing ? "nie przysłał hello" : "milczy"), zatrzymuję")
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + timing.killGrace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func handleExit(code: Int32, generation current: Int) {
        guard current == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        process = nil
        try? input?.close()
        input = nil
        failPendingAcks()
        clearState()
        let delay = policy.record(HelperRestartPolicy.outcome(exitCode: code, sawState: sawState))
        if let delay {
            NSLog("Wokyintosh: pomocnik Now Playing zakończył się (kod \(code)), restart za \(Int(delay)) s")
        } else {
            NSLog("Wokyintosh: pomocnik Now Playing zakończył się (kod \(code)), zostaje AppleScript")
        }
        guard running, let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchProcess()
        }
    }

    private func clearState() {
        players = []
        lastStateAt = nil
        artworks = [:]
        buffer = Data()
    }

    private func resolveAck(id: UUID, ok: Bool) {
        guard let index = pendingAcks.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAcks.remove(at: index)
        DispatchQueue.global(qos: .userInitiated).async { pending.completion(ok) }
    }

    private func failPendingAcks() {
        for pending in pendingAcks {
            resolveAck(id: pending.id, ok: false)
        }
    }
}
```

- [ ] **Step 4: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 104 sprawdzeń`. Po zakończeniu `pgrep -f fake-` nie zwraca żadnego procesu.

- [ ] **Step 5: Commit**

```bash
git add Wokyintosh/MediaRemoteHelper.swift Tests/main.swift
git commit -m "feat: nadzór nad procesem pomocnika MediaRemote"
```

### Task 7: Spięcie z kafelkiem, przyciskami i budowaniem

**Files:**
- Modify: `Wokyintosh/NowPlayingMonitor.swift` (klasa `NowPlayingMonitor`: pola, `init`, `snapshot()`, nowe `perform`, dawne ciało `snapshot()` jako `appleScriptSnapshot()`)
- Modify: `Wokyintosh/NativeBridge.swift`
- Modify: `Wokyintosh/AppDelegate.swift` (`webView(_:didFinish:)`, `userContentController(_:didReceive:)`)
- Modify: `Build Wokyintosh.command`
- Modify: `README.md`
- Test: `Tests/main.swift`

**Interfaces:**
- Consumes: `MediaRemoteHelper` (zadanie 6), `NowPlayingSelection`, `ArtworkURL` (zadanie 3), `MediaRemoteProtocol.command(for:)` (zadanie 2), `MediaControl.perform(_:)`, z testów zadania 6: `helperSandbox`, `fakeHelper(_:_:arguments:)`, `waitUntil(_:_:)`, `fakeWorkingScript`.
- Produces:
  - `NowPlayingMonitor.init(helper: MediaRemoteHelper? = nil, clock: @escaping () -> Date = Date.init)`,
  - `NowPlayingMonitor.perform(_ action: MediaAction, completionQueue: DispatchQueue = .main, completion: @escaping () -> Void)`,
  - `NativeBridge.performMedia(_ action: MediaAction)`, `NativeBridge.artwork(id: String) -> MRArtwork?`,
  - w paczce aplikacji `Contents/Resources/Helper/NowPlayingHelper.dylib` i `Contents/Resources/Helper/nowplaying-helper.pl`.

- [ ] **Step 1: Napisz testy**

W `Tests/main.swift` przed `finishTests()`:

```swift
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
```

- [ ] **Step 2: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: błąd kompilacji `extra arguments at positions #1, #2 in call` przy `NowPlayingMonitor(helper:clock:)`.

- [ ] **Step 3: Zmień `NowPlayingMonitor`**

W `Wokyintosh/NowPlayingMonitor.swift` zamień:

```swift
final class NowPlayingMonitor {
    private var artworkCache: [String: String] = [:]
```

na:

```swift
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
```

Następnie zamień początek dawnej metody:

```swift
    func snapshot() -> NowPlayingData {
        if isRunning(bundleID: "com.spotify.client"),
```

na:

```swift
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
```

Reszta dawnego ciała (`let spotify = spotifySnapshot()` … `return .empty`) zostaje bez zmian i teraz należy do `appleScriptSnapshot()`.

- [ ] **Step 4: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 106 sprawdzeń`.

- [ ] **Step 5: Zmień `NativeBridge`**

W `Wokyintosh/NativeBridge.swift` zamień:

```swift
    private let nowPlaying = NowPlayingMonitor()
```

na:

```swift
    private let helper: MediaRemoteHelper
    private let nowPlaying: NowPlayingMonitor
```

zamień:

```swift
    init(webView: WKWebView) {
        self.webView = webView
    }

    func start() {
        pushSystem()
```

na:

```swift
    init(webView: WKWebView) {
        self.webView = webView
        helper = MediaRemoteHelper(launch: MediaRemoteHelper.Launch.bundled())
        nowPlaying = NowPlayingMonitor(helper: helper)
    }

    func start() {
        helper.start()
        pushSystem()
```

zamień:

```swift
        claudeTimer?.invalidate()
    }
```

na:

```swift
        claudeTimer?.invalidate()
        helper.stop()
    }
```

i zamień:

```swift
    func refreshNowPlaying() {
        pushNowPlaying()
    }
```

na:

```swift
    func refreshNowPlaying() {
        pushNowPlaying()
    }

    /// Przycisk odtwarzania ze strony; kafelek odświeża się 0,3 s po wykonaniu komendy.
    func performMedia(_ action: MediaAction) {
        nowPlaying.perform(action) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.refreshNowPlaying()
            }
        }
    }

    /// Bajty okładki dla schematu `wokyintosh-art`.
    func artwork(id: String) -> MRArtwork? {
        helper.artwork(id: id)
    }
```

- [ ] **Step 6: Zmień `AppDelegate`**

W `Wokyintosh/AppDelegate.swift` zamień:

```swift
        bridge = NativeBridge(webView: webView)
        bridge.start()
```

na:

```swift
        // Przeładowanie strony nie może zostawić starego bridge'a z drugim pomocnikiem.
        bridge?.stop()
        bridge = NativeBridge(webView: webView)
        bridge.start()
```

i zamień:

```swift
        MediaControl.perform(action)

        // Krótka zwłoka, bo odtwarzacz potrzebuje chwili na zmianę stanu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.bridge?.refreshNowPlaying()
        }
```

na:

```swift
        bridge?.performMedia(action)
```

- [ ] **Step 7: Zmień skrypt budowania**

W `Build Wokyintosh.command` zamień:

```zsh
  "$SRC/NowPlayingMonitor.swift" \
```

na:

```zsh
  "$SRC/NowPlayingMonitor.swift" \
  "$SRC/MediaRemoteProtocol.swift" \
  "$SRC/NowPlayingSelection.swift" \
  "$SRC/MediaRemoteHelper.swift" \
```

i zamień:

```zsh
cp "$SRC/Resources/app.js" "$RESOURCES/Resources/app.js"
```

na:

```zsh
cp "$SRC/Resources/app.js" "$RESOURCES/Resources/app.js"

# Pomocnik Now Playing: biblioteka ładowana przez systemowego perla, bo MediaRemote
# od macOS 15.4 odpowiada tylko procesom Apple.
echo "Compiling Now Playing helper…"
mkdir -p "$RESOURCES/Helper"
xcrun clang -O2 -fobjc-arc -fblocks -dynamiclib \
  -target "$TARGET" -isysroot "$SDK" \
  -framework Foundation \
  "$ROOT/Helper/NowPlayingHelper.m" \
  -o "$RESOURCES/Helper/NowPlayingHelper.dylib"
cp "$ROOT/Helper/nowplaying-helper.pl" "$RESOURCES/Helper/nowplaying-helper.pl"
codesign --force --sign - "$RESOURCES/Helper/NowPlayingHelper.dylib"
```

- [ ] **Step 8: Dopisz punkt do README**

W `README.md` zamień:

```markdown
> - autostart po zalogowaniu (`SMAppService`, działa też przy podpisie ad-hoc),
```

na:

```markdown
> - autostart po zalogowaniu (`SMAppService`, działa też przy podpisie ad-hoc),
> - Now Playing z systemowego MediaRemote, więc kafelek pokazuje i steruje też np. YouTube w przeglądarce; przy awarii wraca do AppleScript dla Spotify i Music,
```

- [ ] **Step 9: Zbuduj, zainstaluj i sprawdź podpis**

Run: `./"Build Wokyintosh.command" 2>&1 | tail -6 && codesign --verify --deep --strict /Applications/Wokyintosh.app && echo PODPIS_OK && ls /Applications/Wokyintosh.app/Contents/Resources/Helper`
Expected: `Wokyintosh launched.`, `PODPIS_OK`, pliki `NowPlayingHelper.dylib` i `nowplaying-helper.pl`.

Jeśli `codesign --verify` zgłosi zagnieżdżony kod w `Resources`: w skrypcie budowania zmień katalog dyliba na `"$CONTENTS/Frameworks"` (`mkdir -p "$CONTENTS/Frameworks"`, `-o "$CONTENTS/Frameworks/NowPlayingHelper.dylib"`, ta sama ścieżka w `codesign`), a w `MediaRemoteHelper.Launch.bundled` zamień linię z `library` na:

```swift
            guard let library = bundle.privateFrameworksURL?.appendingPathComponent("NowPlayingHelper.dylib") else { return nil }
```

Potem powtórz ten krok.

- [ ] **Step 10: Sprawdź działanie bez patrzenia na ekran**

Poproś Pawła o puszczenie filmu na YouTube w Dii, potem:

Run: `pgrep -fl 'Helper/nowplaying-helper.pl'; /usr/bin/log show --last 2m --style compact --predicate 'process == "Wokyintosh" AND eventMessage CONTAINS "Now Playing"' | tail -5`
Expected: jeden proces perl ze ścieżką `/Applications/Wokyintosh.app/Contents/Resources/Helper/…` i wpis `Now Playing źródło Dia (company.thebrowser.dia)`.

Run: `pkill -f 'Helper/nowplaying-helper.pl'; sleep 4; pgrep -fl 'Helper/nowplaying-helper.pl'; /usr/bin/log show --last 1m --style compact --predicate 'process == "Wokyintosh" AND eventMessage CONTAINS "pomocnik"' | tail -3`
Expected: nowy PID pomocnika i wpis `zakończył się (kod -1), restart za 1 s`.

Poproś Pawła o kliknięcie play/pauza na ekranie doku przy filmie z YouTube i o potwierdzenie, że film się zatrzymał i ruszył.

- [ ] **Step 11: Commit**

```bash
git add Wokyintosh/NowPlayingMonitor.swift Wokyintosh/NativeBridge.swift Wokyintosh/AppDelegate.swift "Build Wokyintosh.command" README.md Tests/main.swift
git commit -m "feat: kafelek Now Playing i przyciski na danych z MediaRemote"
```

### Task 8: Okładki ze schematu `wokyintosh-art`

**Files:**
- Create: `Wokyintosh/ArtworkSchemeHandler.swift`
- Modify: `Wokyintosh/AppDelegate.swift` (rejestracja schematu, log zdarzeń okładki)
- Modify: `Wokyintosh/Resources/app.js` (`setArtwork`)
- Modify: `Build Wokyintosh.command`

**Interfaces:**
- Consumes: `ArtworkURL.scheme`, `ArtworkURL.artworkId(from:)` (zadanie 3), `MRArtwork` (zadanie 2), `NativeBridge.artwork(id:)` (zadanie 7).
- Produces: `final class ArtworkSchemeHandler: NSObject, WKURLSchemeHandler` z `init(lookup: @escaping (String) -> MRArtwork?)`; wiadomość strony `{artworkEvent: "loaded" | "failed"}`.

Tego zadania nie da się sprawdzić testem jednostkowym (WebKit); weryfikacją jest log aplikacji w kroku 5.

- [ ] **Step 1: Napisz handler**

`Wokyintosh/ArtworkSchemeHandler.swift`:

```swift
import Foundation
import WebKit

/// Podaje stronie okładki z pomocnika MediaRemote pod adresem `wokyintosh-art://artwork/<id>`.
/// Dzięki temu co 1,8 s do strony idzie krótki adres zamiast bajtów obrazka.
final class ArtworkSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lookup: (String) -> MRArtwork?

    init(lookup: @escaping (String) -> MRArtwork?) {
        self.lookup = lookup
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let id = ArtworkURL.artworkId(from: url),
            let artwork = lookup(id)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: artwork.mime,
            expectedContentLength: artwork.data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(artwork.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
```

- [ ] **Step 2: Zarejestruj schemat i log w `AppDelegate`**

W `Wokyintosh/AppDelegate.swift` zamień:

```swift
        configuration.userContentController.add(self, name: "wokyintosh")
```

na:

```swift
        configuration.userContentController.add(self, name: "wokyintosh")
        // Okładki z MediaRemote; bridge powstaje dopiero po załadowaniu strony, stąd słabe self.
        configuration.setURLSchemeHandler(
            ArtworkSchemeHandler { [weak self] id in self?.bridge?.artwork(id: id) },
            forURLScheme: ArtworkURL.scheme
        )
```

oraz zamień:

```swift
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
```

na:

```swift
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "wokyintosh",
           let body = message.body as? [String: Any],
           let event = body["artworkEvent"] as? String {
            NSLog("Wokyintosh: okładka z MediaRemote \(event == "loaded" ? "załadowana" : "nie załadowała się")")
            return
        }

        guard
```

- [ ] **Step 3: Zgłaszaj wynik ładowania okładki ze strony**

W `Wokyintosh/Resources/app.js` zamień:

```js
  img.onload=()=>{img.classList.remove('hidden');fallback.style.display='block'};
  img.onerror=()=>{img.classList.add('hidden');fallback.style.display='block';lastArtwork=''};
```

na:

```js
  img.onload=()=>{img.classList.remove('hidden');fallback.style.display='block';reportArtwork(url,true)};
  img.onerror=()=>{img.classList.add('hidden');fallback.style.display='block';lastArtwork='';reportArtwork(url,false)};
```

i bezpośrednio nad `function setArtwork(url){` dopisz:

```js
/* Wynik ładowania okładki z MediaRemote trafia do logu aplikacji (sprawdzenie bez ekranu). */
function reportArtwork(url,ok){
  if(!String(url).startsWith('wokyintosh-art:'))return;
  try{window.webkit.messageHandlers.wokyintosh.postMessage({artworkEvent:ok?'loaded':'failed'})}catch(e){}
}
```

- [ ] **Step 4: Dodaj plik do budowania**

W `Build Wokyintosh.command` zamień:

```zsh
  "$SRC/MediaRemoteHelper.swift" \
```

na:

```zsh
  "$SRC/MediaRemoteHelper.swift" \
  "$SRC/ArtworkSchemeHandler.swift" \
```

- [ ] **Step 5: Zbuduj i sprawdź okładkę**

Run: `./"Run Tests.command" | tail -1 && ./"Build Wokyintosh.command" 2>&1 | tail -3`
Expected: `OK: 106 sprawdzeń`, `Wokyintosh launched.`

Jeśli zadanie 1 pokazało bajty okładki dla Dii, poproś Pawła o przełączenie na inny film na YouTube, potem:

Run: `/usr/bin/log show --last 2m --style compact --predicate 'process == "Wokyintosh" AND eventMessage CONTAINS "okładka"' | tail -3`
Expected: `okładka z MediaRemote załadowana`.

Jeśli zadanie 1 pokazało 0 B dla Dii, a bajty dla Music: poproś o włączenie utworu w Music i sprawdź to samo. Jeśli żadne źródło nie dało bajtów, zapisz to w raporcie końcowym; strona pokazuje grafikę zastępczą albo okładkę z iTunes dla Music.

- [ ] **Step 6: Commit**

```bash
git add Wokyintosh/ArtworkSchemeHandler.swift Wokyintosh/AppDelegate.swift Wokyintosh/Resources/app.js "Build Wokyintosh.command"
git commit -m "feat: okładki z MediaRemote podawane stronie przez schemat wokyintosh-art"
```

### Task 9: Przycisk play dla przeglądarek bez okładki

Dodane po spike'u (zadanie 1): MediaRemote nie podaje bajtów okładek z Dii ani Music, więc dla przeglądarek kafelek pokazuje 1-bitowy przycisk play zamiast nocnego miasta. Decyzja Pawła: przycisk play (bez logo YouTube), przeglądarki Dia, Arc, Chrome, Safari.

**Files:**
- Create: `Wokyintosh/Resources/video-art.svg`
- Modify: `Wokyintosh/NowPlayingSelection.swift` (stałe i `artworkURL`)
- Modify: `Build Wokyintosh.command` (kopiowanie grafiki)
- Test: `Tests/main.swift` (jedna asercja z zadania 3 zmieniona, dwie nowe)

**Interfaces:**
- Consumes: `NowPlayingSelection.artworkURL(for:hasArtwork:musicLookup:)` i `musicBundle` (zadanie 3), `mrPlayer(...)`, `diaBundle` w `Tests/main.swift` (zadanie 3).
- Produces: `NowPlayingSelection.browserBundles: Set<String>`, `NowPlayingSelection.videoArtURL = "video-art.svg"`; strona dostaje `artwork_url: "video-art.svg"`, który `setArtwork` w `app.js` ładuje względem `index.html`.

- [ ] **Step 1: Zmień testy**

W `Tests/main.swift` zamień linię:

```swift
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer(diaBundle, artworkId: "7ec2"), hasArtwork: false, musicLookup: { "https://itunes" }), "", "okładka: inne źródło bez bajtów")
```

na:

```swift
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer("com.example.player", artworkId: "7ec2"), hasArtwork: false, musicLookup: { "https://itunes" }), "", "okładka: inne źródło bez bajtów")
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer(diaBundle, artworkId: "7ec2"), hasArtwork: false, musicLookup: { "https://itunes" }), "video-art.svg", "okładka: Dia bez bajtów pokazuje przycisk play")
assertEqual(NowPlayingSelection.artworkURL(for: mrPlayer("com.apple.Safari"), hasArtwork: false, musicLookup: { "https://itunes" }), "video-art.svg", "okładka: Safari bez bajtów pokazuje przycisk play")
```

Asercja „okładka: z magazynu" (Dia z bajtami → `wokyintosh-art://…`) zostaje bez zmian i pilnuje, że bajty wygrywają także dla przeglądarek.

- [ ] **Step 2: Uruchom testy i sprawdź, że nie przechodzą**

Run: `./"Run Tests.command"`
Expected: linie `FAIL okładka: Dia bez bajtów pokazuje przycisk play` i `FAIL okładka: Safari bez bajtów pokazuje przycisk play` (otrzymano pusty tekst, oczekiwano `video-art.svg`), na końcu `2 z 108 sprawdzeń nie przeszło`.

- [ ] **Step 3: Napisz implementację**

W `Wokyintosh/NowPlayingSelection.swift` zamień:

```swift
    static let musicBundle = "com.apple.Music"
    private static let appleScriptBundles: Set<String> = ["com.spotify.client", musicBundle]
```

na:

```swift
    static let musicBundle = "com.apple.Music"
    private static let appleScriptBundles: Set<String> = ["com.spotify.client", musicBundle]
    /// Przeglądarki: MediaRemote nie podaje z nich okładek (spike, sekcja 12 specu), a kafelek
    /// nie wie, czy gra YouTube, więc pokazuje ogólny przycisk play zamiast logo.
    static let browserBundles: Set<String> = [
        "company.thebrowser.dia",
        "company.thebrowser.Browser",
        "com.google.Chrome",
        "com.apple.Safari",
    ]
    static let videoArtURL = "video-art.svg"
```

oraz zamień:

```swift
        if player.bundle == musicBundle {
            return musicLookup()
        }
        return ""
```

na:

```swift
        if player.bundle == musicBundle {
            return musicLookup()
        }
        if browserBundles.contains(player.bundle) {
            return videoArtURL
        }
        return ""
```

- [ ] **Step 4: Uruchom testy**

Run: `./"Run Tests.command"`
Expected: `OK: 108 sprawdzeń`.

- [ ] **Step 5: Dodaj grafikę**

Utwórz `Wokyintosh/Resources/video-art.svg` z dokładnie tą treścią (jedna linia):

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" shape-rendering="crispEdges"><rect width="32" height="32" fill="#f1ecd8"/><g fill="#0c0c0c"><rect x="13" y="5" width="6" height="1"/><rect x="10" y="6" width="12" height="1"/><rect x="9" y="7" width="14" height="1"/><rect x="8" y="8" width="16" height="1"/><rect x="7" y="9" width="18" height="1"/><rect x="6" y="10" width="7" height="1"/><rect x="14" y="10" width="12" height="1"/><rect x="6" y="11" width="7" height="1"/><rect x="15" y="11" width="11" height="1"/><rect x="6" y="12" width="7" height="1"/><rect x="16" y="12" width="10" height="1"/><rect x="5" y="13" width="8" height="1"/><rect x="17" y="13" width="10" height="1"/><rect x="5" y="14" width="8" height="1"/><rect x="18" y="14" width="9" height="1"/><rect x="5" y="15" width="8" height="1"/><rect x="19" y="15" width="8" height="1"/><rect x="5" y="16" width="8" height="1"/><rect x="18" y="16" width="9" height="1"/><rect x="5" y="17" width="8" height="1"/><rect x="17" y="17" width="10" height="1"/><rect x="5" y="18" width="8" height="1"/><rect x="16" y="18" width="11" height="1"/><rect x="6" y="19" width="7" height="1"/><rect x="15" y="19" width="11" height="1"/><rect x="6" y="20" width="7" height="1"/><rect x="14" y="20" width="12" height="1"/><rect x="6" y="21" width="20" height="1"/><rect x="7" y="22" width="18" height="1"/><rect x="8" y="23" width="16" height="1"/><rect x="9" y="24" width="14" height="1"/><rect x="10" y="25" width="12" height="1"/><rect x="13" y="26" width="6" height="1"/></g></svg>
```

Run: `/usr/bin/python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('Wokyintosh/Resources/video-art.svg'); print('SVG_OK')"`
Expected: `SVG_OK`.

- [ ] **Step 6: Kopiuj grafikę przy budowaniu**

W `Build Wokyintosh.command` zamień linię:

```zsh
cp "$SRC/Resources/app.js" "$RESOURCES/Resources/app.js"
```

na:

```zsh
cp "$SRC/Resources/app.js" "$RESOURCES/Resources/app.js"
cp "$SRC/Resources/video-art.svg" "$RESOURCES/Resources/video-art.svg"
```

- [ ] **Step 7: Zbuduj i sprawdź paczkę**

Run: `./"Build Wokyintosh.command" 2>&1 | tail -3 && ls -l /Applications/Wokyintosh.app/Contents/Resources/Resources/video-art.svg && codesign --verify --deep --strict /Applications/Wokyintosh.app && echo PODPIS_OK`
Expected: `Wokyintosh launched.`, plik `video-art.svg` w paczce, `PODPIS_OK`. Wygląd na ekranie potwierdza Paweł w zadaniu 10.

- [ ] **Step 8: Commit**

```bash
git add Wokyintosh/Resources/video-art.svg Wokyintosh/NowPlayingSelection.swift "Build Wokyintosh.command" Tests/main.swift
git commit -m "feat: przycisk play zamiast okładki dla przeglądarek"
```

### Task 10: Test wycieku i weryfikacja na ekranie doku

**Files:**
- Brak zmian w kodzie. Wyniki trafiają do raportu dla Pawła.

**Interfaces:**
- Consumes: zainstalowana aplikacja z zadań 7–9, `Tests/helper-smoke.command` (zadanie 5), `Run Tests.command`.
- Produces: raport z pomiarami i listą sprawdzeń z sekcji 14 specu.

- [ ] **Step 1: Pełne testy i smoke test**

Run: `./"Run Tests.command" | tail -1 && ./Tests/helper-smoke.command`
Expected: `OK: 108 sprawdzeń`, potem dwie linie `OK:` ze smoke testu.

- [ ] **Step 2: Uruchom 60-minutowy pomiar pamięci w tle**

Uruchom w tle (narzędzie Bash z `run_in_background`):

```bash
LOG="$TMPDIR/wokyintosh-leak.log"; : > "$LOG"
for i in {0..12}; do
  PID=$(pgrep -f 'Helper/nowplaying-helper.pl' | head -1)
  MEM=$(top -l 1 -pid "$PID" -stats mem | tail -1)
  echo "$((i*5)) $PID $MEM" >> "$LOG"
  [ "$i" -lt 12 ] && sleep 300
done
echo KONIEC >> "$LOG"
```

W tym czasie Wokyintosh działa normalnie; najlepiej, żeby coś grało i przynajmniej raz zmieniła się okładka (inny film albo utwór).

- [ ] **Step 3: Oceń pomiar**

Run:

```bash
/usr/bin/python3 - "$TMPDIR/wokyintosh-leak.log" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l[0].isdigit()]
def mb(v):
    v = v.rstrip('+-')
    unit = v[-1].upper()
    n = float(v[:-1])
    return n / 1024 if unit == 'K' else n if unit == 'M' else n / 1048576
pids = {r[1] for r in rows}
values = [(int(r[0]), mb(r[2])) for r in rows]
base = next(v for m, v in values if m == 5)
peak = max(v for _, v in values)
growth = max(v for m, v in values if m >= 5) - base
print(f"próbek {len(values)}, PID-y {sorted(pids)}, szczyt {peak:.1f} MB, wzrost po 5. min {growth:.1f} MB")
ok = len(pids) == 1 and peak < 15 and growth <= 2
print("OK" if ok else "FAIL")
PY
```

Expected: `OK`, jeden PID (brak restartów), szczyt < 15 MB, wzrost ≤ 2 MB. Przy `FAIL` zatrzymaj się i pokaż Pawłowi log z `$TMPDIR/wokyintosh-leak.log` przed jakąkolwiek zmianą.

- [ ] **Step 4: Sprawdzenia, które robi Claude**

Run: `pkill -x Wokyintosh; sleep 3; pgrep -fl 'Helper/nowplaying-helper.pl' || echo BRAK_POMOCNIKA; open -a /Applications/Wokyintosh.app; sleep 5; pgrep -fl 'Helper/nowplaying-helper.pl'`
Expected: `BRAK_POMOCNIKA` po ubiciu aplikacji (pomocnik sam wychodzi po zamknięciu wejścia), potem jeden proces pomocnika po ponownym uruchomieniu (punkt 7 sekcji 14). `pkill` zamiast `osascript … quit`, żeby nie wywołać okna zgody na automatyzację; zwykłe zamknięcie z menu przechodzi przez `bridge.stop()`, które zamyka wejście tak samo.

Punkt 6 sekcji 14 (pkill i powrót) został sprawdzony w zadaniu 7, krok 10; powtórz go, jeśli od tamtej pory zmieniał się kod pomocnika albo nadzoru.

- [ ] **Step 5: Zapas AppleScript w zainstalowanej aplikacji**

To jedyne sprawdzenie, że przy trwałej awarii pomocnika kafelek działa tak jak dziś. Poproś Pawła o włączenie utworu w Music, potem zablokuj bibliotekę pomocnika i uruchom aplikację ponownie:

Run: `chmod 000 /Applications/Wokyintosh.app/Contents/Resources/Helper/NowPlayingHelper.dylib; pkill -x Wokyintosh; sleep 2; open -a /Applications/Wokyintosh.app; sleep 10; pgrep -fl 'Helper/nowplaying-helper.pl' || echo BRAK_POMOCNIKA; /usr/bin/log show --last 1m --style compact --predicate 'process == "Wokyintosh" AND eventMessage CONTAINS "pomocnik"' | tail -4`
Expected: `BRAK_POMOCNIKA` oraz trzy wpisy `zakończył się (kod 2)`, ostatni z `zostaje AppleScript`.

Poproś Pawła o potwierdzenie na ekranie doku, że kafelek pokazuje utwór z Music, pasek się przesuwa, a play/pauza działa.

Przywróć pomocnika:

Run: `chmod 755 /Applications/Wokyintosh.app/Contents/Resources/Helper/NowPlayingHelper.dylib; codesign --verify --deep --strict /Applications/Wokyintosh.app && echo PODPIS_OK; pkill -x Wokyintosh; sleep 2; open -a /Applications/Wokyintosh.app; sleep 5; pgrep -fl 'Helper/nowplaying-helper.pl'`
Expected: `PODPIS_OK` i jeden proces pomocnika.

- [ ] **Step 6: Sprawdzenia na ekranie, które potwierdza Paweł**

Poproś Pawła o sprawdzenie na ekranie doku i odpowiedź na każdy punkt:
1. YouTube w Dii: tytuł, kanał, źródło „Dia", pasek przesuwa się z filmem.
2. Pauza w Dii: kafelek pokazuje pauzę, pasek stoi.
3. Start Music przy spauzowanym YouTube: kafelek przechodzi na Music.
4. Przyciski działają dla Music (wszystkie trzy) i dla YouTube (play/pauza; następny zgodnie z wynikiem zadania 1).
5. Przy YouTube w Dii w ramce okładki widać 1-bitowy przycisk play (zadanie 9).

- [ ] **Step 7: Raport i decyzja o wypchnięciu**

Zacznij od wyniku, potem: liczba testów, wynik smoke testu, pomiar pamięci (szczyt i wzrost), wynik zapasu AppleScript z kroku 5, odpowiedzi Pawła z kroków 5 i 6, wszystko, co nie zadziałało albo zostało pominięte. Na końcu zapytaj: „Wypchnąć `feature/now-playing-mediaremote` na GitHuba?". Bez zgody nie wykonuj `git push`.
