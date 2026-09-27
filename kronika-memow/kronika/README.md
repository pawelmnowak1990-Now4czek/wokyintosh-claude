# Kronika memów: strona i baza

- **Strona:** https://claude.ai/artifact/3sgGXFEjGnAyaLecsyLHbb (artifact, prywatny). Uprawnienia: `db`.
- **Kod:** [kronika-memow.html](kronika-memow.html), czysty HTML, CSS i JS bez bibliotek. Czcionki z Google Fonts: Grenze Gotisch, EB Garamond, IBM Plex Sans.
- **Baza:** kolekcja `ideas`, jeden dokument na pomysł. Id to rok i skrót, np. `1066-harold-wilhelm`, `p075-cezar-piraci` (p = p.n.e.), `n064-neron` (n = n.e.). Pomysły dodane w formularzu strony mają id `u-…`.

## Schemat dokumentu

| Pole | Typ | Opis |
|---|---|---|
| `title` | string | tytuł roboczy |
| `meme` | string | nazwa memu lub szablonu |
| `figure` | string | postać lub postacie |
| `when` | string | data i miejsce, tekst |
| `year` | number | rok do sortowania, p.n.e. jako liczba ujemna |
| `yearLabel` | string | rok do wyświetlenia („75 p.n.e.”, „1378–1417”) |
| `style` | string | styl graficzny epoki |
| `pl` | bool | wątek polski |
| `format` | `scenario` \| `template` | komiks ze scenariuszem albo znany szablon memu |
| `attach` | bool | prompt zakłada wgranie obrazu szablonu memu |
| `panels` | string[] | kadry po polsku (do czytania) |
| `caption` | string | opis do posta po polsku |
| `captionEn` | string? | opis do posta po angielsku (pokazywany po wybraniu EN) |
| `promptStyle` | string | pierwsza linia promptu: styl, format, technika |
| `shots` | Shot[] | sceny do promptu (po angielsku), patrz niżej |
| `prompt` | string? | gotowy prompt; używany tylko wtedy, gdy nie ma `shots` (pomysły z formularza) |
| `status` | `idea` \| `art` \| `posted` | Pomysł, Grafika, Opublikowane |
| `notes`, `postUrl`, `postedAt` | string | notatki, link do posta, data publikacji (RRRR-MM-DD) |
| `source`, `createdAt` | string | `claude` albo `user`; data utworzenia (ISO) |

Opcjonalne nadpisania promptu (dla stylów, które nie pasują do komiksu 1:1 z dymkami):

| Pole | Domyślnie | Przykład (1066) |
|---|---|---|
| `panelWord` | `Panel` | `Scene` |
| `bubbleWord` | `Speech bubble` | `Speech scroll` |
| `textLine` | linia o dymkach i czytelnym liternictwie | łacińskie napisy i zwoje zamiast dymków |
| `noTextLine` | linia o braku tekstu | pusty pas na napisy i puste zwoje |
| `formatLine` | `Square 1:1 format.` albo proporcje szablonu | `Wide 16:9 format.` |

## Shot i teksty

```json
{ "scene": "English scene description…",
  "texts": [
    { "k": "say",   "at": "Harold", "pl": "…", "en": "…" },
    { "k": "label", "at": "the left button", "pl": "…", "en": "…" },
    { "k": "sign",  "at": "the signpost", "pl": "…", "en": "…" },
    { "k": "cap",   "pl": "…", "en": "…" },
    { "k": "ins",   "la": "HIC HAROLD REX VICIT NORDMANNOS" }
  ] }
```

| `k` | Znaczenie | W wersji „bez tekstu” |
|---|---|---|
| `say` | kwestia postaci `at` (dymek albo zwój) | pusty dymek |
| `label` | podpis na elemencie `at` | pomijany |
| `sign` | napis na przedmiocie `at` (tablica, gazeta, karta) | „Leave … blank.” |
| `cap` | ramka z podpisem | pomijany |
| `ins` | napis z epoki (np. łaciński), taki sam w PL i EN | pomijany |

Prompt składa funkcja `buildPrompt(idea, lang)` w `kronika-memow.html`. `tools/prompt.js` wycina ją ze strony, więc obie wersje zawsze są zgodne.

## Aktualizacja
- Dane: `ArtifactData` z adresem strony (`set`, `update`, `batch` do 50 zapisów). Nie trzeba publikować strony.
- Kod strony: `Artifact` → `read` z adresem strony, potem publish tego pliku z parametrem `url`.
- Kopia w repo: `ArtifactData` → `list` kolekcji `ideas` z `out_dir` ustawionym na `data`, potem commit.
