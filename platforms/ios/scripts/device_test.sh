#!/bin/bash
# Device pass over the README device plan. Builds, exports and signs the demo up front, waits for
# the iPhone on USB, then runs one of two modes and writes report.md and redacted logs to the run
# directory; exits 1 if a check fails.
#   device_test.sh [auto]   scenarios that need no taps (a fresh ATT prompt needs one)
#   device_test.sh guided   ATT deny, ATT timeout, ATT after start with a background cycle, cold and
#                           deferred OneLinks; macOS notifications say when to tap. Put
#                           $ONELINK_TEST_URL in a note on the phone first.
# iOS keeps an ATT answer per bundle id across reinstalls, so each guided ATT phase signs the demo
# under a fresh bundle id ($BUNDLE_ID.att<run>.<n>, created by automatic signing; uninstalled after).
#
# Config: DEV_KEY from ~/.appsflyer-godot.env; TEAM_ID, BUNDLE_ID, APPLE_APP_ID, ONELINK_DOMAINS
# (comma-separated), ONELINK_TEST_URL, DEVICE_UDID from $APPSFLYER_DEVICE_ENV (.agents/device.env).
# APPSFLYER_DEVICE_ANY_TRANSPORT=1 also accepts a Wi-Fi connection. APPSFLYER_DEVICE_REINSTALL=0 keeps the
# installed app (and its ATT answer) so the run needs no taps.
set -euo pipefail

MODE="${1:-auto}"
case "$MODE" in auto | guided) ;; *) echo "usage: $0 [auto|guided]" >&2; exit 2 ;; esac
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

printf '# Device run (%s) %s\n\n| Result | Check | Detail |\n| --- | --- | --- |\n' "$MODE" "$(date '+%Y-%m-%d %H:%M')" > "$REPORT"

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

sign_demo() {
	local bundle_id="$1" derived="$2"
	(cd "$OUT" && xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug -sdk iphoneos \
		-destination 'generic/platform=iOS' -derivedDataPath "$derived" -allowProvisioningUpdates \
		DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" build) \
		> "$LOGS/xcodebuild-$bundle_id.log" 2>&1 || { tail -30 "$LOGS/xcodebuild-$bundle_id.log"; exit 1; }
}

notify "Signing the demo with Xcode"
sign_demo "$BUNDLE_ID" "$DD"
ATT_BUNDLES=()
if [ "$MODE" = guided ]; then
	ATT_RUN="$(date +%m%d%H%M)"
	for n in 1 2 3; do
		ATT_BUNDLES+=("$BUNDLE_ID.att$ATT_RUN.$n")
		sign_demo "$BUNDLE_ID.att$ATT_RUN.$n" "$RUN/derived-att$n"
	done
fi
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
	# No grep -q downstream: it exits early, SIGPIPE fails the pipeline under pipefail, and the wait never ends.
	until grep -F 'Demo{Demo}' "$PHASE_RAW" 2>/dev/null | grep -E "$pattern" > /dev/null; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 2
	done
}

sdk_lines() { grep -v 'AppsFlyerDemo:' "$PHASE_LOG" || true; }

first_line() { grep -n -m1 -E "$1" "$PHASE_LOG" | cut -d: -f1; }

# Session starts before / after the first log line matching $1 (0 when it never appears).
starts_before() {
	local line
	line="$(first_line "$1")"
	if [ -z "$line" ]; then echo 0; else head -n "$line" "$PHASE_LOG" | grep -c -E '\] Start$' || true; fi
}

starts_after() {
	local line
	line="$(first_line "$1")"
	if [ -z "$line" ]; then echo 0; else tail -n +"$line" "$PHASE_LOG" | grep -c -E '\] Start$' || true; fi
}

uninstall_demo() { xcrun devicectl device uninstall app --device "$CORE_ID" "${1:-$BUNDLE_ID}" > /dev/null 2>&1 || true; }

install_demo() {
	xcrun devicectl device install app --device "$CORE_ID" "${1:-$APP}" > "$LOGS/install.log" 2>&1 || { cat "$LOGS/install.log"; exit 1; }
}

att_app() { echo "$RUN/derived-att$1/Build/Products/Debug-iphoneos/Demo.app"; }

terminate_demo() {
	local pid
	xcrun devicectl device info processes --device "$CORE_ID" --json-output "$RUN/processes.json" > /dev/null 2>&1 || return 0
	for pid in $(python3 -I - "$RUN/processes.json" <<'PY'
import json, sys
for process in json.load(open(sys.argv[1]))["result"]["runningProcesses"]:
	if process.get("executable", "").endswith("/Demo.app/Demo"):
		print(process["processIdentifier"])
PY
	); do
		xcrun devicectl device process terminate --device "$CORE_ID" --pid "$pid" > /dev/null 2>&1 || true
	done
}

run_auto() {
	if [ "${APPSFLYER_DEVICE_REINSTALL:-1}" = 1 ]; then
		uninstall_demo
	fi
	install_demo

	begin_phase 1-fresh-install
	launch --terminate-existing "$BUNDLE_ID"
	wait_for 'AppsFlyerDemo: scenario=' 60 || true
	if grep -F 'Demo{Demo}' "$PHASE_RAW" | grep 'att_status=0' > /dev/null; then
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
}

run_guided() {
	local deny_id="${ATT_BUNDLES[0]}" timeout_id="${ATT_BUNDLES[1]}" late_id="${ATT_BUNDLES[2]}"
	uninstall_demo
	begin_phase g1-deny
	install_demo "$(att_app 1)"
	launch --terminate-existing "$deny_id"
	wait_for 'AppsFlyerDemo: scenario=' 60 || true
	notify "Tap 'Ask App Not to Track'"
	wait_for 'att_status_received' 120 || true
	sleep 15
	end_phase
	expect "Deny: answer reported as denied" "$(grep -o 'att_status_received [0-9]' "$PHASE_LOG" | head -1)" grep -q 'att_status_received 2' "$PHASE_LOG"
	expect "Deny: no start before the answer" "$(starts_before 'att_status_received') starts" test "$(starts_before 'att_status_received')" -eq 0
	expect "Deny: exactly one start after the answer" "$(starts_after 'att_status_received') starts" test "$(starts_after 'att_status_received')" -eq 1
	expect "Deny: prompt was shown (fresh ATT state)" "" grep -q 'att_status=0' "$PHASE_LOG"
	uninstall_demo "$deny_id"

	begin_phase g2-timeout
	install_demo "$(att_app 2)"
	launch --terminate-existing --environment-variables '{"APPSFLYER_DEMO_ATT_TIMEOUT":"10"}' "$timeout_id"
	wait_for 'AppsFlyerDemo: scenario=' 60 || true
	notify "Leave the tracking prompt open. Don't tap yet"
	sleep 20
	notify "Now tap Allow"
	wait_for 'att_status_received' 120 || true
	sleep 10
	end_phase
	expect "Timeout: demo used a 10 s timeout" "" grep -q 'att_timeout=10' "$PHASE_LOG"
	expect "Timeout: one start before the answer" "$(starts_before 'att_status_received') starts" test "$(starts_before 'att_status_received')" -eq 1
	expect "Timeout: late answer still reported" "$(grep -o 'att_status_received [0-9]' "$PHASE_LOG" | head -1)" grep -q 'att_status_received 3' "$PHASE_LOG"
	expect "Timeout: no second start after the answer" "$(starts_after 'att_status_received') starts" test "$(starts_after 'att_status_received')" -eq 0
	uninstall_demo "$timeout_id"

	begin_phase g3a-late-att-background
	install_demo "$(att_app 3)"
	launch --terminate-existing --environment-variables '{"APPSFLYER_DEMO_SCENARIO":"late_att"}' "$late_id"
	wait_for 'att requested after start' 60 || true
	notify "Leave the tracking prompt open. The script backgrounds and reopens the demo"
	sleep 4
	launch com.apple.Preferences
	sleep 6
	launch "$late_id"
	sleep 12
	end_phase
	expect "Late ATT: session started before the request" "$(starts_before 'att requested after start') starts" test "$(starts_before 'att requested after start')" -eq 1
	expect "Late ATT: no new start after background/foreground while unanswered" "$(starts_after 'att requested after start') starts" test "$(starts_after 'att requested after start')" -eq 0
	begin_phase g3b-late-att-answer
	notify "Now tap Allow"
	wait_for 'att_status_received' 120 || true
	sleep 10
	end_phase
	expect "Late ATT: answer reported" "$(grep -o 'att_status_received [0-9]' "$PHASE_LOG" | head -1)" grep -q 'att_status_received 3' "$PHASE_LOG"
	expect "Late ATT: exactly one start after the answer" "$(starts_after 'att_status_received') starts" test "$(starts_after 'att_status_received')" -eq 1
	uninstall_demo "$late_id"

	# Installed but never launched: an ATT alert from a killed process stays on screen and blocks the tap.
	install_demo
	begin_phase g4-cold-link
	terminate_demo
	notify "In Notes, tap the OneLink. Allow tracking if asked"
	wait_for 'deep_link_received' 180 || true
	wait_for 'att_status_received' 60 || true
	sleep 10
	end_phase
	expect "Cold link: app was cold-launched" "" grep -q 'AppsFlyerDemo: scenario=' "$PHASE_LOG"
	expect "Cold link: found exactly once" "$(count "$PHASE_LOG" 'deep_link_received .*"status": "found"') found" test "$(count "$PHASE_LOG" 'deep_link_received .*"status": "found"')" -eq 1
	expect "Cold link: no not_found report" "" sh -c "! grep -q 'deep_link_received .*not_found' '$PHASE_LOG'"
	expect "Cold link: exactly one start" "$(count "$PHASE_LOG" '\] Start$') starts" test "$(count "$PHASE_LOG" '\] Start$')" -eq 1
	record INFO "Cold link: result" "$(grep -o 'deep_link_received.*' "$PHASE_LOG" | head -1 | cut -c1-160)"

	uninstall_demo
	notify "Demo deleted. Tap the OneLink in Notes now (App Store says unavailable: expected), then go back to Notes"
	sleep 45
	begin_phase g5-deferred
	install_demo
	launch --terminate-existing "$BUNDLE_ID"
	wait_for 'AppsFlyerDemo: scenario=' 60 || true
	if grep -F 'Demo{Demo}' "$PHASE_RAW" | grep 'att_status=0' > /dev/null; then
		notify "Tap Allow"
		wait_for 'att_status_received' 120 || true
	fi
	wait_for 'deep_link_received' 60 || true
	sleep 10
	end_phase
	expect "Deferred: deep link found and deferred" "$(grep -o 'deep_link_received.*' "$PHASE_LOG" | head -1 | cut -c1-120)" grep -q -E 'deep_link_received .*"status": "found".*"is_deferred": true' "$PHASE_LOG"
	record INFO "Deferred: conversion data" "$(grep -o '"af_status": "[^"]*"' "$PHASE_LOG" | head -1)"
}

if [ "$MODE" = guided ]; then run_guided; else run_auto; fi

cat >> "$REPORT" <<EOF

Still manual (README device plan): branded domain (7), suppressed ATT overlap (9), dashboard checks for events and ad revenue (10, 12). \`guided\` covers 1-3, 6 and 8.

Logs: $LOGS
EOF
notify "Device run finished: $([ "$FAILED" = 0 ] && echo all checks passed || echo some checks failed)"
echo "Report: $REPORT"
exit "$FAILED"
