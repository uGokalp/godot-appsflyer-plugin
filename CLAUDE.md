# godot-appsflyer-plugin

AppsFlyer iOS SDK 7 for Godot 4.7: a static `.gdip` bridge, an `AppsFlyer` autoload facade, and an iOS export plugin. Android is phase 2 (`platforms/android/README.md`). Purchases are deliberately out of scope (revenue goes through RevenueCat's server-side integration; the game sets `$appsflyerId` from `get_appsflyer_id()`).

Read before changing behavior:
- `README.md` — public API, settings, build, device test plan.
- `docs/platform-notes.md` — verified Godot 4.7 / AppsFlyer SDK 7 / iOS facts this code depends on. Update it when you verify something new.
- `.agents/memory.md` — local-only notes (gitignored; may not exist on other machines). Read it if present; add machine-specific or private details there, never in tracked files.

## Layout

| Path | What |
| --- | --- |
| `platforms/ios/src/AppsFlyerGodotPlugin.mm` | Native bridge: `GDCLASS` singleton `AppsFlyerGodotPlugin`, `GDTApplicationDelegate` service (links, background), SDK delegates, ATT, Variant⇄NSObject conversion |
| `platforms/ios/src/session_gate.h` | Pure C++ start/ATT coordinator (no Godot/ObjC). All session-start logic lives here so it can be host-tested |
| `platforms/ios/tests/session_gate_test.cpp` | Host unit tests for the gate (`platforms/ios/scripts/test.sh`) |
| `platforms/ios/AppsFlyerGodotPlugin.gdip` | Links `AppsFlyerLib.xcframework` onto the app target, copies the privacy bundle, system frameworks, `-ObjC` |
| `platforms/ios/scripts/` | `fetch_godot_headers.sh` (4.7.2), `fetch_appsflyer_sdk.sh` (7.0.2, sha256-pinned), `build.sh`, `test.sh` |
| `platforms/godot_editor/addons/appsflyer/` | `appsflyer.gd` (autoload facade), `appsflyer_plugin.gd` (EditorPlugin: settings + autoload + exporter), `ios_export_plugin.gd` (plist + entitlements) |
| `platforms/godot_editor/tests/` | Headless GDScript tests against a fake native object (`run.gd`) |
| `platforms/godot_editor/{main.gd,main.tscn,project.godot}` | Demo used for device verification |

Generated / gitignored: `platforms/ios/{include,bin,vendor}/`, `platforms/godot_editor/ios/plugins/` (build output), `.godot/`, `export_presets.cfg`, `.agents/`.

## Commands

```sh
platforms/ios/scripts/build.sh          # bridge debug+release xcframeworks → godot_editor/ios/plugins/appsflyer
platforms/ios/scripts/test.sh           # session gate host tests
godot --headless --path platforms/godot_editor -s res://tests/run.gd   # GDScript suite
rm -rf platforms/godot_editor/.godot    # after running Godot headless
```

Run all three after any change. Toolchain: Godot 4.7.2 (`godot` on PATH, export templates installed), Xcode 26, `scons` only for regenerating headers.

## How we work

- Engineering merit over documents: verify claims against the Godot 4.7.2 source, the SDK 7.0.2 headers/binary, or a device. Old research docs (`../godot-appflyer-plugin/DESIGN.md`) are hints, not spec.
- Small, fast, simple. No speculative features, no wrappers for things the SDK doesn't need. Self-documenting code; comment only a non-obvious *why*.
- Tests must catch real bugs: for every new test, mutate the code it covers and confirm it fails, then restore. No tautological tests.
- Session-start logic belongs in `session_gate.h` with a gate test, not in GDScript or ad-hoc native flags.
- Callbacks reach Godot on the main queue; never block the Godot thread.
- Never put the dev key or other secrets in tracked files or logs.
- Device behavior beats reviews: the double-start-after-ATT bug was found only on a phone. Re-run the device checks in `README.md` after touching lifecycle, ATT, or link handling.
- Commits only when asked; end messages with the Co-Authored-By trailer the session provides.
- Subagents (Opus/Sonnet/Haiku only, never Fable) for fan-out reviews and fix batches to keep the main context small.
