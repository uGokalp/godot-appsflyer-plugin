## AppsFlyer facade, registered as the `AppsFlyer` autoload. Only iOS has a native
## implementation; every other platform (and the editor) gets harmless defaults.
extends Node

signal conversion_data_received(data: Dictionary)
signal conversion_data_failed(error: String)
## Keys: `status` ("found", "not_found", "failure"), `deeplink_value`, `is_deferred`,
## `click_event`, and `error` on failure.
signal deep_link_received(result: Dictionary)
## 0 not determined, 1 restricted, 2 denied, 3 authorized.
signal att_status_received(status: int)
signal event_logged(event_name: String, success: bool, error_code: int)

const SINGLETON_NAME := "AppsFlyerGodotPlugin"
const SETTINGS_PREFIX := "appsflyer/config/"
const _RELAYED_SIGNALS: Array[StringName] = [
	&"conversion_data_received", &"conversion_data_failed", &"deep_link_received", &"att_status_received", &"event_logged",
]

var _plugin: Object


func _init() -> void:
	if Engine.has_singleton(SINGLETON_NAME):
		bind_plugin(Engine.get_singleton(SINGLETON_NAME))
	elif OS.has_feature("editor"):
		print("AppsFlyer: standby, only functional in iOS exports.")


func bind_plugin(plugin: Object) -> void:
	_plugin = plugin
	for signal_name in _RELAYED_SIGNALS:
		plugin.connect(signal_name, Signal(self, signal_name).emit)


## Omitted arguments fall back to the `appsflyer/config/*` project settings.
func init(dev_key := "", apple_app_id := "") -> void:
	if not _plugin:
		_report_missing_plugin()
		return
	if dev_key.is_empty():
		dev_key = _setting("dev_key")
	if apple_app_id.is_empty():
		apple_app_id = _setting("apple_app_id")
	apple_app_id = apple_app_id.strip_edges().trim_prefix("id")
	if dev_key.is_empty() or not apple_app_id.is_valid_int():
		push_error("AppsFlyer: set appsflyer/config/dev_key and a numeric appsflyer/config/apple_app_id.")
		return
	_plugin.init(dev_key, apple_app_id, onelink_custom_domains(ProjectSettings.get_setting(SETTINGS_PREFIX + "onelink_domains", PackedStringArray())))


## Bare host of a configured OneLink domain: `https://go.example.com/path` and
## `applinks:go.example.com` both become `go.example.com`.
static func normalize_host(domain: String) -> String:
	var host := domain.strip_edges().trim_prefix("applinks:")
	var scheme_end := host.find("://")
	if scheme_end != -1:
		host = host.substr(scheme_end + 3)
	return host.get_slice("/", 0).get_slice("?", 0).get_slice("#", 0).get_slice(":", 0)


## Branded hosts the SDK must resolve itself; `*.onelink.me` hosts need no registration.
static func onelink_custom_domains(domains: PackedStringArray) -> PackedStringArray:
	var custom: PackedStringArray = []
	for domain in domains:
		var host := normalize_host(domain)
		if not host.is_empty() and host != "onelink.me" and not host.ends_with(".onelink.me"):
			custom.append(host)
	return custom


## Must run before start() for the id to be attached to the install.
func set_customer_user_id(id: String) -> void:
	if _plugin:
		_plugin.set_customer_user_id(id)


func set_debug(enabled: bool) -> void:
	if _plugin:
		_plugin.set_debug(enabled)


func disable_skan(disabled: bool) -> void:
	if _plugin:
		_plugin.disable_skan(disabled)


## Shows the ATT prompt. The session start waits for the answer, or for `timeout_sec`
## when it is positive. Do not call this when a consent SDK owns the ATT prompt.
func request_tracking_authorization(timeout_sec := 0.0) -> bool:
	return _plugin.request_tracking_authorization(timeout_sec) if _plugin else false


## Starts measurement. The native side re-starts the session on every foreground.
func start() -> void:
	if _plugin:
		_plugin.start()


func log_event(event_name: String, params := {}) -> void:
	if _plugin:
		_plugin.log_event(event_name, params)


## Empty until init() has run. RevenueCat expects this value as `$appsflyerId`.
func get_appsflyer_id() -> String:
	return _plugin.get_appsflyer_id() if _plugin else ""


## Reads the ATT status without prompting; -1 where ATT does not exist.
func get_att_status() -> int:
	return _plugin.get_att_status() if _plugin else -1


func _report_missing_plugin() -> void:
	if OS.has_feature("ios"):
		push_error("AppsFlyer: native plugin missing. Enable AppsFlyerGodotPlugin under Export > iOS > Plugins.")
	elif OS.has_feature("android"):
		push_warning("AppsFlyer: Android is not implemented yet; calls are no-ops.")


func _setting(key: String) -> String:
	return str(ProjectSettings.get_setting(SETTINGS_PREFIX + key, ""))
