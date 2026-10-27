@tool
extends EditorExportPlugin

const AppsFlyer := preload("res://addons/appsflyer/appsflyer.gd")
const SETTINGS_PREFIX := "appsflyer/config/"
const ASSOCIATED_DOMAINS_KEY := "com.apple.developer.associated-domains"
const POSTBACK_COPY_URL := "https://appsflyer-skadnetwork.com/"


func _get_name() -> String:
	return "AppsFlyer"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform.get_os_name() == "iOS"


# Godot calls _export_begin on every plugin for every platform's export.
func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if not _supports_platform(get_export_platform()):
		return
	var plist := plist_for_preset(str(get_option("application/additional_plist_content")))
	if not plist.is_empty():
		add_apple_embedded_platform_plist_content(plist)

	var domains: PackedStringArray = _setting("onelink_domains", PackedStringArray())
	if not domains.is_empty() and OS.get_name() != "macOS":
		push_warning("AppsFlyer: Godot only patches the exported entitlements on macOS editors, so appsflyer/config/onelink_domains is not applied. Paste this into the preset's entitlements/additional:\n%s" % associated_domains_block(domains))


func _end_generate_apple_embedded_project(path: String, _will_build_archive: bool) -> void:
	patch_exported_entitlements(path)


static func patch_exported_entitlements(path: String) -> void:
	var domains: PackedStringArray = _setting("onelink_domains", PackedStringArray())
	if domains.is_empty():
		return
	var binary_name := path.get_file().get_basename()
	var entitlements_path := path.get_base_dir().path_join(binary_name).path_join(binary_name + ".entitlements")
	var entitlements := FileAccess.get_file_as_string(entitlements_path)
	if entitlements.is_empty():
		push_error("AppsFlyer: cannot read %s; Universal Links will not work." % entitlements_path)
		return
	if _plist_defines_key(entitlements, ASSOCIATED_DOMAINS_KEY):
		push_warning("AppsFlyer: associated domains already set in the export preset; appsflyer/config/onelink_domains ignored.")
		return
	var file := FileAccess.open(entitlements_path, FileAccess.WRITE)
	if file == null:
		push_error("AppsFlyer: cannot write %s; Universal Links will not work." % entitlements_path)
		return
	file.store_string(add_associated_domains(entitlements, domains))


static func plist_for_preset(existing_plist: String) -> String:
	return build_plist_content(_setting("att_usage_description", ""), _setting("skadnetwork_ids", PackedStringArray()), existing_plist, _setting("skan_postback_copies", true))


static func build_plist_content(att_usage_description: String, skadnetwork_ids: PackedStringArray, existing_plist := "", postback_copies := false) -> String:
	var plist := ""
	if not att_usage_description.strip_edges().is_empty() and not _already_defined(existing_plist, "NSUserTrackingUsageDescription"):
		plist += "<key>NSUserTrackingUsageDescription</key>\n<string>%s</string>\n" % att_usage_description.strip_edges().xml_escape()
	var items := ""
	for id in skadnetwork_ids:
		if not id.strip_edges().is_empty():
			items += "<dict><key>SKAdNetworkIdentifier</key><string>%s</string></dict>\n" % id.strip_edges().to_lower().xml_escape()
	if not items.is_empty() and not _already_defined(existing_plist, "SKAdNetworkItems"):
		plist += "<key>SKAdNetworkItems</key>\n<array>\n%s</array>\n" % items
	if postback_copies and not _already_defined(existing_plist, "NSAdvertisingAttributionReportEndpoint"):
		plist += "<key>NSAdvertisingAttributionReportEndpoint</key>\n<string>%s</string>\n" % POSTBACK_COPY_URL
	if postback_copies and not _already_defined(existing_plist, "AdAttributionKit"):
		plist += "<key>AdAttributionKit</key>\n<dict><key>AttributionCopyEndpoint</key><string>%s</string></dict>\n" % POSTBACK_COPY_URL
	return plist


static func add_associated_domains(entitlements: String, domains: PackedStringArray) -> String:
	var block := associated_domains_block(domains)
	if block.is_empty():
		return entitlements
	var close := entitlements.rfind("</dict>")
	if close == -1:
		push_error("AppsFlyer: the exported entitlements have no root <dict>; Universal Links will not work.")
		return entitlements
	return entitlements.substr(0, close) + block + entitlements.substr(close)


static func associated_domains_block(domains: PackedStringArray) -> String:
	var entries := ""
	for domain in domains:
		var host := AppsFlyer.normalize_host(domain)
		if not host.is_empty():
			entries += "<string>applinks:%s</string>\n" % host.xml_escape()
	if entries.is_empty():
		return ""
	return "<key>%s</key>\n<array>\n%s</array>\n" % [ASSOCIATED_DOMAINS_KEY, entries]


static func _already_defined(existing_plist: String, key: String) -> bool:
	if not _plist_defines_key(existing_plist, key):
		return false
	push_warning("AppsFlyer: %s is already set in the preset's application/additional_plist_content; keeping that value." % key)
	return true


# True when `key` is a `<key>` element. A string value that merely contains the name does not count.
static func _plist_defines_key(plist: String, key: String) -> bool:
	var from := 0
	while true:
		var open := plist.find("<key>", from)
		if open == -1:
			return false
		var close := plist.find("</key>", open + 5)
		if close == -1:
			return false
		if plist.substr(open + 5, close - open - 5).strip_edges() == key:
			return true
		from = close + 6
	return false


static func _setting(key: String, default_value: Variant) -> Variant:
	return ProjectSettings.get_setting(SETTINGS_PREFIX + key, default_value)
