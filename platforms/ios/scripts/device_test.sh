#!/bin/bash
# Automated pass over the README device plan. Builds, exports and signs the demo up front, waits for
# the iPhone on USB, then installs it and runs the scenarios that need no taps (a fresh ATT prompt
# needs one). Writes report.md and redacted logs to the run directory; exits 1 if a check fails.
#
# Config: DEV_KEY from ~/.appsflyer-godot.env; TEAM_ID, BUNDLE_ID, APPLE_APP_ID, ONELINK_DOMAINS
# (comma-separated), ONELINK_TEST_URL, DEVICE_UDID from $APPSFLYER_DEVICE_ENV (.agents/device.env).
# APPSFLYER_DEVICE_ANY_TRANSPORT=1 also accepts a Wi-Fi connection. APPSFLYER_DEVICE_REINSTALL=0 keeps the
# installed app (and its ATT answer) so the run needs no taps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$HOME/.appsflyer-godot.env"
source "${APPSFLYER_DEVICE_ENV:-$ROOT/.agents/device.env}"
: "${DEV_KEY:?}" "${TEAM_ID:?}" "${BUNDLE_ID:?}" "${APPLE_APP_ID:?}" "${DEVICE_UDID:?}" "${ONELINK_DOMAINS:=}" "${ONELINK_TEST_URL:=}"
export DEV_KEY APPLE_APP_ID ONELINK_DOMAINS

RUN="${APPSFLYER_DEVICE_RUN_DIR:-$ROOT/.agents/device-runs/$(date +%Y%m%d-%H%M%S)}"
STAGE="$RUN/project"
OUT="$RUN/export"
DD="$RUN/derived"
LOGS="$RUN/logs"
REPORT="$RUN/report.md"
APP="$DD/Build/Products/Debug-iphoneos/Demo.app"
mkdir -p "$LOGS"
trap 'rm -rf "$STAGE"' EXIT
FAILED=0

notify() {
	echo "== $1"
	osascript -e "display notification \"$1\" with title \"AppsFlyer device test\"" >/dev/null 2>&1 || true
}

record() {
	local verdict="$1" check="$2" detail="${3:-}"
	[ "$verdict" = FAIL ] && FAILED=1
	echo "| $verdict | $check | $detail |" >> "$REPORT"
	echo "$verdict  $check  $detail"
}

expect() {
	local check="$1" detail="$2"
	shift 2
	if "$@"; then record PASS "$check" "$detail"; else record FAIL "$check" "$detail"; fi
}

redact() { perl -pe 's/\Q$ENV{DEV_KEY}\E/<dev-key>/g'; }

count() { grep -c -E "$2" "$1" || true; }

printf '# Device run %s\n\n| Result | Check | Detail |\n| --- | --- | --- |\n' "$(date '+%Y-%m-%d %H:%M')" > "$REPORT"

notify "Building the bridge and exporting the demo"
"$ROOT/platforms/ios/scripts/build.sh" > "$LOGS/build.log" 2>&1
rsync -a --exclude .godot "$ROOT/platforms/godot_editor/" "$STAGE/"
python3 -I - "$STAGE/project.godot" <<'PY'
import os, sys
path = sys.argv[1]
text = open(path).read()
domains = ", ".join('"%s"' % d.strip() for d in os.environ["ONELINK_DOMAINS"].split(",") if d.strip())
for key, value in [
	("config/dev_key", '"%s"' % os.environ["DEV_KEY"]),
	("config/apple_app_id", '"%s"' % os.environ["APPLE_APP_ID"]),
	("config/onelink_domains", "PackedStringArray(%s)" % domains),
]:
	lines = [line for line in text.splitlines() if line.startswith(key + "=")]
	assert len(lines) == 1, key
	text = text.replace(lines[0], key + "=" + value)
open(path, "w").write(text)
PY
cat > "$STAGE/export_presets.cfg" <<EOF
[preset.0]

name="iOS"
platform="iOS"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""

[preset.0.options]

application/app_store_team_id="$TEAM_ID"
application/bundle_identifier="$BUNDLE_ID"
application/export_project_only=true
plugins/AppsFlyerGodotPlugin=true
EOF
mkdir -p "$OUT"
godot --headless --path "$STAGE" --import > "$LOGS/godot-import.log" 2>&1 || true
godot --headless --path "$STAGE" --export-debug "iOS" "$OUT/Demo.xcodeproj" 2>&1 | redact > "$LOGS/godot-export.log"
[ -d "$OUT/Demo.xcodeproj" ] || { cat "$LOGS/godot-export.log"; exit 1; }

PLIST="$OUT/Demo/Demo-Info.plist"
ENTITLEMENTS="$OUT/Demo/Demo.entitlements"
plist_value() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true; }
expect "Info.plist NSUserTrackingUsageDescription" "$(plist_value NSUserTrackingUsageDescription)" test -n "$(plist_value NSUserTrackingUsageDescription)"
expect "Info.plist NSAdvertisingAttributionReportEndpoint" "$(plist_value NSAdvertisingAttributionReportEndpoint)" test "$(plist_value NSAdvertisingAttributionReportEndpoint)" = "https://appsflyer-skadnetwork.com/"
expect "Info.plist AdAttributionKit.AttributionCopyEndpoint" "$(plist_value AdAttributionKit.AttributionCopyEndpoint)" test "$(plist_value AdAttributionKit.AttributionCopyEndpoint)" = "https://appsflyer-skadnetwork.com/"
for domain in ${ONELINK_DOMAINS//,/ }; do
	expect "Entitlements applinks:$domain" "" grep -q "applinks:$domain</string>" "$ENTITLEMENTS"
	# Developer mode makes the phone fetch the AASA file directly instead of Apple's CDN cache.
	sed -i '' "s|applinks:$domain</string>|applinks:$domain?mode=developer</string>|" "$ENTITLEMENTS"
done

notify "Signing the demo with Xcode"
(cd "$OUT" && xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug -sdk iphoneos \
	-destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic build) > "$LOGS/xcodebuild.log" 2>&1 \
	|| { tail -30 "$LOGS/xcodebuild.log"; exit 1; }
PRIVACY_PLIST="$(find "$APP" -path '*AppsFlyerLib_Privacy.bundle/Info.plist' -print -quit)"
expect "App bundles AppsFlyerLib_Privacy.bundle with Info.plist" "${PRIVACY_PLIST#"$APP/"}" test -n "$PRIVACY_PLIST"

device_state() {
	xcrun devicectl list devices --json-output "$RUN/devices.json" >/dev/null 2>&1 || return 0
	python3 -I - "$RUN/devices.json" "$DEVICE_UDID" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
	if device.get("hardwareProperties", {}).get("udid") == sys.argv[2]:
		print(device["connectionProperties"].get("transportType", ""), device["identifier"])
PY
}

notify "Ready. Plug in the iPhone and unlock it"
while true; do
	read -r TRANSPORT CORE_ID <<< "$(device_state)" || true
	if [ "${TRANSPORT:-}" = wired ] || { [ -n "${TRANSPORT:-}" ] && [ "${APPSFLYER_DEVICE_ANY_TRANSPORT:-0}" = 1 ]; }; then
		break
	fi
	sleep 5
done
notify "iPhone connected ($TRANSPORT). Keep it unlocked"

launch() {
	local _
	for _ in $(seq 1 36); do
		if xcrun devicectl device process launch --device "$CORE_ID" "$@" > "$LOGS/launch.out" 2>&1; then
			return 0
		fi
		grep -qi -E 'locked|passcode' "$LOGS/launch.out" && notify "Unlock the iPhone to continue"
		sleep 5
	done
	cat "$LOGS/launch.out"
	return 1
}

SYSLOG_PID=""
begin_phase() {
	PHASE_RAW="$LOGS/$1.raw"
	PHASE_LOG="$LOGS/$1.log"
	pymobiledevice3 syslog live --udid "$DEVICE_UDID" > "$PHASE_RAW" 2>/dev/null &
	SYSLOG_PID=$!
	sleep 4
}

end_phase() {
	kill "$SYSLOG_PID" 2>/dev/null || true
	wait "$SYSLOG_PID" 2>/dev/null || true
	# SDK request bodies are multi-line messages; keep their continuation lines with the Demo line.
	awk '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / { keep = index($0, "Demo{Demo}") > 0 } keep' "$PHASE_RAW" | redact > "$PHASE_LOG" || true
	rm -f "$PHASE_RAW"
}

wait_for() {
	local pattern="$1" deadline=$((SECONDS + $2))
	until grep -F 'Demo{Demo}' "$PHASE_RAW" 2>/dev/null | grep -q -E "$pattern"; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 2
	done
}

sdk_lines() { grep -v 'AppsFlyerDemo:' "$PHASE_LOG" || true; }

if [ "${APPSFLYER_DEVICE_REINSTALL:-1}" = 1 ]; then
	xcrun devicectl device uninstall app --device "$CORE_ID" "$BUNDLE_ID" > /dev/null 2>&1 || true
fi
xcrun devicectl device install app --device "$CORE_ID" "$APP" > "$LOGS/install.log" 2>&1 || { cat "$LOGS/install.log"; exit 1; }

begin_phase 1-fresh-install
launch --terminate-existing "$BUNDLE_ID"
wait_for 'AppsFlyerDemo: scenario=' 60 || true
if grep -F 'Demo{Demo}' "$PHASE_RAW" | grep -q 'att_status=0'; then
	notify "Tap Allow on the tracking prompt"
	wait_for 'att_status_received' 120 || true
fi
wait_for 'sample events sent' 90 || true
wait_for 'event_logged af_login' 30 || true
sleep 15
end_phase
expect "Fresh install: demo started" "$(grep -o 'scenario=.*' "$PHASE_LOG" | head -1)" grep -q 'AppsFlyerDemo: scenario=' "$PHASE_LOG"
expect "Fresh install: exactly one session start" "$(count "$PHASE_LOG" '\] Start$') starts" test "$(count "$PHASE_LOG" '\] Start$')" -eq 1
expect "Fresh install: ATT answered or already determined" "$(grep -o -E 'att_status(_received|=)[ ]?[0-9]' "$PHASE_LOG" | tr '\n' ' ')" grep -q -E 'att_status_received [1-3]|att_status=[1-3]' "$PHASE_LOG"
expect "Fresh install: conversion data received" "$(grep -o 'af_status[^,]*' "$PHASE_LOG" | head -1)" grep -q 'conversion_data_received' "$PHASE_LOG"
expect "Fresh install: af_login event acknowledged" "$(grep -o 'event_logged af_login.*' "$PHASE_LOG" | head -1)" grep -q 'event_logged af_login true 0' "$PHASE_LOG"
expect "Launch: SDK sent consent data" "$(sdk_lines | grep -c -i -E 'consent|gdpr' || true) SDK lines" sh -c "grep -v 'AppsFlyerDemo:' '$PHASE_LOG' | grep -q -i -E 'consent|gdpr'"
expect "Launch: SDK sent ad revenue" "$(sdk_lines | grep -c -i -E 'monetization_network|ad_?revenue' || true) SDK lines" sh -c "grep -v 'AppsFlyerDemo:' '$PHASE_LOG' | grep -q -i -E 'monetization_network|ad_?revenue'"

begin_phase 2-background-foreground
launch com.apple.Preferences
sleep 6
launch "$BUNDLE_ID"
sleep 20
end_phase
expect "Background then foreground: exactly one new session start" "$(count "$PHASE_LOG" '\] Start$') starts" test "$(count "$PHASE_LOG" '\] Start$')" -eq 1

if [ -n "$ONELINK_TEST_URL" ]; then
	begin_phase 3-warm-link
	launch --payload-url "$ONELINK_TEST_URL" "$BUNDLE_ID"
	wait_for 'deep_link_received' 30 || true
	sleep 5
	end_phase
	# devicectl opens the URL as a URL context rather than a Universal Link activity, so this is informational.
	record INFO "Warm OneLink via devicectl --payload-url" "$(grep -o 'deep_link_received.*' "$PHASE_LOG" | head -1 | cut -c1-160)"
fi

begin_phase 4-stopped
launch --terminate-existing --environment-variables '{"APPSFLYER_DEMO_SCENARIO":"stopped"}' "$BUNDLE_ID"
wait_for 'AppsFlyerDemo: scenario=stopped' 60 || true
wait_for 'sample events sent' 60 || true
sleep 15
end_phase
expect "Stopped: demo reports is_stopped" "" grep -q 'scenario=stopped.*stopped=true' "$PHASE_LOG"
# The bridge still calls start; the SDK must refuse to send it. Numbered operations are launch and event requests.
expect "Stopped: SDK refuses requests" "$(count "$PHASE_LOG" 'isStopTracking') refusals" grep -q 'isStopTracking. request not sent' "$PHASE_LOG"
expect "Stopped: no launch or event request" "$(count "$PHASE_LOG" 'Operation start: .[0-9]') requests" test "$(count "$PHASE_LOG" 'Operation start: .[0-9]')" -eq 0
expect "Stopped: no ad revenue sent" "" sh -c "! grep -v 'AppsFlyerDemo:' '$PHASE_LOG' | grep -q -i -E 'monetization_network|ad_?revenue'"

launch --terminate-existing "$BUNDLE_ID" || true

cat >> "$REPORT" <<EOF

Still manual (README device plan): ATT deny and timeout on a fresh ATT state (2), background before answering (3), cold and deferred links tapped from Notes (6, 8), branded domain (7), suppressed ATT overlap (9), dashboard checks for events and ad revenue (10, 12).

Logs: $LOGS
EOF
notify "Device run finished: $([ "$FAILED" = 0 ] && echo all checks passed || echo some checks failed)"
echo "Report: $REPORT"
exit "$FAILED"
