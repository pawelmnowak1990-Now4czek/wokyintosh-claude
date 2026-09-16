# Wokyintosh + systemowe Now Playing (MediaRemote) — projekt

Data: 2026-09-16
Gałąź: `feature/now-playing-mediaremote`, odbita od `feature/claude-tile` @ `ace28d6`
Repo: `pawelmnowak1990-Now4czek/wokyintosh-claude`, lokalnie `~/projects/wokyintosh`

## 1. Cel

Kafelek Now Playing ma pokazywać to, co faktycznie gra na Macu — także film na YouTube
w przeglądarce Dia — a nie tylko Spotify i Music. Dane bierzemy z systemowego
„Now Playing" (framework MediaRemote, ten sam, z którego korzysta Centrum sterowania).
Przyciski i okładka mają działać dla każdego źródła, które je udostępnia.

## 2. Zakres

W zakresie:
1. Pomocnik w Objective-C (biblioteka dynamiczna) ładowany przez `/usr/bin/perl`, który czyta stan wszystkich odtwarzaczy
   z MediaRemote i wykonuje komendy.
2. Nadzór nad pomocnikiem w aplikacji: start, restart, wykrywanie zawieszenia, trwały zapas.
3. Wybór odtwarzacza do pokazania i doliczanie pozycji.
4. Okładka z MediaRemote serwowana stronie przez własny schemat adresu.
5. Przyciski poprzedni / play-pauza / następny kierowane do wybranego odtwarzacza.
6. Zapas: obecny odczyt i sterowanie przez AppleScript dla Spotify i Music.
7. 1-bitowa grafika przycisku play dla przeglądarek bez okładki (decyzja Pawła po spike'u).

Poza zakresem: przewijanie paska kliknięciem, pokazywanie kilku odtwarzaczy naraz,
wybór źródła ręcznie, powiadomienia MediaRemote zamiast odpytywania, rozpoznawanie
„YouTube" jako źródła (pokazujemy nazwę aplikacji, np. „Dia"), okładka dla Spotify
z AppleScript, gdy MediaRemote jej nie poda.

## 3. Tło i ustalenia z testów (2026-09-16, macOS 27.0, build 26A428)

- Od macOS 15.4 MediaRemote zwraca dane tylko procesom podpisanym przez Apple. Wywołanie
  `MRMediaRemoteGetNowPlayingInfo` z własnej binarki zwróciło `nil` i PID źródła 0.
- Ta sama biblioteka załadowana do `/usr/bin/perl` (DynaLoader) dostaje pełne dane:
  Music zwróciło 28 pól (tytuł, wykonawca, album, długość, pozycja, tempo).
- Zarejestrowane odtwarzacze w trakcie filmu na YouTube: `com.apple.Music` (spauzowane)
  i `company.thebrowser.dia` (grające; asercje zasilania „Playing audio" i „Video Wake Lock").
- System nadal wskazywał Music jako aktywny odtwarzacz, a `MRMediaRemoteGetNowPlayingInfo`
  przekroczyło 3 s. Dlatego pytamy każdego klienta osobno i sami wybieramy źródło.
- Sygnatura odczytana z deasemblacji: `MRMediaRemoteGetNowPlayingInfoForClient(client,
  origin, options, queue, block)`, gdzie `origin` to `MRMediaRemoteGetLocalOrigin()`,
  `options` może być `NULL`, a blok dostaje `(CFDictionaryRef info, void *)`.
  Inna kolejność argumentów kończy się crashem (kody 134 i 139).
- Dia zwraca 13 pól: `Title`, `Artist`, `Album`, `Duration`, `ElapsedTime`, `PlaybackRate`,
  `Timestamp`, `CurrentPlaybackDate`, `ContentItemIdentifier`, `ArtworkIdentifier`,
  `ArtworkMIMEType` (`image/jpeg`), `ArtworkDataWidth`, `ArtworkDataHeight`. Samych bajtów
  okładki w tym wywołaniu nie ma.
- `ElapsedTime` to pozycja z chwili `Timestamp`, nie bieżąca (3048 s o 10:16:34).
- Pomiar pomocnika w pętli co 1 s przez 20 odczytów: pamięć (phys_footprint) 2,9 MB na
  starcie, 4,8 MB po 10. i 20. odczycie, CPU 0,19% jednego rdzenia.
- Z deasemblacji (podczas pisania planu):
  - `MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork(origin, includeArtwork, queue, block)`
    to `ForClient` z klientem `NULL`, więc trzeci argument `ForClient` jest flagą okładki
    (sprawdzany jako 32-bitowa wartość, `cbz w22`); przy fladze MediaRemote dociąga
    kolejkę odtwarzania z okładką.
  - `MRMediaRemoteSendCommandToClient(command, options, origin, client, appOptions, queue,
    block)` zwraca `Boolean`; blok dostaje `(uint32_t error, CFArrayRef statuses)`
    (opakowanie `MRCommandResult`). Wartości komend: `togglePlayPause` = 2,
    `nextTrack` = 4, `previousTrack` = 5.
  - `MRNowPlayingClientGetDisplayName(client)` zwraca `CFStringRef`.
  Działanie komend i okładki na żywo sprawdza spike (sekcja 11).

## 4. Architektura

| Element | Plik | Odpowiedzialność |
|---|---|---|
| Pomocnik | `Helper/NowPlayingHelper.m` (Objective-C) → `NowPlayingHelper.dylib` | Co 1 s wypisuje stan odtwarzaczy, wysyła okładki, wykonuje komendy. Bez decyzji o wyborze źródła. |
| Starter | `Helper/nowplaying-helper.pl` | Ładuje dylib przez DynaLoader; przy błędzie ładowania wypisuje błąd na stderr i kończy kodem 2. |
| Protokół | `Wokyintosh/MediaRemoteProtocol.swift` | Typy wiadomości, parsowanie linii, kodowanie komend. Czysta logika. |
| Wybór | `Wokyintosh/NowPlayingSelection.swift` | Wybór odtwarzacza, doliczanie pozycji, mapowanie na `NowPlayingData`, reguły adresu okładki. Czysta logika. |
| Nadzór | `Wokyintosh/MediaRemoteHelper.swift` | Proces (`Process` + potoki), ostatni stan, magazyn okładek, komendy z oczekiwaniem na `ack`, polityka restartów (`HelperRestartPolicy`, czysta). |
| Okładki dla strony | `Wokyintosh/ArtworkSchemeHandler.swift` | `WKURLSchemeHandler` dla schematu `wokyintosh-art`, bajty z magazynu okładek. |
| Odczyt | `NowPlayingMonitor.swift` (zmiana) | `snapshot()` najpierw z pomocnika, potem AppleScript; `perform(_:)` kieruje komendę do pomocnika albo do `MediaControl`. |
| Sterowanie AppleScript | `MediaControl.swift` (bez zmian w logice) | Zostaje jako zapas dla Spotify i Music. |
| Spinanie | `NativeBridge.swift`, `AppDelegate.swift` (zmiany) | Bridge tworzy i zatrzymuje pomocnika, AppDelegate rejestruje schemat i kieruje przyciski przez `bridge.performMedia(_:)`. |

Uwaga do projektu z rozmowy: sterowanie przez pomocnika trafia do
`NowPlayingMonitor.perform(_:)` zamiast do `MediaControl.perform()`. Zachowanie jest to samo,
a `MediaControl` zostaje czystą ścieżką AppleScript.

Pomocnik uruchamiany jest poleceniem:
`/usr/bin/perl <app>/Contents/Resources/Helper/nowplaying-helper.pl <app>/Contents/Resources/Helper/NowPlayingHelper.dylib`.
Pętla działa w konstruktorze biblioteki (`__attribute__((constructor))`), wejście czytane
jest na osobnym wątku, a stdout jest buforowany liniami.

## 5. Protokół

Jedna linia JSON na wiadomość, kodowanie UTF-8, znak nowej linii na końcu.

Pomocnik → aplikacja:

```json
{"type":"hello","version":1}
{"type":"state","players":[{"bundle":"company.thebrowser.dia","name":"Dia","title":"…","artist":"Asmongold TV","album":"","duration":4083.08,"elapsed":3048.0,"rate":1.0,"timestamp":1789553794.0,"artworkId":"7ec2014f5eb8fe62"}]}
{"type":"artwork","bundle":"company.thebrowser.dia","artworkId":"7ec2014f5eb8fe62","mime":"image/jpeg","data":"<base64>"}
{"type":"ack","cmd":"togglePlayPause","bundle":"company.thebrowser.dia","ok":true}
{"type":"error","reason":"missing-symbol","symbol":"MRMediaRemoteGetNowPlayingClients"}
```

- `hello` — pierwsza linia, gdy wszystkie potrzebne symbole się znalazły.
- `state` — co 1 s; tylko odtwarzacze z niepustym tytułem. `timestamp` w sekundach od
  1970-01-01 (Unix), przeliczony z `Timestamp` MediaRemote. Brakujące liczby to `0`,
  brakujące teksty to `""`, brak okładki to `"artworkId":""`.
- `artwork` — tylko gdy `artworkId` danego odtwarzacza jest nowy; pomijana, gdy dane
  mają więcej niż 2 MB przed kodowaniem base64.
- `ack` — odpowiedź na każdą komendę.
- `error` — przed wyjściem z kodem 3.

Aplikacja → pomocnik:

```json
{"cmd":"togglePlayPause","bundle":"company.thebrowser.dia"}
```

Dozwolone `cmd`: `togglePlayPause`, `nextTrack`, `previousTrack`. Inne dostają
`ack` z `ok:false`.

Kody wyjścia pomocnika: `0` — zamknięte wejście (normalne zakończenie), `2` — nie udało
się załadować biblioteki, `3` — brak symbolu MediaRemote.

## 6. Wybór odtwarzacza i pozycja

Wejście: lista `players` z ostatniego stanu, bieżący czas, poprzednio wybrany `bundle`.

1. Kandydaci: odtwarzacze z tytułem niepustym po obcięciu spacji.
2. Jeśli któryś gra (`rate > 0`), wybierz grający z największym `timestamp`.
3. W przeciwnym razie wybierz kandydata z największym `timestamp`.
4. Przy remisie `timestamp` wygrywa poprzednio wybrany `bundle`, jeśli jest wśród
   remisujących; inaczej pierwszy w kolejności z listy.
5. Brak kandydatów → brak wyboru.

Pozycja:
- `rate > 0` i `timestamp > 0`: `elapsed + max(0, teraz − timestamp) × rate`,
- w pozostałych przypadkach (pauza albo brak `timestamp`): `elapsed`,
- wynik nie mniejszy niż 0 i, gdy `duration > 0`, nie większy niż `duration`.

## 7. Mapowanie na `NowPlayingData` i okładka

| Pole | Wartość |
|---|---|
| `playing` | `true` |
| `app` | `name`; gdy pusty — `bundle` |
| `track` | `title` |
| `artist` | `artist` |
| `duration` | `duration` |
| `position` | pozycja z sekcji 6 |
| `state` | `"playing"` gdy `rate > 0`, inaczej `"paused"` |
| `artworkURL` | reguła poniżej |

Adres okładki:
1. Jeśli magazyn okładek ma bajty dla `artworkId` wybranego odtwarzacza →
   `wokyintosh-art://artwork/<artworkId>`.
2. Jeśli `bundle == com.apple.Music` → obecne wyszukiwanie w iTunes Search API
   (z pamięcią podręczną jak dziś).
3. Jeśli `bundle` to przeglądarka (`company.thebrowser.dia`, `company.thebrowser.Browser`,
   `com.google.Chrome`, `com.apple.Safari`) → `video-art.svg`, 1-bitowy przycisk play z zasobów
   strony. Kafelek nie wie, czy w przeglądarce gra YouTube, więc grafika jest ogólna, bez logo.
4. Inaczej `""` (strona pokazuje grafikę zastępczą).

Magazyn okładek trzyma po jednej okładce na `bundle` i tylko dla odtwarzaczy obecnych
w ostatnim stanie. Schemat `wokyintosh-art` odpowiada bajtami i `mime` z magazynu,
a dla nieznanego `artworkId` błędem, co strona obsługuje już dziś (`img.onerror`).

## 8. Sterowanie

`NowPlayingMonitor.perform(action)`:
1. Jeśli pomocnik ma świeży stan i ostatni `snapshot()` wybrał odtwarzacz obecny w tym
   stanie → komenda do pomocnika dla tego `bundle`
   (`previous` → `previousTrack`, `playPause` → `togglePlayPause`, `next` → `nextTrack`).
2. Jeśli `ack` ma `ok:false` albo nie przyjdzie w 1 s, a `bundle` to `com.spotify.client`
   lub `com.apple.Music` → `MediaControl.perform(action)`. Dla innych źródeł tylko wpis w logu.
3. Jeśli pomocnik nie ma świeżego stanu albo nic nie jest wybrane → `MediaControl.perform(action)`.

Po komendzie zostaje obecne odświeżenie kafelka po 0,3 s.

## 9. Błędy i zapas

„Świeży stan" = ostatnia linia `state` odebrana mniej niż 5 s temu.
Gdy stanu nie ma albo jest nieświeży, `snapshot()` używa obecnego odczytu AppleScript.

| Sytuacja | Reakcja |
|---|---|
| `/usr/bin/perl` nie istnieje lub nie daje się uruchomić | Trwały zapas do restartu aplikacji, jeden wpis w logu |
| Kod wyjścia 3 | Trwały zapas do restartu aplikacji |
| Brak `hello` w 5 s, kod 2 albo zakończenie przed pierwszym `state` | Porażka startu; restart po przerwie |
| 3 porażki startu z rzędu | Trwały zapas do restartu aplikacji |
| Zakończenie po co najmniej jednym `state` | Restart po przerwie |
| Brak jakiejkolwiek linii przez 15 s | SIGTERM, po 2 s SIGKILL, restart po przerwie |
| Linia niebędąca poprawnym JSON-em albo nieznany `type` | Pominięta |
| Linia dłuższa niż 4 MB | Odrzucona |
| Świeży stan bez kandydatów | Odczyt AppleScript |
| Zamknięcie aplikacji | `bridge.stop()` zamyka wejście pomocnika i czeka do 1 s, potem SIGTERM |
| Crash aplikacji | Pomocnik wychodzi sam po zamknięciu wejścia (kod 0) |

Przerwy przed restartem: 1, 2, 4, 8, 16, 32, 60, 60… s. Pierwsza linia `state` po
starcie zeruje licznik porażek i przerwę.

Bezpieczeństwo: pomocnik czyta tylko metadane odtwarzania; komendy są na białej liście;
aplikacja wysyła komendę tylko do `bundle` z ostatniego stanu.

## 10. Pliki

Nowe:
- `Helper/NowPlayingHelper.m`
- `Helper/nowplaying-helper.pl`
- `Wokyintosh/MediaRemoteProtocol.swift`
- `Wokyintosh/NowPlayingSelection.swift`
- `Wokyintosh/MediaRemoteHelper.swift`
- `Wokyintosh/ArtworkSchemeHandler.swift`
- `Wokyintosh/Resources/video-art.svg`
- `Tests/helper-smoke.command`

Zmieniane:
- `Wokyintosh/NowPlayingMonitor.swift` — `init(helper:)`, nowa kolejność w `snapshot()`,
  `perform(_:)`, wyszukiwanie w iTunes dostępne dla reguły okładki.
- `Wokyintosh/NativeBridge.swift` — tworzenie, start i stop pomocnika; `performMedia(_:)`.
- `Wokyintosh/AppDelegate.swift` — rejestracja schematu `wokyintosh-art`; przyciski przez
  `bridge.performMedia(_:)`.
- `Build Wokyintosh.command` — kompilacja dyliba (`clang -dynamiclib -fblocks -O2`,
  ta sama architektura), kopiowanie `Helper/` do `Contents/Resources/Helper/` przed podpisem,
  kopiowanie `video-art.svg` do zasobów strony,
  nowe pliki Swift w kompilacji.
- `Run Tests.command`, `Tests/main.swift` — nowe testy.
- `README.md` — punkt o systemowym Now Playing w notce forka.

## 11. Testy

1. Spike przed kodem (pierwsze zadanie planu), na YouTube w Dii i na Music:
   - działanie `MRMediaRemoteSendCommandToClient` (sygnatura z sekcji 3) dla
     `togglePlayPause`, `nextTrack`, `previousTrack` oraz znaczenie `error` i `statuses`,
   - bajty okładki z flagą `includeArtwork` dla Dii i Music,
   - wynik dopisany do sekcji 12 tego dokumentu przed dalszą pracą.
2. Testy jednostkowe w `Run Tests.command`:
   - parsowanie `hello`, `state`, `artwork`, `ack`, `error`; linie uszkodzone, z brakami,
     z nieznanym typem, za długie,
   - kodowanie komend i biała lista,
   - wybór odtwarzacza: gra kontra pauza, dwa grające, sama pauza, remis z poprzednim
     wyborem, brak tytułu, pusta lista,
   - pozycja: gra, pauza, obcięcie do długości, `teraz < timestamp`, `duration == 0`,
   - mapowanie na `NowPlayingData` i cztery reguły adresu okładki,
   - decyzja o zapasie AppleScript po `ack` (Spotify/Music tak, inne nie),
   - polityka restartów: kolejne przerwy, próg 3 porażek, kod 3, zerowanie po `state`.
3. `Tests/helper-smoke.command` na zbudowanym dylibie:
   - `hello` i co najmniej 3 poprawne linie `state` w 5 s,
   - komenda do nieistniejącego `bundle` daje `ack` z `ok:false`,
   - zamknięcie wejścia kończy proces kodem 0 w ciągu 2 s.
4. Test wycieku: pomocnik 60 minut, pomiar pamięci co 5 minut. Warunek: poniżej 15 MB
   i wzrost po 5. minucie nie większy niż 2 MB.

## 12. Otwarte niewiadome

- Czy Dia/YouTube reaguje na komendy wysłane z odczytaną sygnaturą. Jeśli nie: przyciski
  dla źródeł spoza Spotify/Music nic nie robią (tylko wpis w logu).
- Czy flaga `includeArtwork` daje bajty okładki. Jeśli nie: reguły 2–4 z sekcji 7.
- Czy YouTube obsługuje `nextTrack`/`previousTrack` poza playlistą.
- Czy strona ładowana z `file://` wyświetla obrazki ze schematu `wokyintosh-art`.
- Apple może zamknąć furtkę z `/usr/bin/perl` albo usunąć perla z systemu; wtedy działa
  zapas z sekcji 9.

**Wynik spike'a (2026-09-16):**
- Dia: play/pauza działa: tak; `error` = 0; `statuses` = [__NSCFNumber=0] (oba wywołania CMD=2).
- Music: następny/poprzedni działa: tak; `error` = 0; `statuses` = [__NSCFNumber=0] (CMD=4 i CMD=5).
- Okładka z flagą: Dia 0 B (`image/jpeg`), Music 0 B (`(null)`).
- Decyzja dla pomocnika: `ok` = `error == 0 && statusesOK(statuses)` — przy wszystkich zadziałanych
  komendach `statuses` zawierało wyłącznie `__NSCFNumber=0`, więc spełnia regułę `statusesOK`
  z briefu zadania 1.

## 13. Gałęzie i atrybucja

Praca na `feature/now-playing-mediaremote`. Commity po polsku, bez stopki z atrybucją.
Nic z tej zmiany nie trafia na `main` (poprawki dla autora oryginału), bo dotyczy tylko forka.

## 14. Weryfikacja po implementacji

Na ekranie Wokyis, po instalacji przez `Build Wokyintosh.command`:
1. YouTube w Dii: tytuł, kanał, źródło „Dia", pasek przesuwa się z filmem.
2. Pauza w Dii: kafelek pokazuje pauzę, pasek stoi.
3. Start Music przy spauzowanym YouTube: kafelek przechodzi na Music.
4. Przyciski działają dla Music (wszystkie trzy) i dla YouTube (zgodnie z wynikiem spike'a).
5. Przy YouTube w Dii w ramce okładki widać 1-bitowy przycisk play.
6. `pkill -f nowplaying-helper` w trakcie odtwarzania: kafelek dalej pokazuje Music przez
   AppleScript, pomocnik wraca sam, a kafelek wraca do danych z MediaRemote.
7. Po zamknięciu Wokyintosha nie zostaje żaden proces `perl` z pomocnikiem.

Zaakceptowany kompromis (decyzja Pawła, 2026-09-16): jeśli MediaRemote nie poda okładki
dla Spotify, kafelek pokaże grafikę zastępczą zamiast obecnej okładki z AppleScript.
Paweł nie używa Spotify, więc nie dokładamy zapasowego odczytu okładki.
