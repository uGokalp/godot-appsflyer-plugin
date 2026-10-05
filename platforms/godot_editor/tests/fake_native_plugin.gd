extends RefCounted

signal conversion_data_received(data: Dictionary)
signal conversion_data_failed(error: String)
signal deep_link_received(result: Dictionary)
signal att_status_received(status: int)
signal event_logged(event_name: String, success: bool, error_code: int)

var calls: Array[Array] = []


func init(dev_key: String, apple_app_id: String, onelink_custom_domains: PackedStringArray) -> void:
	calls.append(["init", dev_key, apple_app_id, onelink_custom_domains])
