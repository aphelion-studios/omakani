# OmaWaniKani

A [WaniKani](https://www.wanikani.com/) cockpit for the [Omarchy](https://omarchy.org/) bar.

A quiet alligator-head mark sits in the bar and takes the accent colour when
reviews (or lessons) are waiting. Click it for a dashboard drop-down that
mirrors the website: reviews and lessons due, an Upcoming Reviews forecast you
can drill into hour by hour, Level Progress, Item Spread, Critical Condition,
recent unlocks and burns, and the Extra Study counts. Fully keyboard-driven.

Desktop notifications for reviews piling up, new lessons, level-ups and burns.

> **Status: read-only.** The dashboard and notifications are done. Doing lessons
> and reviews *inside* the shell is still to come. See the
> [build plan](https://claude.ai/code/artifact/683e07bc-d1e2-4bc6-8bc9-2afac661ad7d).

Not affiliated with, sponsored by, or endorsed by WaniKani or Tofugu LLC.

## Install

Review the source, then:

```bash
omarchy plugin add https://github.com/aphelion-studios/omawanikani.git
```

Accept the prompt to enable the plugin. It needs `python3` (standard library
only), `libnotify` (`notify-send`) for notifications, and `xdg-open` for the
links.

## Connecting your account

Click the mark, paste a **WaniKani API token**, press Connect.

Generate one at **wanikani.com → Settings → API Tokens**. A read-only token is
all the dashboard needs. It is stored in `~/.config/omarchy/wanikani.json` with
`0600` permissions and is passed to the helper over stdin, never on a command
line.

## Remove

```bash
omarchy plugin remove io.github.aphelion-studios.omawanikani
```

Your token is left behind deliberately; delete it yourself with:

```bash
rm -f ~/.config/omarchy/wanikani.json
```

## Keyboard

The dashboard is fully keyboard-driven. Mouse hover and the keyboard share one
cursor.

| Key | Effect |
| --- | --- |
| `j` / `k` (or `↓` / `↑`) | Move the cursor down / up — through the days, the Extra Study rows, the item chips, the footer |
| `h` / `l` (or `←` / `→`) | Move sideways on a chip row or the footer; on a day, `l` opens its hour breakdown and `h` goes back |
| `Enter` / `Space` | Open — drill into a day, launch an Extra Study session, open an item's page, hit a footer button |
| `g` / `G` | Jump to the first / last item |
| `r` | Refresh |
| `Esc` | Back out of a day's breakdown or the settings sheet, or close the panel |
| `Tab` / `Shift+Tab` | Next / previous bar panel |

The gear in the footer opens a settings sheet (the two mark toggles and the four
notification controls). Everything there is keyboard-driven too. To bind a key
straight to it, add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + K", "OmaWaniKani", "omarchy-shell -q io.github.aphelion-studios.omawanikani toggle")
```

IPC methods on `io.github.aphelion-studios.omawanikani`: `toggle`, `open`,
`close`, `refresh`, `settings`.

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| Refresh interval | 60 s | How often the counts re-read from WaniKani. The dashboard sync runs on a longer cadence. |
| Light the mark for lessons too | on | Accent the mark for waiting lessons, not only reviews. |
| Hide the mark when nothing is due | off | Hide a connected, caught-up widget. It always shows while no token is stored. |
| Notify at N reviews | 25 | Notify once your review count climbs past this. 0 turns it off. |
| Notify when new lessons unlock | on | |
| Notify on level-up | on | |
| Notify when items burn | on | |

Notifications follow Do Not Disturb, stay quiet on vacation, and are silent
until the plugin has taken its first reading (so a shell restart never dumps a
backlog on you).

## What it does on your system

- **Runs `wanikani.py`** (Python standard library, no dependencies) in the
  background while the shell is up — a light `summary` poll on the short
  interval, a heavier `dashboard` sync (which caches subjects, assignments and
  review statistics under `~/.cache/omawanikani/`) on a longer one.
- **Reads and writes** `~/.config/omarchy/wanikani.json` (`0600`) — just your API
  token — and the cache directory above.
- **Reaches** `api.wanikani.com` over HTTPS. No other network access, no
  telemetry.
- **Runs `notify-send`** for the events you've enabled.
- **Never writes to your WaniKani account.** It is read-only.

## From a terminal

```bash
./wanikani.py summary | jq
./wanikani.py dashboard | jq
printf '%s\n' "$TOKEN" | ./wanikani.py set-token
./wanikani.py clear-token
```

## License

MIT — see [LICENSE](LICENSE).
