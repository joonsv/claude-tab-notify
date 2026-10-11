# tab-notify

Claude Code plugin for **Windows**: a soft chime when Claude finishes, and your terminal (tab) comes to you — but only if you haven't already seen it.

## What it does

| When Claude finishes and… | What happens |
|---|---|
| You're in that session's tab and were active in the last 60 s | Nothing — you've seen it |
| You're in that tab but idle (AFK) | Waits up to 3 min: any input in that tab (or a new prompt) cancels it, otherwise a chime |
| You're in **another tab** of Windows Terminal | Chime + the finished tab gets a 🔔 in its title and a blinking ring (see below for when it switches) |
| You're in another app | Chime + the terminal comes to the front on the finished tab (after a short pause in your typing, so no keystrokes land in the wrong place) |
| Something is running fullscreen (game, video, F11) | Chime + tab mark only — your focus is never stolen |

### When a marked tab switches

While a tab is marked, it switches to it when:

- **you press Enter** anywhere in the terminal (e.g. sending a prompt in the tab you're on) — Shift/Ctrl/Alt+Enter don't count;
- **the tab you're on is a Claude session that is still working** (spinner in its title) and:
  - you haven't touched anything for **10 s** — you're just waiting on it, or
  - you typed there without pressing Enter and then stopped for **30 s** — time to think before it moves you.

If you click over to the marked tab yourself, the mark simply disappears. With several finished tabs waiting, each Enter / trigger switches to only one of them.

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
- **Timings:** `$SEEN_IDLE_SEC` (60), `$TYPE_QUIET_SEC` (10), `$TYPING_PAUSE_SEC` (30) and `$FALLBACK_SEC` (180) at the top of `scripts/notify-done.ps1`.

## Troubleshooting

Every decision is logged to `%USERPROFILE%\.claude\tab-notify\notify.log` with its reason (`tab not in front`, `unmarked: enter`, `skip: ... seen`, ...).
