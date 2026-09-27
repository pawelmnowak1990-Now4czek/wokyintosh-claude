# Handover: test integracji Claude ↔ Lovable

Stan na **27 września 2026**. Kolejna sesja ma przetestować połączenie z Lovable, a potem wykorzystać je w projekcie memów.

## W skrócie

- **Projekt:** memy historyczne. Schemat: data i miejsce, prawdziwe wydarzenie, mem jako puenta, fakt w opisie, grafika w stylu epoki. Szczegóły w [docs/strategia.md](docs/strategia.md).
- **Kronika memów:** https://claude.ai/artifact/3sgGXFEjGnAyaLecsyLHbb. Zawiera 23 pomysły, wszystkie w statusie „Pomysł”. Kopia bazy leży w [data/ideas/](data/ideas/).
- **Najbliższy termin:** poniedziałek **28 IX 2026**, 960. rocznica lądowania Wilhelma. Pomysł `1066-harold-wilhelm` (tkanina z Bayeux) jest gotowy, brakuje tylko grafiki.
- **Lovable:** konektor jest podłączony i działa. 27 IX sprawdziłem go wyłącznie odczytem: nic nie zmieniłem, nie zużyłem kredytów.
- **Cel następnej sesji:** sprawdzić cały cykl bez klikania w interfejsie Lovable (odczyt → zmiana → podgląd zmian → publikacja), a potem zbudować w Lovable generator grafik do memów.

## Jak zacząć następną sesję

1. Konektor Lovable musi być włączony. Jest podłączony na https://claude.ai/customize/connectors. Nowa sesja widzi go od startu.
2. Uruchom sesję w repozytorium `pawelmnowak1990-Now4czek/wokyintosh-claude`, branch `claude/historical-character-meme-content-tsou7v`. Jeśli projekt został już przeniesiony do osobnego repo, uruchom ją tam.
3. Wklej jako pierwszą wiadomość:

```
Przeczytaj kronika-memow/HANDOVER.md i kronika-memow/CLAUDE.md. Kontynuujemy projekt
Kronika memów. Cel tej sesji: przetestować połączenie z Lovable według planu z handovera
(fazy A–C), a potem zaproponować generator grafik do memów w Lovable (faza D).
Zanim zużyjesz kredyty Lovable albo cokolwiek opublikujesz, zapytaj mnie.
```

## Lovable: stan z 27 IX 2026

Workspace **„Paweł's Lovable”**, id `hOavuFj36jPwQJGuhUD5`, plan **Pro** (konektor MCP wymaga Pro albo Business). Rola: owner.

| Projekt | ID | Opublikowany | Ostatnia edycja | Uwagi |
|---|---|---|---|---|
| GA4 Audit Buddy | `e236c82b-b4f4-49ed-aecc-38ca14bb9526` | tak, publiczny | 25 IX 2026 | działa na produkcji |
| Polish CV Creator | `14e529a7-63a0-4136-9c4b-a7cfee24543e` | tak, publiczny | 25 IX 2026 | działa na produkcji |
| Figure Paint Match | `72ac3349-233b-4c6f-bd8f-104ebaf4fe26` | nie | 25 IX 2026 | farby do figurek, aktywnie rozwijany |
| My Analytics Hub | `629f7262-b298-4e8b-be3d-486c7d783e55` | tak, publiczny | 15 IX 2026 | **portfolio zawodowe, nie ruszać bez zgody** |
| Birthday Invite Maker | `1a301ee5-d81a-4fe9-9833-901397ed1976` | nie | 25 IV 2026 | nieużywany od kwietnia, **najbezpieczniejszy do testów** |

Link do edytora dowolnego projektu: `https://lovable.dev/projects/<ID>`.

### Narzędzia konektora (najważniejsze)

| Narzędzie | Co robi | Koszt |
|---|---|---|
| `get_me`, `list_workspaces`, `get_workspace`, `list_projects`, `get_project` | odczyt kont i projektów | darmowe |
| `list_files`, `read_file`, `list_edits`, `get_diff`, `list_messages` | podgląd kodu, historii i zmian | darmowe |
| `send_message` | polecenie dla agenta Lovable w projekcie; `plan_mode=true` = tylko plan, bez zmian w kodzie | **zużywa kredyty** |
| `create_project`, `remix_project` | nowy projekt albo kopia istniejącego | **zużywa kredyty** |
| `deploy_project` | publikacja na lovable.app, zwraca publiczny adres (opcjonalny parametr `name` = slug) | **publikuje publicznie** |
| `set_project_visibility` | kto może edytować projekt (restricted i workspace_view wymagają planu Business) | — |
| `query_database`, `get_database_status` | baza Lovable Cloud projektu | odczyt |

Jeśli `send_message` zwróci status `awaiting_input`, agent czeka na decyzję człowieka (np. zgodę na narzędzie albo limit wydatków). Odpowiedzieć da się tylko w edytorze Lovable. Nowe `send_message` nie odpowiada na pauzę, tylko ją zastępuje.

## Plan testu

**Zasady bezpieczeństwa (obowiązują w każdej fazie):**
- Przed każdym `send_message`, `create_project`, `remix_project` i `deploy_project` pytaj użytkownika. Pierwsze trzy zużywają kredyty, ostatnie publikuje stronę publicznie.
- Nie publikuj ani nie zmieniaj projektów działających na produkcji (GA4 Audit Buddy, Polish CV Creator, My Analytics Hub) bez wyraźnej zgody na konkretny projekt.
- Nigdy nie proś o wklejenie kluczy ani haseł do czatu.

### Faza A: odczyt (darmowa)
Projekt: Birthday Invite Maker.
1. `get_project`: nazwa, adresy, stan publikacji.
2. `list_files`, a potem `read_file` dla `src/App.tsx` (albo odpowiednika): czy widzimy kod.
3. `list_edits` i `list_messages`: czy widać historię.

Sukces: czytamy kod i historię projektu bez otwierania Lovable.

### Faza B: zmiana bez publikacji (kredyty, za zgodą)
1. `send_message` z `plan_mode=true`, np. „Zaproponuj zmianę tekstu w stopce na «Test integracji z Claude, 2026»”. Sprawdzamy, czy tryb planu nie rusza kodu.
2. `send_message` bez planu, z tą samą drobną zmianą.
3. `get_diff`: czy widać dokładnie tę zmianę.
4. Zanotuj, ile kredytów zużyła jedna wiadomość (użytkownik sprawdza saldo w Lovable przed testem i po nim).

Sukces: zmiana w kodzie jest widoczna w `get_diff` i w `preview_url`.

### Faza C: publikacja bez klikania (publiczna, za zgodą)
1. `deploy_project` dla Birthday Invite Maker. Najpierw zapytaj o slug (`name`), bo adres będzie publiczny.
2. Otwórz zwrócony adres. Uwaga: polityka sieci tego środowiska może blokować `*.lovable.app` (blokowała już `docs.lovable.dev` i `api.openai.com`). Wtedy weryfikuje użytkownik w przeglądarce.
3. Opcjonalnie: druga drobna zmiana i ponowny `deploy_project`, żeby potwierdzić, że aktualizacja opublikowanej strony też działa bez interfejsu.

Sukces: to jest właściwy cel użytkownika. Claude publikuje zmiany, a użytkownik nie klika „Publish”.

### Faza D: generator grafik do memów (kredyty, za zgodą, najpierw plan)
Nowy projekt Lovable (`create_project`, workspace `hOavuFj36jPwQJGuhUD5`), najpierw jako rozmowa w `plan_mode`. Zakres do uzgodnienia z użytkownikiem:
- import pomysłów z `data/ideas/*.json` (schemat opisany w [kronika/README.md](kronika/README.md)),
- złożenie promptu PL / EN / bez tekstu tą samą logiką co `buildPrompt` w `kronika/kronika-memow.html`,
- generowanie obrazów przez **Lovable AI** (wbudowane modele Gemini, bez własnego klucza API, płatne z kredytów),
- galeria wariantów dla każdego pomysłu, wybór najlepszego, pobieranie pliku.

Do rozstrzygnięcia: czy Kronika zostaje jako artifact, czy przenosi się do aplikacji Lovable (wtedy baza w Lovable Cloud i jedno miejsce na wszystko).

### Faza E: pierwsza grafika
Harold 1066 (`node tools/prompt.js 1066-harold-wilhelm pl`) do publikacji **28 IX**. Jeśli generator z fazy D nie będzie gotowy na czas, użytkownik generuje grafikę ręcznie w ChatGPT (GPT Image 2).

## Generowanie grafik: co już wiemy

- **Claude nie ma własnego generatora obrazów.** Grafiki umie tylko rysować kodem (SVG, HTML, Python), co nie wystarcza do ilustracji w stylu epoki.
- **Gemini API** (Nano Banana): serwer `generativelanguage.googleapis.com` jest osiągalny z tego środowiska. Wystarczy klucz z Google AI Studio dodany w ustawieniach środowiska jako zmienna `GEMINI_API_KEY` (menu środowiska w pasku tytułu → Edit). Przez API obrazy nie mają widocznego znaczka Gemini.
- **OpenAI API** (GPT Image 2): `api.openai.com` jest **zablokowany** przez politykę sieci środowiska. Wymaga dodania domeny do dozwolonych oraz zmiennej `OPENAI_API_KEY`.
- **Lovable AI**: generowanie obrazów wbudowane w aplikacje Lovable, bez własnego klucza (faza D).
- **Ręcznie**: najlepszy wybór to ChatGPT z GPT Image 2 (tekst, polskie znaki, trzymanie się poleceń). Gemini lepiej trzyma spójność postaci, Midjourney V8.1 daje najładniejszy styl malarski.

## Kronika memów: jak ją aktualizować

- Adres: https://claude.ai/artifact/3sgGXFEjGnAyaLecsyLHbb, baza: kolekcja `ideas`, schemat w [kronika/README.md](kronika/README.md).
- Dodawanie i zmiana pomysłów: narzędzie `ArtifactData` z adresem strony (`set`, `update`, `batch`). Strony nie trzeba wtedy publikować ponownie.
- Zmiana kodu strony: edytuj `kronika/kronika-memow.html`, potem `Artifact` → publish z parametrem `url` strony. Najpierw odczytaj stronę (`action: "read"`), bo narzędzie odrzuca publikację bez odczytu.
- Po zmianach odśwież kopię w `data/ideas/` (`ArtifactData` → `list`, `out_dir`) i zacommituj ją.

## Przeniesienie do osobnego repozytorium

Integracja GitHub nie może tworzyć repozytoriów (błąd 403 „Resource not accessible by integration”). Jeśli użytkownik chce osobne repo:
1. Użytkownik zakłada na GitHubie puste prywatne repo, np. `kronika-memow`, i daje do niego dostęp aplikacji Claude na https://claude.ai/connect-github.
2. Claude dołącza je do sesji (`add_repo`, dostęp `push`) i przenosi folder razem z historią:
   ```bash
   git subtree split --prefix=kronika-memow -b kronika-export
   git push https://github.com/pawelmnowak1990-Now4czek/kronika-memow.git kronika-export:main
   ```
3. Kolejne sesje uruchamiamy już w nowym repo.

## Otwarte pytania do użytkownika

1. Który projekt Lovable ma pierwszy dostać publikowanie bez klikania, gdy test przejdzie? Najbardziej aktywne to GA4 Audit Buddy, Polish CV Creator i Figure Paint Match.
2. Czy przenosimy `kronika-memow` do osobnego repozytorium?
3. Konto angielskie, polskie czy oba? Wybrana nazwa konta? Propozycje w [docs/strategia.md](docs/strategia.md).
4. Budżet na generowanie grafik: kredyty Lovable czy klucz Gemini API?
5. Czy Kronika zostaje artifactem, czy przenosimy ją do aplikacji Lovable?

## Czego nie sprawdziłem

- Klikania na opublikowanej stronie Kroniki (status, notatki, dodawanie pomysłu). Logikę testowałem lokalnie na danych testowych, a zapis do bazy przez `ArtifactData`.
- Żadnej operacji w Lovable poza odczytem profilu, workspace i listy projektów.
