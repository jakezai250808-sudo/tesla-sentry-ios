# Strings

One JSON file per screen area, flat `{ "<English key as in code>": "<zh-Hans>" }`, merged by
`merge.py` into `WatchpostApp/Localizable.xcstrings` (and `InfoPlist.json` into
`WatchpostApp/InfoPlist.xcstrings`). The app never reads this folder.

- `core.json` — shared and frozen-layer keys (camera names, reasons, categories, common actions).
- `connect.json`, `events.json`, `playback.json` — one per screen area.
- `support.json` — feedback, tips and the usage-statistics switch.
- `InfoPlist.json` — the home-screen name and the Local Network usage text.

Rules:
- The key is the English text exactly as it stands in Swift, including leading/trailing spaces.
- An interpolated string is stored with `%@` (objects, strings) or `%lld` (Int) in place of the
  value; the Chinese value must use the same specifiers (order may differ; `%1$@` is fine).
- No Chinese in Swift. Never edit the `.xcstrings` files by hand.
- After editing: `python3 Tools/Strings/merge.py`, and read the "unused" lines. The app ships the
  `.xcstrings` on disk, not these tables: `python3 Tools/Strings/merge.py --check` fails when one is
  out of date, so run it before committing.
