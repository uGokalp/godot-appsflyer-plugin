@tool
extends EditorPlugin

const AUTOLOAD_NAME := "AppsFlyer"
var _settings := {
	"appsflyer/config/dev_key": [TYPE_STRING, ""],
	"appsflyer/config/apple_app_id": [TYPE_STRING, ""],
	"appsflyer/config/att_usage_description": [TYPE_STRING, ""],
	"appsflyer/config/onelink_domains": [TYPE_PACKED_STRING_ARRAY, PackedStringArray()],
	"appsflyer/config/skadnetwork_ids": [TYPE_PACKED_STRING_ARRAY, PackedStringArray()],
}

var _ios_export_plugin: EditorExportPlugin


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/appsflyer/appsflyer.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	for key: String in _settings:
		var type: int = _settings[key][0]
		var default_value: Variant = _settings[key][1]
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, default_value)
		ProjectSettings.set_initial_value(key, default_value)
		ProjectSettings.add_property_info({"name": key, "type": type})
		ProjectSettings.set_as_basic(key, true)
	_ios_export_plugin = preload("res://addons/appsflyer/ios_export_plugin.gd").new()
	add_export_plugin(_ios_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_ios_export_plugin)
