# OmaWaniKani

A [WaniKani](https://www.wanikani.com/) cockpit for the [Omarchy](https://omarchy.org/) bar.

A quiet Crabigator mark sits in the bar and takes the accent colour when reviews
(or lessons) are waiting. Click it for a dashboard drop-down: how many reviews
and lessons are due now, the next-review countdown, a 24-hour forecast, and
which level you're on.

> **Status: early.** This is phase 1 of a larger plan — the read-only dashboard.
> Doing lessons and reviews inside the shell, the Extra Study modes, and desktop
> notifications are still to come. See the
> [build plan](https://claude.ai/code/artifact/683e07bc-d1e2-4bc6-8bc9-2afac661ad7d).

Not affiliated with, sponsored by, or endorsed by WaniKani or Tofugu LLC.

## Install

Review the source, then:

```bash
omarchy plugin add https://github.com/aphelion-studios/omawanikani.git
```

Accept the prompt to enable the plugin. It needs `python3` (standard library
only) and `xdg-open` for the "open wanikani.com" button.

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

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| Refresh interval | 60 s | How often the counts re-read from WaniKani (two requests each; the API allows 60/min). |
| Light the mark for lessons too | on | Accent the mark for waiting lessons, not only reviews. |
| Hide the mark when nothing is due | off | Hide a connected, caught-up widget. It always shows while no token is stored. |

## What it does on your system

- **Runs `wanikani.py`** (Python standard library, no dependencies) on a timer
  while the bar is up — one `GET /user` and one `GET /summary` per refresh.
- **Reads and writes** `~/.config/omarchy/wanikani.json` (`0600`) — just your API
  token.
- **Reaches** `api.wanikani.com` over HTTPS. No other network access, no
  telemetry.
- **Never writes to your WaniKani account.** This phase is read-only.

## From a terminal

```bash
./wanikani.py summary | jq
printf '%s\n' "$TOKEN" | ./wanikani.py set-token
./wanikani.py clear-token
```

## License

MIT — see [LICENSE](LICENSE).
