# OmaKani

A [WaniKani](https://www.wanikani.com/) cockpit for the [Omarchy](https://omarchy.org/) bar.

A quiet Crabigator-head mark sits in the bar and takes the accent colour when
reviews (or lessons) are waiting. Click it for a dashboard drop-down that
mirrors the website: the Lessons / Reviews counts with Start buttons, an
Upcoming Reviews forecast you can drill into hour by hour, Level Progress, Item
Spread, Critical Condition, recent unlocks and burns, and the Extra Study
counts.

Click Lessons or Reviews (or hit Enter on the dashboard) and the whole flow
runs in-shell: the learn-walk for new lessons, meaning/reading quizzing for
both, item info with the same mnemonics/context sentences/radical
illustrations the website shows, a kana chart for typing readings without a
Japanese IME, pronunciation audio, and a running log of what you've answered
this session. Browsing — a level's full item list, or any single subject — works
the same way standalone, outside a review. Extra Study (recent lessons, recent
mistakes, burned items) quizzes without touching SRS. Every screen is
keyboard-first; press `?` in the app for the current hotkeys.

Desktop notifications for reviews piling up, new lessons, level-ups and burns.

Not affiliated with, sponsored by, or endorsed by WaniKani or Tofugu LLC.

## Install

Review the source, then:

```bash
omarchy plugin add https://github.com/aphelion-studios/omakani.git
```

Accept the prompt to enable the plugin. It needs `python3` (standard library
only), `libnotify` (`notify-send`) for notifications, `xdg-open` for links, and
`mpv` for pronunciation audio.

## Connecting your account

Click the mark, paste a **WaniKani API token**, press Connect.

Generate one at **wanikani.com → Settings → API Tokens**. A read-only token
unlocks the dashboard and browsing; doing lessons and reviews needs a token
with the **`assignments:start`** and **`reviews:create`** permissions checked
too — otherwise you'll get a clear in-app error the first time you try to
submit one, telling you to make a new token with those boxes checked. It is
stored in `~/.config/omarchy/wanikani.json` with `0600` permissions and is
passed to the helper over stdin, never on a command line.

## Remove

```bash
omarchy plugin remove io.github.aphelion-studios.omakani
```

Your token is left behind deliberately; delete it yourself with:

```bash
rm -f ~/.config/omarchy/wanikani.json
```

## Keyboard

The dashboard is fully keyboard-driven. Mouse hover and the keyboard share one
cursor — resting the mouse over it while you use only the keyboard doesn't
fight you for control.

| Key | Effect |
| --- | --- |
| `j` / `k` (or `↓` / `↑`) | Move the cursor down / up — through the days, the Extra Study rows, the item chips, the footer |
| `h` / `l` (or `←` / `→`) | Move sideways on a chip row or the footer; on a day, `l` opens its hour breakdown and `h` goes back |
| `Enter` / `Space` | Open — drill into a day, launch an Extra Study session, open an item's page, hit a footer button |
| `g` / `G` (double-tap `g`, vim-style) | Jump to the first / last item |
| `r` | Refresh |
| `Esc` | Back out of a day's breakdown or the settings sheet, or close the panel |
| `Tab` / `Shift+Tab` | Next / previous bar panel |

The gear in the footer opens a settings sheet (the two mark toggles and the four
notification controls). Everything there is keyboard-driven too. To bind a key
straight to it, add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + K", "OmaKani", "omarchy-shell -q io.github.aphelion-studios.omakani toggle")
```

The main window — lessons, reviews, browsing, item info, the kana chart — is
its own keyboard-first surface with a larger hotkey set (vim-style `j`/`k`/`gg`/`G`
navigation, `f` for item info, audio playback, folding, and more). Press `?`
anywhere in it for the current list rather than relying on this README to stay
in sync.

IPC methods on `io.github.aphelion-studios.omakani`: `toggle`, `open`,
`close`, `refresh`, `settings`.

## Settings

The dashboard's gear icon and the main window's own settings sheet share one
schema, so they never drift.

### Dashboard

| Setting | Default | Effect |
| --- | --- | --- |
| Refresh interval | 60 s | How often the counts re-read from WaniKani. The dashboard sync runs on a longer cadence. |
| Light the mark for lessons too | on | Accent the mark for waiting lessons, not only reviews. |
| Hide the mark when nothing is due | off | Hide a connected, caught-up widget. It always shows while no token is stored. |
| Notify at N reviews | 25 | Notify once your review count climbs past this. 0 turns it off. |
| Notify when new lessons unlock | on | |
| Notify on level-up | on | |
| Notify when items burn | on | |

### Lessons, reviews, audio

Opened from the main window's own gear icon.

| Setting | Default | Effect |
| --- | --- | --- |
| Preferred lesson batch size | 5 | New lessons to learn before each lesson quiz. |
| Maximum daily lessons | 15 | Cap on new lessons per day (0 = no cap). |
| Interleave lesson item types | on | Mix radicals / kanji / vocabulary rather than grouping by type. |
| SRS change indicator during reviews | on | Show the "you moved to Guru" chip as each item finishes. |
| Review ordering | Shuffled | Shuffled, Apprentice first, lower SRS stages first, or lower levels first. |
| Pronunciation voice | Random | Which voice actor's audio plays for vocabulary. |
| Autoplay audio in lessons / reviews / extra study | off | Play a vocabulary word's audio automatically rather than only on request. |

Notifications follow Do Not Disturb, stay quiet on vacation, and are silent
until the plugin has taken its first reading (so a shell restart never dumps a
backlog on you).

## Radical illustrations (optional)

WaniKani draws a small picture for many radicals — the "bat wing extended to
your right…" illustration shown under the mnemonic. These are **not in the API**
and are **not shipped with this plugin**. If you want them in the subject
pages, fetch your account's set once:

```bash
./wanikani.py radical-images
```

It walks each radical's page on `wanikani.com` one at a time with a short delay
and saves the illustrations into `~/.cache/omakani/radical_mnemonics/`
(a few MB). Safe to re-run — it only fills gaps — so run it again after you
level up. Radicals WaniKani hasn't illustrated just show their character, as
before. The plugin reads this cache and shows nothing until you've run the
command; the images stay local and are never redistributed.

## What it does on your system

- **Runs `wanikani.py`** (Python standard library, no dependencies) in the
  background while the shell is up — a light `summary` poll on the short
  interval, a heavier `dashboard` sync (which caches subjects, assignments and
  review statistics under `~/.cache/omakani/`) on a longer one.
- **Reads and writes** `~/.config/omarchy/wanikani.json` (`0600`) — just your API
  token — and the cache directory above.
- **Reaches** `api.wanikani.com` over HTTPS. No telemetry. The only other
  network access is when you run `radical-images` yourself, which fetches from
  `wanikani.com` / `files.wanikani.com`.
- **Runs `notify-send`** for the events you've enabled, `xdg-open` for external
  links, and `mpv` to play pronunciation audio.

## From a terminal

```bash
./wanikani.py summary | jq
./wanikani.py dashboard | jq
./wanikani.py radical-images          # one-time: fetch radical illustrations
printf '%s\n' "$TOKEN" | ./wanikani.py set-token
./wanikani.py clear-token
```

## License

MIT — see [LICENSE](LICENSE).

The code is MIT. WaniKani's content is not: subject data, mnemonics,
pronunciation audio and radical illustrations belong to Tofugu LLC and are
accessed through your own subscription, cached locally, and never redistributed
by this plugin. `icon.svg` is an original drawing made for this plugin.
`wordmark.svg` is WaniKani's own "WaniKani" lockup, used to identify the
service. WaniKani and the Crabigator are trademarks of Tofugu LLC.
