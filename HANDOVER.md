# Handover: grafika i wideo z Claude Code

Data: 2026-10-02. Notatka przekazania do nowej sesji. Nie jest częścią projektu Wokyintosh (repo służy tu tylko jako katalog roboczy). Nic nie zostało zbudowane ani zacommitowane.

## Cel użytkownika
Znaleźć "poligon" / zestaw narzędzi, dzięki któremu Claude Code pomaga w generowaniu grafik i filmów. Użytkownik koduje głównie w SQL, używa Tableau, Holistics, Keboola, Cursora i Claude Code, ma własny serwer i domenę, buduje strony i aplikacje na własny użytek. Zainteresowania: gadżety, gry, historia, malowanie miniatur.

## Ustalenia z rozmowy
- Claude Code sam nie generuje pikseli. Pisze kod, który renderuje grafikę lub wideo, i może zweryfikować wynik (zrzut ekranu przez Playwright, w sesjach chmurowych Chromium jest preinstalowany).
- Modele AI do obrazów i wideo przez API są płatne (rozliczane za obraz lub sekundę wideo). Modele otwarte (Stable Diffusion, SDXL, Flux, Wan, LTX-Video) są darmowe lokalnie, ale wymagają GPU.
- **Ograniczenie sprzętowe:** serwer użytkownika jest słaby, a Mac mini też ma być ciężki do tego celu. Nie znamy modelu Maca mini ani ilości RAM-u (pytanie zostało bez odpowiedzi). Obrazy SDXL/Flux na Apple Silicon z 16 GB+ RAM są możliwe (Draw Things, ComfyUI/MLX), ale wolne. Wideo AI lokalnie odpada.

## Rekomendowane podejście (hybrydowe)
1. **Lokalnie, bez GPU:** Remotion (wideo z komponentów React), Manim, SVG/Canvas/p5.js/Three.js, matplotlib/Plotly/D3, ffmpeg, ImageMagick/Pillow. Pętla: kod, render, zrzut ekranu, ocena, poprawka.
2. **Obrazy AI w chmurze:** fal.ai lub Replicate z modelem Flux/SDXL, płatność za obraz (grosze). Podpiąć skryptem albo serwerem MCP, żeby Claude Code wołał generowanie sam. Sugerowany budżet startowy: 5–10 USD, żeby sprawdzić realne koszty.
3. **Wideo AI:** używać oszczędnie (fal.ai, Runway, Kling, Veo). Najpierw sprawdzić, czy Remotion + ffmpeg wystarczy.
4. Alternatywa abonamentowa: Midjourney, ChatGPT/OpenAI Images, Ideogram.

## Proponowany następny krok (nie rozpoczęty)
Przygotować w repozytorium minimalny szablon:
- projekt Remotion z jedną przykładową kompozycją i komendą renderu do MP4,
- skrypt do fal.ai (klucz z zmiennej środowiskowej `FAL_KEY`, nie w repo) generujący obraz z promptu,
- krótki README z komendami.

## Do ustalenia z użytkownikiem
- Model i RAM Maca mini (czy w ogóle próbować lokalnych obrazów).
- Czy preferuje API (fal.ai/Replicate), czy abonament.
- Do czego ma służyć: infografiki/wykresy pod Tableau i Holistics, ilustracje do stron, tematyka hobby (historia, gry, miniatury), czy krótkie filmy.
- Gdzie umieścić szablon: nowe repo czy ten katalog.

## Uwagi środowiskowe
- Konektor Keboola był niezalogowany/rozłączony pod koniec sesji i niezwiązany z tym tematem.
- Plik `HANDOVER.md` jest nieśledzony przez git. Usuń go lub zacommituj według uznania.
