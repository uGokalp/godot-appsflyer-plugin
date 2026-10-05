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
	var patched := ExportPlugin.add_associated_domains(ENTITLEMENTS, PackedStringArray(["https://game.onelink.me/AbCd", "applinks:go.example.com", " http://links.example.org/path?q=1 ", "  "]))

	check_eq(_root_values(patched, "com.apple.developer.associated-domains"), PackedStringArray(["applinks:game.onelink.me", "applinks:go.example.com", "applinks:links.example.org"]), "domains")
	check_eq(_root_values(patched, "aps-environment"), PackedStringArray(["development"]), "existing entitlement")
	check(patched.ends_with("</dict>\n</plist>\n"), "document tail preserved")


func test_blank_domains_leave_entitlements_untouched() -> void:
	check_eq(ExportPlugin.add_associated_domains(ENTITLEMENTS, PackedStringArray(["", " "])), ENTITLEMENTS, "entitlements")


func test_keys_already_in_preset_plist_are_not_duplicated() -> void:
	var existing := "<key>NSUserTrackingUsageDescription</key>\n<string>Preset text</string>\n"
	var plist := ExportPlugin.build_plist_content("Plugin text", PackedStringArray(["v9wttpbfk9.skadnetwork"]), existing)

	check_eq(_root_values(_plist_document(existing + plist), "NSUserTrackingUsageDescription"), PackedStringArray(["Preset text"]), "ATT description")
	check_eq(_root_values(_plist_document(existing + plist), "SKAdNetworkItems"), PackedStringArray(["v9wttpbfk9.skadnetwork"]), "identifiers")
