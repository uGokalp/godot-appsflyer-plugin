extends Object

signal conversion_data_received(data: Dictionary)
signal conversion_data_failed(error: String)
signal deep_link_received(result: Dictionary)
signal att_status_received(status: int)
signal event_logged(event_name: String, success: bool, error_code: int)

var calls: Array[Array] = []


func init(dev_key: String, apple_app_id: String, onelink_custom_domains: PackedStringArray) -> void:
	calls.append(["init", dev_key, apple_app_id, onelink_custom_domains])


func start() -> void:
	calls.append(["start"])


func set_customer_user_id(id: String) -> void:
	calls.append(["set_customer_user_id", id])


func set_debug(enabled: bool) -> void:
	calls.append(["set_debug", enabled])


func disable_skan(disabled: bool) -> void:
	calls.append(["disable_skan", disabled])


func set_stopped(stopped: bool) -> void:
	calls.append(["set_stopped", stopped])


func is_stopped() -> bool:
	calls.append(["is_stopped"])
	return true


func set_anonymize_user(enabled: bool) -> void:
	calls.append(["set_anonymize_user", enabled])


func set_consent(subject_to_gdpr: bool, data_usage: Variant, ads_personalization: Variant, ad_storage: Variant) -> void:
	calls.append(["set_consent", subject_to_gdpr, data_usage, ads_personalization, ad_storage])


func enable_tcf_data_collection(enabled: bool) -> void:
	calls.append(["enable_tcf_data_collection", enabled])


func request_tracking_authorization(timeout_sec: float) -> bool:
	calls.append(["request_tracking_authorization", timeout_sec])
	return true


func get_att_status() -> int:
	calls.append(["get_att_status"])
	return 3


func log_event(event_name: String, params: Dictionary) -> void:
	calls.append(["log_event", event_name, params])


func log_ad_revenue(monetization_network: String, mediation_network: int, currency: String, revenue: float, params: Dictionary) -> void:
	calls.append(["log_ad_revenue", monetization_network, mediation_network, currency, revenue, params])


func get_appsflyer_id() -> String:
	calls.append(["get_appsflyer_id"])
	return "af-id"
