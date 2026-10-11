# tab-notify

Claude Code plugin for **Windows**: a soft chime when Claude finishes, and your terminal (tab) comes to you — but only if you haven't already seen it.

## What it does

| When Claude finishes and… | What happens |
|---|---|
| You're in that session's tab and were active in the last 60 s | Nothing — you've seen it |
| You're in that tab but idle (AFK) | Chime after 3 min, unless you do something first |
| You're in **another tab** of Windows Terminal | Chime + the tab gets a 🔔 in its title and a blinking ring. On your next **Enter** in the terminal it switches to that tab; if you click over yourself, the mark disappears |
| You're in another app | Chime + the terminal comes to the front on the right tab |
| Something is running fullscreen (game, video, F11) | Chime + tab mark, your focus is never stolen |

Tab detection and marking work in **Windows Terminal**. In other terminals (conhost, VS Code) you get the chime and the window brought to the front.

## Install

Type this in Claude Code (in a terminal):

```
/plugin install tab-notify --marketplace joonsv/claude-tab-notify
```

Answer `y` to add the marketplace, then pick a scope (user = all your projects). Restart your Claude sessions afterwards.

From a local folder (without GitHub):

```
claude plugin marketplace add C:\path\to\claude-tab-notify
claude plugin install tab-notify@tab-notify
```

## Customize

- **Sound:** tweak `sounds/make_chime.py` (pitch, volume, tempo) and run `python sounds/make_chime.py`, or replace `sounds/done.wav` with your own wav.
- **Timings:** `$SEEN_IDLE_SEC` (60) and `$FALLBACK_SEC` (180) at the top of `scripts/notify-done.ps1`.

## Troubleshooting

Every decision is logged to `%USERPROFILE%\.claude\tab-notify\notify.log` with its reason (`tab not in front`, `unmarked: enter`, `skip: ... seen`, ...).
