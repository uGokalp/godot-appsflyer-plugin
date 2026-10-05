# Platform notes

Facts this plugin depends on, each verified against the named source. Add to this file when you verify something new; mark anything unverified as such.

## Godot 4.7.2

- **Plugin init timing.** `.gdip` `initialization` functions run from `register_ios_api()` inside `Main::setup`, which runs inside `GDTAppDelegateService application:didFinishLaunchingWithOptions:` — i.e. while `GDTApplicationDelegate` is enumerating its `services` array. Calling `+[GDTApplicationDelegate addService:]` from the init function mutates that array mid-enumeration. The bridge registers its service from a `__attribute__((constructor))`, which runs after every `+load` (the array is created in `GDTApplicationDelegate +load`) and before `main`. Source: `drivers/apple_embedded/godot_app_delegate.mm`, `app_delegate_service.mm`, `platform/ios/api/api.cpp`.
- **Scene lifecycle.** The template Info.plist has `UIApplicationSceneManifest`; `GDTApplicationDelegate` forwards `scene:willConnectToSession:options:`, `scene:continueUserActivity:`, `scene:openURLContexts:` and scene activity callbacks to services. In a scene app UIKit never calls `application:continueUserActivity:` / `application:openURL:`, and cold-launch links are not in `didFinishLaunching` options.
- **GDCLASS auto-registers** on first `memnew` (`initialize_class` in `core/object/object.h`); no `GDREGISTER_CLASS` needed.
- **ABI.** Templates build with `-std=gnu++17`, RTTI on, `-fno-exceptions`, defines `IOS_ENABLED APPLE_EMBEDDED_ENABLED UNIX_ENABLED THREADS_ENABLED`, plus `DEBUG_ENABLED` for template_debug and `NDEBUG` for template_release. Min iOS 14.0. The `.gdip` `binary` name resolves to `<name>.debug.xcframework` / `<name>.release.xcframework` per export type.
- **`.gdip` dependencies.** `linked=` xcframeworks are copied under `dylibs/` and linked (not embedded) onto the app target; `files=` are copied as resources (`lastKnownFileType = file`, directories included). No pbxproj patching needed. Source: `editor/export/editor_export_platform_apple_embedded.cpp` (`_copy_asset`, `_export_additional_assets`).
- **Plugin discovery** walks `res://ios/plugins` with `DirAccess` (skips only hidden entries), so a `.gdignore` in the plugin folder is safe. Without it the editor imports the SDK's `.swiftmodule/*.abi.json` as JSON resources and packs them into the `.pck`.
- **Export plugin API (4.7).** `add_apple_embedded_platform_plist_content`, `get_option(...)`, `_end_generate_apple_embedded_project(path, will_build_archive)`; no SPM API. The entitlements file is written to `<dir>/<name>/<name>.entitlements` before `_end_generate_apple_embedded_project`, and that hook only runs on macOS editors (`#ifdef MACOS_ENABLED`). Export requires `application/app_store_team_id` and an app icon.
- **Release export** sets `CODE_SIGN_IDENTITY = "Apple Distribution"`; device test archives need an `Apple Development` override.
- **Official simulator template is x86_64-only** (4.7.2); simulator builds need `ARCHS=x86_64`.
- **GDScript gotchas.** A `const` Dictionary containing `PackedStringArray()` is a parse error (silently disables an EditorPlugin). `OS.add_logger()` + `Logger._log_error` (error type `ERROR_TYPE_SCRIPT`) is how the test runner catches script errors. On iOS, `print` goes to os_log, not stdout.

## AppsFlyer SDK 7.0.2 (headers + binary)

- Start: `initWithDevKey:appleAppId:` once (before any other SDK call), set `delegate` / `deepLinkDelegate` (both **weak** — keep the object alive), `handleLaunchOptions:` (cold link) before `registerSessionReadyListener:`, call `start` inside the listener. The listener is dispatched on main and documented as "once per foreground cycle", **but on device it also fires again when the app returns to active after the ATT sheet** (no background) — the gate allows one start per foreground and resets only on background.
- Apple app id is passed without `id`; the SDK adds the prefix itself (`app_id=id…` in requests).
- Selectors: `customerUserID` property, `getAppsFlyerUID`, `isDebug:` setter, `disableSKAdNetwork`, `oneLinkCustomDomains` (branded hosts; `*.onelink.me` not needed), `continueUserActivity:restorationHandler:`, `handleOpenUrl:options:`, `logEventWithEventName:eventValues:completionHandler:`.
- `handleLaunchOptions:` reads only `UIApplicationLaunchOptionsUserActivityDictionaryKey` / `UIApplicationLaunchOptionsUserActivityTypeKey` (checked with `strings` on the static binary). The bridge rebuilds that dictionary from the scene's cold `NSUserActivity` and also forwards it via `continueUserActivity:` (non-scene iOS delivers it through both). Verified on device: cold link registers before `Start`, one start, `deep_link_received` found.
- Deferred deep links are resolved by the SDK's own DDL request at launch, independently of `start` (so `deep_link_received` can precede the ATT answer); verified `is_deferred: true` on a fresh install.
- `onConversionDataSuccess` still fires on SDK 7 and repeats on each foreground with the cached install data.
- A brand-new AppsFlyer app in "Pending" state can answer the first conversion-data request with "App ID is incorrect"; it succeeds once the install is recorded.
- Distribution: CocoaPods zip `AppsFlyerLib-Binaries.zip` (sha256 pinned in `fetch_appsflyer_sdk.sh`); `binaries/xcframework/full` is static; trimmed to iOS slices (6.6 MB vs 21 MB). The framework's own `PrivacyInfo.xcprivacy` is not bundled for static frameworks, hence `AppsFlyerLib_Privacy.bundle`.

## iOS / Apple

- ATT: the sheet only shows when the app is active; requesting from inside the did-become-active notification, or alongside another permission prompt, can return `notDetermined` without showing. The gate treats `notDetermined` as "retry once on next activation", then proceeds without IDFA (never withholds the session forever). Missing `NSUserTrackingUsageDescription` crashes the app, so native refuses to prompt without it.
- Universal Links need the OneLink template's Universal Links configured with Team ID + bundle ID (AppsFlyer then serves `/.well-known/apple-app-site-association`). Apple's CDN (`app-site-association.cdn-apple.com`) can cache an empty file for hours; for development use `applinks:<host>?mode=developer` plus Settings → Developer → Associated Domains Development. Production builds use the plain entitlement.
- Universal Links arrive as `NSUserActivity` (browsing-web), never as URL contexts; URL contexts are custom schemes.
- Device logs: `xcrun devicectl ... --console` misses os_log; use `pymobiledevice3 syslog live --udid <udid>` and filter `Demo{Demo}` (process{image}).
