# Watchpost

Native iPhone client for [tesla-sentry-f50](https://github.com/baicyber/tesla-sentry-f50), the
self-hosted Tesla Sentry and dashcam viewer. It talks only to the server you run yourself: you
type its address and the admin password, and Watchpost lists your events, plays them with the
driving telemetry, and exports watermarked clips to share.

简体中文说明见 [README.zh-Hans.md](README.zh-Hans.md).

## What it does

- **Connect** to your own server over `http://` or `https://`, port included. Addresses are
  saved on the device so you can switch between servers.
- **Events** grouped by day, with category, date and reason filters, and the server's storage
  summary.
- **Playback** of each one-minute clip, switching between the cameras the event recorded — front,
  rear, the two B-pillar cameras and the two fender cameras (a car with four cameras shows four):
  play and pause, jump ten seconds, a scrubber with the trigger marked, full screen. Speed, gear,
  brake, throttle, steering angle and turn signals follow the playhead. A value the recording does
  not contain is shown as “—”, never as a made-up zero.
- **Export and share**: one minute, one camera, with the watermark the server burns in, in the
  quality you pick. The finished file goes out through the system share sheet.
- **Demo mode** with sample footage drawn entirely from code. A “Demo data” badge stays on
  screen so sample events are never mistaken for real ones.

## Camera names

Watchpost names the side cameras by where they are mounted: the `*_pillar` files are the B-pillar
cameras and the `*_repeater` files are the fender cameras. The upstream web viewer (v2.8.45)
shows those two the other way round. Watchpost does not change the server; it only labels what it
is given by position.

## Requirements

- A tesla-sentry-f50 server of your own, with its address and admin password.
- To build: Xcode 26 or newer (built and tested with Xcode 27.1). The app runs on iOS 18.0 or
  later, on iPhone.

## Run it

Open `WatchpostApp.xcodeproj`, choose the `WatchpostApp` scheme and an iPhone simulator, and
press ⌘R. On the connect screen, choose **Try demo** to look around without a server.

From a terminal, with a simulator already booted:

```sh
xcodebuild -project WatchpostApp.xcodeproj -scheme WatchpostApp -sdk iphonesimulator \
  CONFIGURATION_BUILD_DIR="$PWD/build/Debug-iphonesimulator" build &&
xcrun simctl install booted build/Debug-iphonesimulator/WatchpostApp.app &&
xcrun simctl launch booted com.jakezai.watchpost-pwvw
```

Unit tests (they run against a loopback server inside the test process; no tesla-sentry-f50
server is needed):

```sh
xcodebuild -project WatchpostApp.xcodeproj -scheme WatchpostApp -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Tips

Tips are voluntary in-app purchases that unlock nothing. To try them without paying, select
`WatchpostAppTests/Tips.storekit` as the scheme's StoreKit Configuration (Product ▸ Scheme ▸ Edit
Scheme…, Run ▸ Options) and run: purchases then go through StoreKit Testing, and nothing is charged.
A tip bought that way is reported like any other, with StoreKit Testing's receipt. How the tip store
behaves is covered by the unit tests, which run it against that same file
(`WatchpostAppTests/StoreKitTipStoreTests.swift`): a tip bought on another device, a refund, Ask to
Buy, and a purchase the App Store could not verify. Nothing a test buys is reported.

## Privacy

- No account and no cloud service of its own. Besides the address you type, the app talks only to
  the developer's report service at `apps.air.build`: usage statistics you can switch off, crash
  reports, feedback you choose to send, and tip purchases. There is no advertising SDK.
- Usage statistics count which screens are opened and how often the app runs, under a random number
  made anew for each install. Never the server address, the password or the recordings. On by
  default; the switch is on the Servers page, and turning it off deletes at once what had not been
  sent yet, together with that number.
- A crash report carries the app version, device model, system version and language, and the crash
  text with addresses removed. Feedback includes
  what you typed, the pictures you picked, and the app version, device model, system version,
  language and region. It may also include a device proof identifier to verify that it came from
  this app. This identifier can link feedback and crash reports from the same app installation.
  A tip purchase is reported with Apple's receipt.
- The server address and password stay on the device: the password in the iOS Keychain, the rest
  in the app's own preferences.
- Plain `http://` is allowed because home servers are often reached that way on a local network.
  Reaching a server on your local network makes iOS ask for the Local Network permission.

## Project layout

| Path | What is in it |
| --- | --- |
| `WatchpostApp/Data` | Models, decoding of the server's replies, the server session, export and playback logic |
| `WatchpostApp/Views` | The three screens: connect, events, playback |
| `WatchpostApp/DemoAssets` | Sample footage, thumbnails and telemetry for the demo mode; the export samples and place names once per language |
| `WatchpostAppTests` | Unit tests, including a loopback server that answers like the real one |
| `Tools` | Strings, demo-media generator and a local server helper. See [Tools/README.md](Tools/README.md) |

UI text is written in English in the code and translated to Simplified Chinese in
`Tools/Strings/*.json`. After changing any user-facing text, run `python3 Tools/Strings/merge.py`
to regenerate the catalogs and audit the keys.

## License

MIT. See [LICENSE](LICENSE). tesla-sentry-f50 is a separate project by baicyber, also under MIT.

Watchpost is a hobby project and is not affiliated with Tesla, Inc. “Tesla” and “Tesla Sentry”
are trademarks of Tesla, Inc.
