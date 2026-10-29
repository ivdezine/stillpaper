# Stillpaper

A small native Mac app that shows a web page as your desktop background, without paying for the
page's animations all day.

## Why

A web page as wallpaper costs whatever the page costs to draw, forever. A dashboard with spinning
rings, glows and moving SVG parts redraws the desktop about 60 times a second, even while you are
not looking at it. Stillpaper was written to replace Plash for one such page, where Plash's web
process sat near half a core all day and had reached 845 MB.

It changes how the page is drawn instead of just hosting it. Measured on that page (2026-10-20, an
Intel Mac with 16 GB, macOS 12):

| Mode | What it does | CPU |
| --- | --- | --- |
| Motion on | The page as it is | 53% of a core |
| **Live, motion off** (default) | The page runs and updates, all animation frozen: CSS animations and transitions off, every SVG paused, including ones the page draws later | **7%** |
| Snapshot | Every N minutes it loads the page, waits 12 seconds for its data, captures a still, and shuts the web process down | about 1% at the default 5 minutes, about 5% at 1 minute. No web process exists between refreshes |

On an Apple silicon Mac with a much simpler test page (one spinning ring and one moving SVG dot),
motion on measured 4.6% of a core and motion off 0.1%.

In every mode the page is torn down while the screen is locked, asleep, or switched to another
user, leaving its last frame on screen, and comes back on return. A live page also reloads every
six hours so its memory never creeps.

## Requirements

- macOS 12 or later, on Apple silicon or Intel.
- The Swift compiler from Xcode or the Command Line Tools (`xcode-select --install`).

No Xcode project, no dependencies.

## Build and install

```
git clone https://github.com/ivdezine/stillpaper.git
cd stillpaper
bash build.sh --install     # -> ~/Applications/Stillpaper.app
open ~/Applications/Stillpaper.app
```

Without `--install` the app lands in `build/` (ignored by git). The build targets the Mac it runs on;
set `ARCH=x86_64` or `ARCH=arm64` to build for the other one. It stamps the release identity,
`Version 1.0.0 · build <commit count> (<short commit>)`, shown at the top of the app's menu. A build
from uncommitted changes carries `-dirty` after the commit. A build from a source download, such
as a release's Source code archive, has no history to count, so it reads build 0 with the commit
it was cut from.

The app is signed ad hoc on your own Mac, so a build from source opens without a Gatekeeper prompt.

## First run

1. If another app already draws a web page as your wallpaper, quit it first, or both will draw.
2. Stillpaper adds a picture frame icon to the menu bar and asks for a page address. Any `http://`
   or `https://` address works, a local one too (`http://localhost:8080/`). Until a page is set the
   desktop is plain near-black with a short hint, and nothing is loaded.
3. If the page is behind a login, choose **Sign in…** from the menu, sign in in the window that
   opens, then close it: the wallpaper reloads signed in. The app keeps its own cookies, separate
   from Safari's. For a page behind Cloudflare Access the menu's status line says "Sign-in needed"
   whenever the page lands on the Access login instead. Any other login wall works through
   Sign in… too, though the menu cannot tell you when it is needed.
4. Tick **Open at login** in the same menu to start it with the Mac.

Desktop icons stay on top of the page, and clicks pass through it to the desktop.

## Menu

- **Reload now**: rebuilds the wallpaper windows and reloads the page.
- **Mode**: Live or Snapshot. **Snapshot every**: 1, 5, 15, 30 or 60 minutes.
- **Motion**: turns the page's animations back on, at the page's full cost.
- **Show on all displays**: off by default, because each display runs its own web process.
- **Sign in…**: opens the page in a normal window, for pages behind a login.
- **Page address…**: the page shown as the wallpaper.
- **Open at login**: writes `~/Library/LaunchAgents/com.ivdezine.stillpaper.plist` and loads it
  into launchd, or unloads and removes it. Unticking from the copy launchd started leaves the job
  to lapse at logout rather than unloading it, because unloading would quit the app.

## Settings

Settings live in the app's defaults domain, `com.ivdezine.stillpaper`:

| Key | Values | Default |
| --- | --- | --- |
| `url` | the page address | none |
| `mode` | `live` or `snapshot` | `live` |
| `motion` | `YES` or `NO` | `NO` |
| `allDisplays` | `YES` or `NO` | `NO` |
| `snapshotMinutes` | minutes between snapshots | `5` |

The menu sets all of them. Any of them can also be overridden for a single run on the command
line, without saving anything, which is how to try a page or measure a mode:

```
~/Applications/Stillpaper.app/Contents/MacOS/Stillpaper -url http://localhost:8080/ -mode snapshot
```

## Check it is working

- The desktop shows the page, with desktop icons still on top, and clicks pass through to the
  desktop.
- The menu's status line reads `Live, motion off`, or `Snapshot every 5 min, last HH:mm`.
- In Activity Monitor the app itself sits near 0%. In live mode one `com.apple.WebKit.WebContent`
  process carries the page; in snapshot mode it exists only for about 15 seconds per refresh.

## Remove it

- **Pause**: Quit from the menu. Nothing keeps running.
- **Stop it starting at login**: untick Open at login. It unloads and removes the launch agent.
- **Uninstall**: quit it, untick Open at login, then delete `~/Applications/Stillpaper.app`.
  Besides its settings (`defaults delete com.ivdezine.stillpaper`), the app's web data lives in
  `~/Library/WebKit/com.ivdezine.stillpaper`, `~/Library/Caches/com.ivdezine.stillpaper` and, once
  a page sets cookies, `~/Library/HTTPStorages/com.ivdezine.stillpaper.binarycookies`. It touches
  nothing else.

## Tests

```
node --test stillpaper.test.mjs
```

Needs Node 20 or later and nothing installed. Checks that no page address is built into the app,
that nothing loads until a page is chosen and a first run asks for one, that the motion freeze
covers both CSS and SVG animation, and that Open at login loads what it writes. It checks that
`build.sh` is executable, and that the build targets the Mac it runs on and pins the macOS 12
minimum, then compiles the real app three times into temp folders: an Intel build, checked for
its architecture and minimum; a native build whose stamped identity it checks; and a build from
a `git archive` export of the current commit, run as `./build.sh` the way a release download
would be, which must still name that commit. The build tests skip where `swiftc` is missing.

## License

MIT, see [LICENSE](LICENSE).
