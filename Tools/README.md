# Tools

Developer tools for Watchpost. Nothing here ships in the app; the app reads only the generated
catalogs and the files in `WatchpostApp/DemoAssets/`.

| Folder | What it does | When to run it |
| --- | --- | --- |
| `Strings/` | UI copy: English keys and their Simplified Chinese, merged into the string catalogs | after adding or changing any user-facing text |
| `MakeDemoMedia/` | Draws the offline demo's footage, thumbnails and telemetry from code | only when the demo scenes change |
| `LiveServer/` | Runs the upstream server on this Mac with synthetic events | to check the app against the real protocol |

All commands run from the project root: `Tools/<folder>/…`, or `python3 Tools/Strings/merge.py`.

## Strings

`Tools/Strings/*.json`, one file per screen area plus `InfoPlist.json`, each a flat
`{ "<English key exactly as written in code>": "<zh-Hans>" }` map. The two catalogs are generated
from them and must never be edited by hand:

- `python3 Tools/Strings/merge.py` writes `WatchpostApp/Localizable.xcstrings` and
  `WatchpostApp/InfoPlist.xcstrings`, then audits.
- `python3 Tools/Strings/merge.py --check` audits only (exit 1 on a missing key).
- `python3 Tools/Strings/merge.py --list` prints every key the Swift sources use with its Chinese.

Audit rules: every user-facing literal in `WatchpostApp/**/*.swift` has a zh-Hans value; a key is
never written in Chinese (CJK in Swift is an error unless the literal only matches server text);
an interpolated `Text("… \(x) …")` resolves to a key with `%@` / `%lld`; format specifiers match
between key and value. "unused" lines are keys in the tables that no code uses any more: delete them.

Keep the English keys as Camo's copy (copy v3) writes them; a new key needs its Chinese in the
same change. See `Strings/README.md` for details.

## MakeDemoMedia

`swift Tools/MakeDemoMedia/make-demo-media.swift <output-directory>` renders the demo clips
(six cameras, parked and driving sets), thumbnails, `demo-telemetry.json` and the watermarked
export samples into the directory given. To refresh the app's demo footage, run it with
`WatchpostApp/DemoAssets` as the output directory and check the diff of the `.json` file.
`--still <out.png> <parked|drive> <camera> <seconds>` renders one frame for looking at a moment.
Everything is drawn from code: no real car, place, face or plate.

## LiveServer

`Tools/LiveServer/run.sh start|status|stop` runs the upstream `sentry-viewer.py` (read-only
checkout in `.airbuild/worktree/upstream`) at `http://127.0.0.1:18080` with synthetic events built
from the demo footage under Tesla's file names. User `admin`, password in `LiveServer/password.txt`
(a fixed throwaway for this local server). Everything it writes goes to `/tmp/wp-live`.
Always `stop` it when the check is done. The app connects to `http://127.0.0.1:18080` from the
simulator; this needs the Local Network permission, so that permission's failure path can be
checked here too.
