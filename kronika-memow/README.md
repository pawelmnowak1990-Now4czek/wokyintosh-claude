# Kronika memów

Memy historyczne na X i inne platformy. Każdy mem to prawdziwe wydarzenie z konkretną datą, znany mem jako puenta i prawdziwy fakt w opisie. Grafika jest w stylu malarstwa epoki, której dotyczy (tkanina z Bayeux dla 1066, fresk dla Rzymu, Matejko dla Grunwaldu).

> Folder `kronika-memow/` jest samodzielnym projektem. Tymczasowo leży w repozytorium `wokyintosh-claude` na branchu `claude/historical-character-meme-content-tsou7v`, bo integracja GitHub nie może zakładać nowych repozytoriów. Jak go przenieść do osobnego repo, opisuje [HANDOVER.md](HANDOVER.md#przeniesienie-do-osobnego-repozytorium).

## Co tu jest

| Ścieżka | Zawartość |
|---|---|
| [HANDOVER.md](HANDOVER.md) | Stan projektu i plan następnej sesji (test integracji z Lovable). **Zacznij od tego pliku.** |
| [CLAUDE.md](CLAUDE.md) | Zasady pracy dla Claude w tym projekcie |
| [docs/strategia.md](docs/strategia.md) | Koncepcja, formuła memu, style epok, narzędzia, platformy, ryzyka |
| [docs/kalendarz-rocznic.md](docs/kalendarz-rocznic.md) | Najbliższe rocznice, daty bez memów, plan publikacji |
| [kronika/](kronika/) | Kod strony Kronika memów i opis jej bazy danych |
| [data/ideas/](data/ideas/) | Kopia bazy pomysłów (JSON, jeden plik na pomysł), stan z 27 IX 2026 |
| [tools/prompt.js](tools/prompt.js) | Skrypt, który składa prompt graficzny z pliku pomysłu |

## Kronika memów

Bank pomysłów ze statusem (pomysł → grafika → opublikowane), kadrami, opisami do postów i promptami graficznymi w wersji PL, EN i bez tekstu:
**https://claude.ai/artifact/3sgGXFEjGnAyaLecsyLHbb** (prywatna, widoczna tylko dla właściciela).

Źródłem prawdy jest baza strony (kolekcja `ideas`). Pliki w `data/ideas/` to kopia do pracy offline i dla skryptów.

## Prompt z wiersza poleceń

```bash
node tools/prompt.js --list                        # lista pomysłów
node tools/prompt.js 1066-harold-wilhelm           # prompt z tekstem PL
node tools/prompt.js 1066-harold-wilhelm en        # prompt z tekstem EN
node tools/prompt.js 1066-harold-wilhelm none      # bez tekstu (napisy dodajesz sam)
node tools/prompt.js 1066-harold-wilhelm en --caption   # plus opis do posta
```

Skrypt używa tej samej funkcji `buildPrompt` co strona, więc prompty są identyczne.
