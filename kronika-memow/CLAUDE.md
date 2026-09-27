# Kronika memów: zasady pracy

## Użytkownik
- Pisze po polsku; odpowiadaj po polsku.
- Na co dzień: SQL, Tableau, Holistics, Keboola (ETL), Claude Code, Cursor. Ma własny serwer i domenę, lubi majsterkować.
- Zainteresowania: historia, gry, gadżety, malowanie figurek. Wątki z tych dziedzin są mile widziane w pomysłach na memy.

## Zasady treści
- **Fakty muszą się zgadzać.** Poprawność historyczna to główny wyróżnik projektu. Sprawdzaj daty, cytaty i liczby. Tam, gdzie źródła się różnią, pisz „według tradycji” albo „podobno”.
- **Test pomysłu:** czy mem streszcza to, co postać naprawdę zrobiła? Jeśli nie, to tylko przebranie, a nie żart.
- **Styl grafiki = malarstwo epoki** (np. tkanina z Bayeux, fresk pompejański, iluminowany manuskrypt, Holbein, Matejko, Suchodolski).
- **Kwestie z memów** zostają po angielsku także w wersji polskiej, bo tak funkcjonują w polskim internecie.
- **Bez memów:** dyktatorzy XX wieku jako śmieszni bohaterowie, postacie religijne, tragedie, których świadkowie jeszcze żyją. W rocznice takich wydarzeń jak kapitulacja Warszawy (28 IX 1939) czy koniec Powstania Warszawskiego (2 X 1944) nie publikujemy memów o II wojnie.
- Grafiki AI zawsze oznaczamy w opisie posta.

## Zasady techniczne
- Kronika memów: https://claude.ai/artifact/3sgGXFEjGnAyaLecsyLHbb, kolekcja `ideas`. Schemat pomysłu: [kronika/README.md](kronika/README.md).
- Prompt budujemy zawsze przez `buildPrompt` (strona i `tools/prompt.js` używają tej samej funkcji). Nie kopiuj jej logiki do nowych miejsc, tylko importuj albo wycinaj ją z `kronika/kronika-memow.html`, jak robi `tools/prompt.js`.
- Lovable: zanim wywołasz `send_message`, `create_project` albo `remix_project` (kredyty) lub `deploy_project` (publiczna publikacja), zapytaj użytkownika. Projektów produkcyjnych nie ruszaj bez zgody. Szczegóły w [HANDOVER.md](HANDOVER.md).
- Nigdy nie proś o wklejenie kluczy ani haseł do czatu. Klucze trafiają do zmiennych środowiska (np. `GEMINI_API_KEY`).
- Sieć środowiska: `api.openai.com`, `docs.lovable.dev` i `mcp.directory` są zablokowane. `generativelanguage.googleapis.com` działa.
