extends VBoxContainer

const ATT_TIMEOUT_SEC := 60.0
const SAMPLE_EVENTS_DELAY_SEC := 5.0
const LATE_ATT_DELAY_SEC := 5.0
## Set by platforms/ios/scripts/device_test.sh: "" (default), "stopped", or "late_att" (start
## first, then ask for tracking).
const SCENARIO_ENV := "APPSFLYER_DEMO_SCENARIO"
const ATT_TIMEOUT_ENV := "APPSFLYER_DEMO_ATT_TIMEOUT"

@onready var _output: RichTextLabel = $Output


func _ready() -> void:
	_fit_safe_area()
	AppsFlyer.conversion_data_received.connect(func(data: Dictionary) -> void: _log("conversion_data_received %s" % data))
	AppsFlyer.conversion_data_failed.connect(func(error: String) -> void: _log("conversion_data_failed %s" % error))
	AppsFlyer.deep_link_received.connect(func(result: Dictionary) -> void: _log("deep_link_received %s" % result))
	AppsFlyer.att_status_received.connect(func(status: int) -> void: _log("att_status_received %d" % status))
	AppsFlyer.event_logged.connect(func(event_name: String, success: bool, code: int) -> void: _log("event_logged %s %s %d" % [event_name, success, code]))
	$LogEvent.pressed.connect(_log_sample_events)

	var scenario := OS.get_environment(SCENARIO_ENV)
	AppsFlyer.set_debug(OS.is_debug_build())
	AppsFlyer.set_consent(true, true, true, true)
	AppsFlyer.set_stopped(scenario == "stopped")
	AppsFlyer.init()
	var att_timeout := float(OS.get_environment(ATT_TIMEOUT_ENV)) if OS.has_environment(ATT_TIMEOUT_ENV) else ATT_TIMEOUT_SEC
	if scenario != "late_att":
		AppsFlyer.request_tracking_authorization(att_timeout)
	AppsFlyer.start()
	_log("scenario=%s platform=%s att_status=%d att_timeout=%s stopped=%s appsflyer_id=%s" % [scenario, OS.get_name(), AppsFlyer.get_att_status(), att_timeout, AppsFlyer.is_stopped(), AppsFlyer.get_appsflyer_id()])

	if scenario == "late_att":
		await get_tree().create_timer(LATE_ATT_DELAY_SEC).timeout
		_log("att requested after start")
		AppsFlyer.request_tracking_authorization(att_timeout)
	if AppsFlyer.get_att_status() == 0:
		await AppsFlyer.att_status_received
	await get_tree().create_timer(SAMPLE_EVENTS_DELAY_SEC).timeout
	_log_sample_events()


func _log_sample_events() -> void:
	AppsFlyer.log_event("af_login")
	AppsFlyer.log_ad_revenue("applovin", AppsFlyer.MediationNetwork.APPLOVIN_MAX, "USD", 0.0021, {"ad_type": "rewarded", "country": "US"})
	_log("sample events sent: af_login, ad revenue applovin 0.0021 USD")


func _log(line: String) -> void:
	print("AppsFlyerDemo: ", line)
	_output.append_text(line + "\n")


func _fit_safe_area() -> void:
	var screen := Vector2(DisplayServer.screen_get_size())
	var safe := Rect2(DisplayServer.get_display_safe_area())
	var scale := get_viewport_rect().size / screen
	offset_top = safe.position.y * scale.y
	offset_bottom = -(screen.y - safe.end.y) * scale.y
