extends VBoxContainer

const ATT_TIMEOUT_SEC := 60.0

@onready var _output: RichTextLabel = $Output


func _ready() -> void:
	_fit_safe_area()
	AppsFlyer.conversion_data_received.connect(func(data: Dictionary) -> void: _log("conversion_data_received %s" % data))
	AppsFlyer.conversion_data_failed.connect(func(error: String) -> void: _log("conversion_data_failed %s" % error))
	AppsFlyer.deep_link_received.connect(func(result: Dictionary) -> void: _log("deep_link_received %s" % result))
	AppsFlyer.att_status_received.connect(func(status: int) -> void: _log("att_status_received %d" % status))
	AppsFlyer.event_logged.connect(func(event_name: String, success: bool, code: int) -> void: _log("event_logged %s %s %d" % [event_name, success, code]))
	$LogEvent.pressed.connect(func() -> void: AppsFlyer.log_event("af_login"))

	AppsFlyer.set_debug(OS.is_debug_build())
	AppsFlyer.init()
	AppsFlyer.request_tracking_authorization(ATT_TIMEOUT_SEC)
	AppsFlyer.start()
	_log("platform=%s att_status=%d appsflyer_id=%s" % [OS.get_name(), AppsFlyer.get_att_status(), AppsFlyer.get_appsflyer_id()])


func _log(line: String) -> void:
	print("AppsFlyerDemo: ", line)
	_output.append_text(line + "\n")


func _fit_safe_area() -> void:
	var screen := Vector2(DisplayServer.screen_get_size())
	var safe := Rect2(DisplayServer.get_display_safe_area())
	var scale := get_viewport_rect().size / screen
	offset_top = safe.position.y * scale.y
	offset_bottom = -(screen.y - safe.end.y) * scale.y
