# Godot AppsFlyer plugin

AppsFlyer iOS SDK 7 for Godot 4.7. The plugin covers attribution, conversion data, unified deep linking, ATT and in-app events. It has three parts:

- a static `.gdip` bridge (`platforms/ios`)
- an `AppsFlyer` autoload, which is the only API game code uses
- an iOS export plugin that writes the plist keys and the Universal Links entitlement

The editor, desktop exports and Android all no-op. Android support is phase 2 (see `platforms/android/README.md`).

Purchases are out of scope. Revenue goes through RevenueCat's server-side AppsFlyer integration. After `start()`, copy `AppsFlyer.get_appsflyer_id()` onto the RevenueCat customer as `$appsflyerId`. Do not also log `af_purchase`, because that double-counts revenue.

## Pins

| Component | Version | Where |
| --- | --- | --- |
| Godot headers and templates | 4.7.2 | `platforms/ios/scripts/fetch_godot_headers.sh` (`GODOT_VERSION`) |
| AppsFlyerLib (static, non-strict) | 7.0.2, sha256-verified | `platforms/ios/scripts/fetch_appsflyer_sdk.sh` |
| Minimum iOS | 14.0 | matches the Godot 4.7 template |

Rebuild the bridge when the Godot patch version changes. The bridge is compiled against engine headers, and its debug and release builds must match the template ABI (`DEBUG_ENABLED` is defined only for the debug build).

## Build

```sh
platforms/ios/scripts/build.sh
```

The script needs Xcode, and it needs `scons` the first time (for the generated Godot headers). `platforms/ios/vendor/` is not checked in: the script runs `fetch_appsflyer_sdk.sh`, which downloads the pinned SDK and verifies its sha256, whenever it is missing. It writes the following files into `platforms/godot_editor/ios/plugins/appsflyer/`:

- `AppsFlyerGodotPlugin.gdip`
- `AppsFlyerGodotPlugin.{debug,release}.xcframework`, which is the bridge only (about 0.5 MB)
- `AppsFlyerLib.xcframework`, with iOS device and simulator slices only (6.6 MB, down from 21 MB)
- `AppsFlyerLib_Privacy.bundle`, the SDK's `PrivacyInfo.xcprivacy`
- `.gdignore`, which stops the editor from importing the SDK's `.json` files into the `.pck`

The `.gdip` links `AppsFlyerLib` onto the app target, copies the privacy bundle into the app, and names the system frameworks. No project patching is needed for linking.

To use the plugin in a game, copy `addons/appsflyer/` and `ios/plugins/appsflyer/` into the project. Enable the AppsFlyer editor plugin, which registers the `AppsFlyer` autoload. Then tick **AppsFlyerGodotPlugin** under Export → iOS → Plugins. The facade binds during construction, so earlier autoloads can initialize it from `_ready()`.

## Configure

Project settings under `appsflyer/config/`:

| Setting | Purpose |
| --- | --- |
| `dev_key` | AppsFlyer dev key. Used when `init()` gets no argument. |
| `apple_app_id` | Numeric App Store id. An `id` prefix is stripped. |
| `att_usage_description` | Written as `NSUserTrackingUsageDescription`. If it is empty, the key is not written and `request_tracking_authorization()` refuses to prompt instead of crashing. If the preset's `application/additional_plist_content` already has the key, the preset wins and the export warns. The same applies to `SKAdNetworkItems`. |
| `onelink_domains` | OneLink hosts. `go.example.com`, `https://go.example.com/path` and `applinks:go.example.com` are all accepted. They are added as `applinks:` associated domains to the exported `.entitlements`. If the preset's `entitlements/additional` already defines associated domains, this setting is ignored with a warning. Godot runs the entitlements hook only in macOS editors; on other hosts the export prints the block to paste into `entitlements/additional`. URL paths, queries, fragments and ports are removed. Branded hosts (anything not ending in `onelink.me`) are also passed to the SDK as `oneLinkCustomDomains` by `init()`. |
| `skadnetwork_ids` | Optional `SKAdNetworkItems`. Empty by default. Copy the list from the AppsFlyer dashboard and do not guess it. |

## Use

```gdscript
func _ready() -> void:
	AppsFlyer.conversion_data_received.connect(_on_conversion_data)
	AppsFlyer.deep_link_received.connect(_on_deep_link)

	AppsFlyer.set_debug(OS.is_debug_build())
	AppsFlyer.set_customer_user_id(user_id)          # optional, before start()
	AppsFlyer.init()                                 # project settings, or init(dev_key, apple_app_id)
	AppsFlyer.request_tracking_authorization(60.0)   # optional; start() waits for the answer or 60 s
	AppsFlyer.start()
```

| Method | Notes |
| --- | --- |
| `init(dev_key := "", apple_app_id := "")` | Calls `initWithDevKey:appleAppId:`, sets `oneLinkCustomDomains`, and installs the delegates and the session-ready listener. It does not start a session. |
| `start()` | Lets the session start. The native side calls the SDK's `start` once per foreground cycle when the SDK reports ready and no ATT answer is pending. |
| `request_tracking_authorization(timeout_sec := 0.0) -> bool` | Shows the ATT prompt and returns `false` if it cannot (no usage description, or off iOS). Until the answer arrives, or the timeout when one is given, no session starts, including sessions after a background/foreground cycle. The prompt is deferred until the app is active, one main-queue turn after activation. If iOS answers "not determined" (the prompt was suppressed), it is retried once on the next activation or after one second if already active. If still inactive after one second, or if the retry is also suppressed, the gate stops waiting for consent. A visible retry prompt still waits for the answer or the caller’s timeout. |
| `get_att_status() -> int` | Reads the status without prompting. Returns `-1` off iOS. |
| `set_customer_user_id(id)`, `set_debug(enabled)`, `disable_skan(disabled)` | These may be called before `init()`. The values are applied when the SDK is initialized. |
| `log_event(name, params := {})` | Params keep their types. Use a float for `af_revenue`. |
| `get_appsflyer_id() -> String` | Returns `""` until `init()`. |

| Signal | Arguments |
| --- | --- |
| `conversion_data_received` | `Dictionary`, passed through as-is (`af_status`, `media_source`, `campaign`, …). It fires on every foreground, so the game decides whether to ignore repeats. |
| `conversion_data_failed` | `String` |
| `deep_link_received` | `Dictionary` with `status` (`found` / `not_found` / `failure`), `deeplink_value`, `is_deferred`, `click_event` and, on failure, `error` |
| `att_status_received` | `int`: 1 restricted, 2 denied, 3 authorized. A suppressed prompt ("not determined") is not reported. |
| `event_logged` | `event_name: String`, `success: bool`, `error_code: int` |

If a consent SDK shows ATT, do not call `request_tracking_authorization()`. Call `start()` once your consent flow finishes, and read the result with `get_att_status()`.

## How links reach the SDK

Godot 4.7 owns `UIApplicationDelegate` and uses the scene lifecycle. The bridge registers a `GDTApplicationDelegate` service before `main()` runs, using a static constructor. It cannot register from the `.gdip` initializer, because Godot calls plugin initializers while it enumerates its service list. Cold-start activities and URLs from `scene:willConnectToSession:options:`, and warm ones from `scene:continueUserActivity:` and `scene:openURLContexts:`, are buffered until `init()`. They are then forwarded to `continueUserActivity:` and `handleOpenUrl:options:` before the session-ready listener is registered.

With the scene lifecycle, the launch options never contain a cold-start Universal Link. The bridge rebuilds the `UIApplicationLaunchOptionsUserActivityDictionaryKey` entry that UIKit gives non-scene apps from the scene's web-browsing activity and passes it to `handleLaunchOptions:`, so session readiness waits for the link to resolve. The activity is also forwarded to `continueUserActivity:`, which matches the non-scene path, where UIKit delivers a cold link through both.

The start gate lives in `platforms/ios/src/session_gate.h`, a plain C++ struct with no Godot or UIKit dependencies. It tracks whether `start()` was called, whether the SDK reported the current session ready, and whether an ATT answer is pending. Each ATT request has a generation number, so a timeout left over from an earlier request cannot release a later one.

## Test

```sh
godot --headless --path platforms/godot_editor -s res://tests/run.gd
```

The headless suite runs the facade against a fake native object. It covers the settings fallback and validation, OneLink host normalization and filtering, signal relays and the no-plugin defaults. It also checks that the plist and entitlements output parses as XML, lands in the root `<dict>`, and does not duplicate keys the preset already sets.

```sh
platforms/ios/scripts/test.sh
```

This compiles and runs the start-gate unit test on the host with `clang++`. It covers start with and without ATT, timeouts, stale timeouts, the single retry of a suppressed prompt, its bounded activation wait and stale callbacks, once-per-foreground starts, background resets, and an ATT request made after a session already started.

Each test was checked by mutating the code under test and confirming that the test fails.

The native bridge is checked by exporting the demo and building it with Xcode. The official 4.7.2 simulator template is x86_64-only, so simulator builds need `ARCHS=x86_64`.

### Device test plan

Run these on a real device with a debug build, `set_debug(true)`, and the AppsFlyer dashboard's test device registered.

1. Fresh install, ATT prompt: `att_status_received` fires with the answer, then the SDK log shows one launch. Deny once and allow once on separate installs.
2. ATT timeout: leave the prompt open past the timeout. The session starts after the timeout, and the later answer is still reported.
3. Background before answering: request ATT after a session has started, background and foreground before answering. No new launch is sent until the answer.
4. Conversion data: an install from a OneLink test link reports `af_status` `Non-organic` with the campaign. An organic install reports `Organic`.
5. Warm OneLink: tap a link with the app in the background. `deep_link_received` reports `found` with the `deeplink_value`.
6. Cold OneLink: kill the app, then tap a link. The scene lifecycle delivers the link through `scene:willConnectToSession:options:`. The bridge passes it to `handleLaunchOptions:` and `continueUserActivity:` before the listener is registered. `deep_link_received` reports `found` once, and the SDK log shows the launch sent after the link resolved.
7. Branded domain: repeat 5 and 6 with a link on a custom OneLink domain.
8. Deferred deep link: install from a link, then launch. `deep_link_received` reports `is_deferred` true.
9. Suppressed ATT with zero timeout: overlap another permission request with ATT, and keep the app active. Confirm the retry occurs without needing another background/foreground cycle; one launch follows its answer (or its suppression). Repeat with the app inactive through the one-second retry deadline, then foreground: measurement must resume.
10. Events: `log_event` emits `event_logged` with `success` true, and the event shows in the dashboard.
