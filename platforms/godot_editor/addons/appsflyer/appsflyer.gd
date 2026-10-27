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

## The ad mediation platform that served an impression, for `log_ad_revenue()`.
enum MediationNetwork {
	GOOGLE_ADMOB = 1,
	IRONSOURCE = 2,
	APPLOVIN_MAX = 3,
	FYBER = 4,
	APPODEAL = 5,
	ADMOST = 6,
	TOPON = 7,
	TRADPLUS = 8,
	YANDEX = 9,
	CHARTBOOST = 10,
	UNITY = 11,
	TOPON_PTE = 12,
	CUSTOM = 13,
	DIRECT_MONETIZATION = 14,
}

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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_plugin):
		for signal_name in _RELAYED_SIGNALS:
			_plugin.disconnect(signal_name, Signal(self, signal_name).emit)


func bind_plugin(plugin: Object) -> void:
	_plugin = plugin
	for signal_name in _RELAYED_SIGNALS:
		plugin.connect(signal_name, Signal(self, signal_name).emit)


## Omitted arguments fall back to the `appsflyer/config/*` project settings.
func init(dev_key := "", apple_app_id := "") -> void:
	if not _plugin:
		_report_missing_plugin()
		return
	if dev_key.strip_edges().is_empty():
		dev_key = _setting("dev_key")
	if apple_app_id.strip_edges().is_empty():
		apple_app_id = _setting("apple_app_id")
	dev_key = dev_key.strip_edges()
	apple_app_id = apple_app_id.strip_edges().trim_prefix("id")
	if dev_key.is_empty() or not is_app_store_id(apple_app_id):
		push_error("AppsFlyer: set appsflyer/config/dev_key and a numeric appsflyer/config/apple_app_id.")
		return
	_plugin.init(dev_key, apple_app_id, onelink_custom_domains(ProjectSettings.get_setting(SETTINGS_PREFIX + "onelink_domains", PackedStringArray())))


static func is_app_store_id(id: String) -> bool:
	return not id.is_empty() and id.lstrip("0123456789").is_empty() and not id.lstrip("0").is_empty()


## Bare lowercase host of a configured OneLink domain: `https://Go.Example.com/path` and
## `applinks:go.example.com` both become `go.example.com`.
static func normalize_host(domain: String) -> String:
	var host := domain.strip_edges().trim_prefix("applinks:")
	var scheme_end := host.find("://")
	if scheme_end != -1:
		host = host.substr(scheme_end + 3)
	return host.get_slice("/", 0).get_slice("?", 0).get_slice("#", 0).get_slice(":", 0).to_lower()


## Branded hosts the SDK must resolve itself; `*.onelink.me` hosts need no registration, and
## wildcard entries only make sense in the entitlement.
static func onelink_custom_domains(domains: PackedStringArray) -> PackedStringArray:
	var custom: PackedStringArray = []
	for domain in domains:
		var host := normalize_host(domain)
		if not host.is_empty() and not host.begins_with("*") and host != "onelink.me" and not host.ends_with(".onelink.me"):
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


## GDPR/DMA consent. Call it before start() on every launch: the SDK does not persist it.
## Users outside GDPR scope: `set_consent(false)`. Pass `null` for an answer you do not have.
func set_consent(subject_to_gdpr: bool, data_usage: Variant = null, ads_personalization: Variant = null, ad_storage: Variant = null) -> void:
	if _plugin:
		_plugin.set_consent(subject_to_gdpr, data_usage, ads_personalization, ad_storage)


## Lets the SDK read consent written by a TCF v2 CMP instead of `set_consent()`.
func enable_tcf_data_collection(enabled: bool) -> void:
	if _plugin:
		_plugin.enable_tcf_data_collection(enabled)


## Stops every SDK request, for users who opt out of measurement.
func set_stopped(stopped: bool) -> void:
	if _plugin:
		_plugin.set_stopped(stopped)


func is_stopped() -> bool:
	return _plugin.is_stopped() if _plugin else false


## Keeps measuring sessions and events without identifying the user.
func set_anonymize_user(enabled: bool) -> void:
	if _plugin:
		_plugin.set_anonymize_user(enabled)


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


## One ad impression's revenue. `monetization_network` is the network that served the ad
## (e.g. "applovin"); optional `params` keys: `country`, `ad_unit`, `ad_type`, `placement`.
func log_ad_revenue(monetization_network: String, mediation_network: MediationNetwork, currency: String, revenue: float, params := {}) -> void:
	if _plugin:
		_plugin.log_ad_revenue(monetization_network, mediation_network, currency, revenue, params)


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
