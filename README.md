# tab-notify

Claude Code-plugin voor **Windows**: een zachte chime als Claude klaar is, en je terminal(tab) komt naar je toe — maar alleen als je het nog niet gezien hebt.

## Wat het doet

| Situatie als Claude klaar is | Wat er gebeurt |
|---|---|
| Je zit in de tab van die sessie en was de laatste 60 sec actief | Niks — je hebt het gezien |
| Je zit in die tab maar bent idle (AFK) | Chime na 3 min, tenzij je eerder iets doet |
| Je zit in een **andere tab** van Windows Terminal | Chime + tab krijgt 🔔 in de titel en een knipperende ring. Bij je volgende **Enter** in de terminal wisselt hij naar die tab; klik je er zelf heen, dan verdwijnt de markering |
| Je zit in een ander programma | Chime + terminal naar voren op de juiste tab |
| Er draait iets fullscreen (game, video, F11) | Chime + markering, je focus wordt niet gestolen |

Tab-detectie/markering werkt in **Windows Terminal**. In andere terminals (conhost, VS Code) krijg je de chime en het venster naar voren.

## Installeren

Typ in Claude Code (terminal):

```
/plugin install tab-notify --marketplace joonsv/claude-tab-notify
```

Kies `y` om de marketplace toe te voegen en daarna een scope (user = voor al je projecten). Herstart daarna je Claude-sessies.

Lokaal vanaf een map (zonder GitHub):

```
claude plugin marketplace add C:\pad\naar\claude-tab-notify
claude plugin install tab-notify@tab-notify
```

## Aanpassen

- **Geluid:** pas `sounds/make_chime.py` aan (toonhoogte, volume, tempo) en draai `python sounds/make_chime.py`, of vervang `sounds/done.wav` door je eigen wav.
- **Tijden:** `$SEEN_IDLE_SEC` (60) en `$FALLBACK_SEC` (180) bovenin `scripts/notify-done.ps1`.

## Problemen

Elke beslissing komt in `%USERPROFILE%\.claude\tab-notify\notify.log`, met reden (`tab not in front`, `unmarked: enter`, `skip: ... seen`, ...).
