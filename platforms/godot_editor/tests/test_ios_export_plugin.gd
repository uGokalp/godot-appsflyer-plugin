extends "res://tests/test_case.gd"

const ExportPlugin := preload("res://addons/appsflyer/ios_export_plugin.gd")
const ENTITLEMENTS := """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>aps-environment</key>
<string>development</string>

</dict>
</plist>
"""


func _plist_document(content: String) -> String:
	return "<plist version=\"1.0\"><dict>\n%s</dict></plist>" % content


## Non-key text under <key>`key`</key> of the root <dict>; fails on malformed XML.
func _root_values(xml: String, key: String) -> PackedStringArray:
	var parser := XMLParser.new()
	parser.open_buffer(xml.to_utf8_buffer())
	var values: PackedStringArray = []
	var depth := 0
	var key_depth := -1
	var collecting := false
	var error := parser.read()
	while error == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				key_depth = depth if parser.get_node_name() == "key" else -1
				if not parser.is_empty():
					depth += 1
			XMLParser.NODE_ELEMENT_END:
				depth -= 1
				key_depth = -1
			XMLParser.NODE_TEXT:
				var text := parser.get_node_data().strip_edges()
				if key_depth == 2:
					collecting = text == key
				elif key_depth == -1 and collecting and not text.is_empty():
					values.append(text.xml_unescape())
		error = parser.read()
	if error != ERR_FILE_EOF or depth != 0:
		return ["<malformed xml>"]
	return values


func test_att_description_is_escaped_into_valid_plist() -> void:
	var description := "Ads & offers <tailored> for \"you\""
	var plist := ExportPlugin.build_plist_content("  %s  " % description, PackedStringArray())

	check_eq(_root_values(_plist_document(plist), "NSUserTrackingUsageDescription"), PackedStringArray([description]), "parsed description")


func test_empty_settings_add_no_plist_keys() -> void:
	check_eq(ExportPlugin.build_plist_content("   ", PackedStringArray()), "", "plist content")


func test_skadnetwork_ids_are_normalized_items() -> void:
	var plist := ExportPlugin.build_plist_content("", PackedStringArray([" V9WTTPBFK9.skadnetwork ", "n38lu8286q.skadnetwork"]))

	check(not plist.contains("NSUserTrackingUsageDescription"), "no ATT key without a description")
	check_eq(_root_values(_plist_document(plist), "SKAdNetworkItems"), PackedStringArray(["v9wttpbfk9.skadnetwork", "n38lu8286q.skadnetwork"]), "identifiers")


func test_associated_domains_are_inserted_inside_root_dict() -> void:
	var patched := ExportPlugin.add_associated_domains(ENTITLEMENTS, PackedStringArray(["https://game.onelink.me?pid=test", "applinks:go.example.com", " http://links.example.org:443#promo ", "  "]))

	check_eq(_root_values(patched, "com.apple.developer.associated-domains"), PackedStringArray(["applinks:game.onelink.me", "applinks:go.example.com", "applinks:links.example.org"]), "domains")
	check_eq(_root_values(patched, "aps-environment"), PackedStringArray(["development"]), "existing entitlement")
	check(patched.ends_with("</dict>\n</plist>\n"), "document tail preserved")


func test_blank_domains_leave_entitlements_untouched() -> void:
	check_eq(ExportPlugin.add_associated_domains(ENTITLEMENTS, PackedStringArray(["", " "])), ENTITLEMENTS, "entitlements")


func test_keys_already_in_preset_plist_are_not_duplicated() -> void:
	var existing := "<key>NSUserTrackingUsageDescription</key>\n<string>Preset text</string>\n"
	var printing := silence_errors()
	var plist := ExportPlugin.build_plist_content("Plugin text", PackedStringArray(["v9wttpbfk9.skadnetwork"]), existing)
	restore_errors(printing)

	check_eq(_root_values(_plist_document(existing + plist), "NSUserTrackingUsageDescription"), PackedStringArray(["Preset text"]), "ATT description")
	check_eq(_root_values(_plist_document(existing + plist), "SKAdNetworkItems"), PackedStringArray(["v9wttpbfk9.skadnetwork"]), "identifiers")


func test_key_names_inside_string_values_are_still_written() -> void:
	var existing := "<key>CFBundleDisplayName</key>\n<string>NSUserTrackingUsageDescription SKAdNetworkItems</string>\n"
	var plist := ExportPlugin.build_plist_content("Plugin text", PackedStringArray(["v9wttpbfk9.skadnetwork"]), existing)
	var document := _plist_document(existing + plist)

	check_eq(_root_values(document, "NSUserTrackingUsageDescription"), PackedStringArray(["Plugin text"]), "ATT description")
	check_eq(_root_values(document, "SKAdNetworkItems"), PackedStringArray(["v9wttpbfk9.skadnetwork"]), "identifiers")


func test_blank_skadnetwork_ids_are_skipped() -> void:
	check_eq(ExportPlugin.build_plist_content("", PackedStringArray(["", "  "])), "", "all blank")
	var plist := ExportPlugin.build_plist_content("", PackedStringArray([" ", "v9wttpbfk9.skadnetwork"]))
	check_eq(_root_values(_plist_document(plist), "SKAdNetworkItems"), PackedStringArray(["v9wttpbfk9.skadnetwork"]), "identifiers")


func test_postback_copies_point_skan_and_adattributionkit_at_appsflyer() -> void:
	var document := _plist_document(ExportPlugin.build_plist_content("", PackedStringArray(), "", true))

	check_eq(_root_values(document, "NSAdvertisingAttributionReportEndpoint"), PackedStringArray([ExportPlugin.POSTBACK_COPY_URL]), "SKAN endpoint")
	check_eq(_root_values(document, "AdAttributionKit"), PackedStringArray([ExportPlugin.POSTBACK_COPY_URL]), "AdAttributionKit endpoint")
	check(document.contains("<key>AttributionCopyEndpoint</key>"), "AdAttributionKit copy key")
	check_eq(ExportPlugin.build_plist_content("", PackedStringArray(), "", false), "", "disabled")


func test_preset_plist_is_respected_by_the_export_hook() -> void:
	ProjectSettings.set_setting("appsflyer/config/att_usage_description", "Plugin text")
	ProjectSettings.set_setting("appsflyer/config/skan_postback_copies", true)
	var existing := "<key>NSUserTrackingUsageDescription</key>\n<string>Preset text</string>\n<key>NSAdvertisingAttributionReportEndpoint</key>\n<string>https://other.example.com/</string>\n"
	var printing := silence_errors()
	var document := _plist_document(existing + ExportPlugin.plist_for_preset(existing))
	restore_errors(printing)
	ProjectSettings.set_setting("appsflyer/config/att_usage_description", "")

	check_eq(_root_values(document, "NSUserTrackingUsageDescription"), PackedStringArray(["Preset text"]), "ATT description")
	check_eq(_root_values(document, "NSAdvertisingAttributionReportEndpoint"), PackedStringArray(["https://other.example.com/"]), "SKAN endpoint")
	check_eq(_root_values(document, "AdAttributionKit"), PackedStringArray([ExportPlugin.POSTBACK_COPY_URL]), "AdAttributionKit endpoint")


func _export_project_with_entitlements(entitlements: String) -> String:
	var root := OS.get_cache_dir().path_join("appsflyer_export_test_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root.path_join("Game"))
	var path := root.path_join("Game/Game.entitlements")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(entitlements)
	file.close()
	ProjectSettings.set_setting("appsflyer/config/onelink_domains", PackedStringArray(["go.example.com"]))
	var printing := silence_errors()
	ExportPlugin.patch_exported_entitlements(root.path_join("Game.xcodeproj"))
	restore_errors(printing)
	ProjectSettings.set_setting("appsflyer/config/onelink_domains", PackedStringArray())
	var patched := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(root.path_join("Game"))
	DirAccess.remove_absolute(root)
	return patched


func test_export_hook_adds_domains_to_the_exported_entitlements() -> void:
	check_eq(_root_values(_export_project_with_entitlements(ENTITLEMENTS), "com.apple.developer.associated-domains"), PackedStringArray(["applinks:go.example.com"]), "domains")


func test_export_hook_keeps_associated_domains_from_the_preset() -> void:
	var preset := ENTITLEMENTS.replace("</dict>", "<key>com.apple.developer.associated-domains</key>\n<array><string>applinks:preset.example.com</string></array>\n</dict>")
	check_eq(_export_project_with_entitlements(preset), preset, "entitlements")


func test_entitlements_without_root_dict_are_left_alone() -> void:
	var broken := "<plist version=\"1.0\"></plist>"
	var printing := silence_errors()
	var patched := ExportPlugin.add_associated_domains(broken, PackedStringArray(["go.example.com"]))
	restore_errors(printing)
	check_eq(patched, broken, "entitlements")
