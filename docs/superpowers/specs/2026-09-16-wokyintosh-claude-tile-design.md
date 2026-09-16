# Wokyintosh + kafelek Claude — projekt

Data: 2026-09-16
Baza: fork `SalarFarahani/Wokyintosh` @ `81e77ab`, licencja MIT
Repo: `pawelmnowak1990-Now4czek/wokyintosh-claude`, lokalnie `~/projects/wokyintosh`

## 1. Cel

Wyświetlacz Wokyis (5", 1280x720, dla macOS zwykły drugi ekran o nazwie "Wokyis")
ma pokazywać dashboard Wokyintosha oraz jeden nowy kafelek: licznik sesji Claude Code,
które wymagają uwagi, z animacją gdy Claude pracuje. Do tego cztery poprawki, które
robią różnicę na ekranie chodzącym non stop.

## 2. Zakres

W zakresie:
1. Kafelek Claude w nagłówku dashboardu.
2. Poprawka liczenia RAM.
3. Poprawka przepełnienia liczników CPU.
4. Okno samo ustawia się na ekranie Wokyis.
5. Autostart po zalogowaniu.
6. Zmiana nazwy, identyfikatora aplikacji i podpisów (fork).

Poza zakresem: presja pamięci zamiast procentu RAM, poprawki licznika sieci,
lista nazw sesji na kafelku, klikalność kafelka, wsparcie dla sesji Claude Code
uruchomionych na innych maszynach.

## 3. Źródło danych

Claude Code zapisuje dla każdej żywej sesji plik `~/.claude/sessions/<pid>.json`.
Format jest nieudokumentowany, ustalony przez obserwację i lekturę binarki 2.1.271.

Pola, których używamy:

| Pole | Typ | Zastosowanie |
|---|---|---|
| `pid` | Int | sprawdzenie, czy proces żyje |
| `kind` | String | bierzemy tylko `interactive` |
| `status` | String | `busy`, `shell`, `idle`, `waiting` |
| `startedAt` | Int (ms) | odróżnienie świeżo otwartej sesji |
| `statusUpdatedAt` | Int (ms) | kiedy status się zmienił |
| `updatedAt` | Int (ms) | wykrycie zawieszonego statusu |

Potwierdzone na żywo 2026-09-15: sesja desktopowa przechodzi w `waiting`, gdy czeka
na odpowiedź w oknie dialogowym (22:36:55), i wraca do `busy` po odpowiedzi (22:37:24).
Przejścia `busy` ↔ `idle` pokrywają się z początkiem i końcem odpowiedzi.
W binarce status wyliczany jest z `queuedElicitation` i `topDialogWaitingFor`, a pole
`waitingFor` przyjmuje wartości `dialog open`, `input needed`, `sandbox request`,
`goal proposal`. Sesje z desktopu zapisują te pliki (`entrypoint: claude-desktop`),
wbrew temu, co twierdzi README projektu claude-busy-monitor.

Odrzucone alternatywy: `claude agents --json` (uruchamia 210 MB binarkę przy każdym
odczycie i nie podaje czasu zmiany statusu), własne hooki (zmiana w `~/.claude/settings.json`,
proces przy każdym zdarzeniu, powiadomienie o zgodzie dopiero po ~6 s).

## 4. Logika klasyfikacji

Odczyt co 2 s, katalog `~/.claude/sessions`, pliki `*.json` (pliki `*.key` pomijane).
Nic nie jest zapisywane.

Dla każdego rekordu:
- pomiń, gdy `kind != "interactive"`;
- pomiń, gdy proces nie żyje (`kill(pid, 0)`; `EPERM` liczy się jako żywy);
- `status == "waiting"` → **czeka**;
- `status == "busy" || status == "shell"` → **pracuje**, chyba że `updatedAt > statusUpdatedAt`
  (znany błąd anthropics/claude-code#87131, status zawieszony na `busy`) — wtedy sesja jest pomijana;
- `status == "idle"` oraz `now - statusUpdatedAt <= okno` oraz `statusUpdatedAt - startedAt > 10 s`
  → **skończyła niedawno**;
- w pozostałych przypadkach sesja nie jest liczona.

Okno domyślnie 15 minut, z `UserDefaults`, klucz `ClaudeFinishedWindowMinutes`.
Zmiana bez rekompilacji: `defaults write com.pawelnowak.wokyintosh ClaudeFinishedWindowMinutes 20`.

Pakiet do warstwy widoku (`updateClaude`):

```json
{ "available": true, "attention": 3, "waiting": 1, "finished": 2, "working": true }
```

`available: false`, gdy katalogu nie ma albo żaden plik nie dał się odczytać przy
niepustym katalogu. Błąd odczytu pojedynczego pliku pomija tylko ten plik.

## 5. Kafelek

Położenie: nagłówek, między zegarem a pogodą. `.top` zmienia się z
`grid-template-columns:1fr 25.5vw` na `1fr ~16vw 25.5vw` (dokładna szerokość do
dostrojenia po pierwszym buildzie). Styl `classic-box`, jak reszta dashboardu,
kolory z istniejących zmiennych, więc tryb ciemny działa bez dodatkowej pracy.

Zawartość: nagłówek `Claude`, pikselowa gwiazdka 11x11 (własny rysunek 1-bit, nie
logo Anthropic), duża liczba, podpis po angielsku jak reszta interfejsu.

Stany:

| Sytuacja | Liczba | Podpis |
|---|---|---|
| nic nie czeka, nic nie pracuje | `0` | `all quiet` |
| tylko praca w toku | `0` | `N working` |
| tylko świeżo skończone | `N` | `N done` |
| coś czeka | suma | `N waiting · M done` |
| brak danych | `?` | `no data` |

Gdy `waiting > 0`, liczba dostaje odwrócone kolory i miga co 2 s.
Gdy `working`, gwiazdka animuje się wariantem B: dwie klatki (gwiazda i znak "X"),
600 ms na klatkę, `steps(1,end)`, przełączanie widoczności gotowych klatek w CSS.
Bez pracy animacja jest wyłączona (klasa zdejmowana), bez JavaScriptu w pętli.

## 6. Poprawki

### 6.1 RAM (`SystemMonitor.swift`)

Dziś: `active + inactive + wired + compressed`, co na macOS daje stale ~95%, bo
`inactive` to głównie cache plików (zmierzone 2026-09-15: aplikacja 95,3%, realnie 73,9%).

Po zmianie: `(internal_page_count - purgeable_count) + wire_count + compressor_page_count`,
dzielone przez `ProcessInfo.processInfo.physicalMemory`. Odejmowanie zabezpieczone
przed ujemnym wynikiem.

### 6.2 CPU (`SystemMonitor.swift`)

Dziś: odejmowanie 32-bitowych liczników `natural_t` bez zabezpieczenia. Przy ~1000
tykach na sekundę licznik przekręca się po ok. 50 dniach pracy i Swift ubija aplikację.

Po zmianie: odejmowanie zawijające (`&-`), wynik poprawny również przez przekręcenie.

### 6.3 Okno na Wokyis (`AppDelegate.swift`)

- Wybór ekranu: `localizedName == "Wokyis"`, w drugiej kolejności ekran 1280x720,
  w ostatniej `NSScreen.main` z dotychczasowym oknem z ramką.
- Na Wokyis: okno bez ramki (`.borderless`), `frame` równy `screen.frame`,
  `collectionBehavior` z `.canJoinAllSpaces` i `.stationary`, `canBecomeKey` nadpisane,
  żeby Cmd+Q działało.
- Start bez zabierania fokusu: usunięcie `NSApp.activate(ignoringOtherApps: true)`.
- Obserwacja `NSApplication.didChangeScreenParametersNotification` i ponowne ustawienie
  okna po wybudzeniu lub podłączeniu ekranu.
- Stan na tej maszynie (2026-09-15): osobne przestrzenie na ekran, pasek menu chowany
  automatycznie, więc dostępne jest pełne 1280x720.

### 6.4 Autostart

`SMAppService.mainApp.register()` przy starcie, plus pozycja w menu do włączenia
i wyłączenia. Build wymaga `-framework ServiceManagement`. Aplikacja musi leżeć
w `/Applications`, bo uruchomiona z `build/` albo z Pobranych działa z tymczasowej
kopii (App Translocation) i rejestracja nie ma sensu. Skrypt budujący dostaje krok
instalacji.

## 7. Pliki

Nowe:
- `Wokyintosh/ClaudeMonitor.swift` — odczyt i klasyfikacja, bez zależności od AppKit.
- `Tests/LogicTests.swift`, `Run Tests.command` — testy czystych funkcji.
- `docs/superpowers/specs/` — ten dokument i plan implementacji.

Zmieniane:
- `Wokyintosh/NativeBridge.swift` — osobny timer 2 s i `pushClaude()`, niezależnie od `pushSystem()`.
- `Wokyintosh/SystemMonitor.swift` — poprawki 6.1 i 6.2.
- `Wokyintosh/AppDelegate.swift` — poprawka 6.3, menu z pozycją autostartu.
- `Wokyintosh/Resources/index.html` — kafelek w nagłówku, zmiana stopki.
- `Wokyintosh/Resources/style.css` — kolumna nagłówka, style kafelka, klatki animacji.
- `Wokyintosh/Resources/app.js` — obsługa `updateClaude`.
- `Wokyintosh/Info.plist` — identyfikator `com.pawelnowak.wokyintosh`, nazwa.
- `Build Wokyintosh.command` — nowy plik źródłowy, framework, krok instalacji.
- `README.md` — informacja, że to fork, i lista zmian.

Nie zmieniamy: `LICENSE` (MIT autora zostaje w całości), `NowPlayingMonitor.swift`,
`WeatherService.swift`, `main.swift`.

## 8. Testy

`Run Tests.command` kompiluje `Tests/LogicTests.swift` razem z testowanymi plikami
i uruchamia bez interfejsu. Testowane są czyste funkcje, po wydzieleniu ich z klas:

- klasyfikacja sesji: czeka, skończyła w oknie, skończyła poza oknem, świeżo otwarta
  (poniżej 10 s), zawieszony `busy`, martwy proces, `kind` inny niż `interactive`,
  uszkodzony JSON;
- RAM: znane liczby stron dają znany procent, brak ujemnych wyników przy
  `purgeable > internal`;
- CPU: normalna różnica, różnica przez przekręcenie licznika, pierwszy pomiar.

## 9. Gałęzie i atrybucja

- `main`: tylko 6.1 i 6.2, osobne commity, gotowe do PR do oryginału.
- `feature/claude-tile`: kafelek, okno, autostart, zmiana nazwy i podpisów.
- MIT wymaga zachowania `LICENSE` i noty copyright autora. Stopka aplikacji i README
  mówią wprost: fork Pawła Nowaka na bazie Wokyintosha Salara Farahaniego.

## 10. Weryfikacja po implementacji

1. `Run Tests.command` przechodzi.
2. Build się kompiluje, aplikacja startuje.
3. RAM zgodny z Monitorem aktywności w granicach ok. 1 punktu procentowego.
4. Kafelek: druga sesja w toku animuje gwiazdkę, zakończenie sesji podbija licznik,
   po 15 minutach licznik spada.
5. Prośba o zgodę na narzędzie w drugiej sesji ustawia `waiting` i włącza odwróconą liczbę.
6. Usunięcie katalogu sesji (test na kopii) daje `?`, a nie crash.
7. Okno ląduje na Wokyis, bez ramki, po wybudzeniu wraca na miejsce.
8. Po restarcie Maca aplikacja startuje sama.

## 11. Otwarte niewiadome

- Czy `SMAppService` zadziała przy podpisie ad-hoc. Awaryjnie: ręczne dodanie
  w Ustawieniach → Ogólne → Rzeczy otwierane przy logowaniu.
- Czy prośba o zgodę na narzędzie w sesji desktopowej ustawia `waiting` (kod sugeruje,
  że tak, obserwacji jeszcze nie ma).
- Format plików sesji może zmienić się przy aktualizacji Claude Code. Zabezpieczenie:
  kafelek pokazuje `?`, aplikacja działa dalej.
