extends "res://tests/test_case.gd"

const FakeNativePlugin := preload("res://tests/fake_native_plugin.gd")
const Facade := preload("res://addons/appsflyer/appsflyer.gd")


func _make_facade(native: Object = null) -> Node:
	var facade: Node = load("res://addons/appsflyer/appsflyer.gd").new()
	tree.root.add_child(facade)
	if native:
		facade.bind_plugin(native)
	return facade


func test_init_falls_back_to_project_settings_and_strips_id_prefix() -> void:
	ProjectSettings.set_setting("appsflyer/config/dev_key", "settings-key")
	ProjectSettings.set_setting("appsflyer/config/apple_app_id", " id123456789 ")
	ProjectSettings.set_setting("appsflyer/config/onelink_domains", PackedStringArray(["https://go.example.com/promo", "game.onelink.me"]))
	var native := FakeNativePlugin.new()
	var facade := _make_facade(native)

	facade.init()
	facade.init("arg-key", "id42")
	ProjectSettings.set_setting("appsflyer/config/dev_key", "")
	ProjectSettings.set_setting("appsflyer/config/apple_app_id", "")
	ProjectSettings.set_setting("appsflyer/config/onelink_domains", PackedStringArray())
	var domains := PackedStringArray(["go.example.com"])
	check_eq(native.calls, [["init", "settings-key", "123456789", domains], ["init", "arg-key", "42", domains]], "native init calls")
	facade.free()


func test_onelink_custom_domains_are_bare_branded_hosts() -> void:
	var domains := PackedStringArray([
		" https://go.example.com/promo?x=1 ", "applinks:links.example.org", "http://Brand.example.net",
		"game.onelink.me", "https://game.onelink.me/abc", "onelink.me", "notonelink.me", "", "   ",
		"https://query.example.com?pid=campaign", "https://fragment.example.com#promo", "https://port.example.com:443/path",
	])

	check_eq(Facade.onelink_custom_domains(domains), PackedStringArray(["go.example.com", "links.example.org", "Brand.example.net", "notonelink.me", "query.example.com", "fragment.example.com", "port.example.com"]), "custom domains")


func test_native_is_bound_before_facade_enters_tree() -> void:
	var native := FakeNativePlugin.new()
	Engine.register_singleton(Facade.SINGLETON_NAME, native)
	var facade := Facade.new()
	var received: Array = []
	facade.conversion_data_received.connect(func(data: Dictionary) -> void: received.append(data))
	facade.init("key", "123")
	native.conversion_data_received.emit({"af_status": "Organic"})
	check_eq(native.calls, [["init", "key", "123", PackedStringArray()]], "initialization from an earlier autoload")
	check_eq(received, [{"af_status": "Organic"}], "signals before entering the tree")
	facade.free()
	Engine.unregister_singleton(Facade.SINGLETON_NAME)


func test_init_rejects_missing_key_or_non_numeric_app_id() -> void:
	var native := FakeNativePlugin.new()
	var facade := _make_facade(native)

	facade.init("", "123")
	facade.init("key", "com.example.game")
	check_eq(native.calls, [] as Array[Array], "native init calls")
	facade.free()


func test_native_signals_reach_facade_listeners() -> void:
	var native := FakeNativePlugin.new()
	var facade := _make_facade(native)
	var received: Array = []
	facade.conversion_data_received.connect(func(data: Dictionary) -> void: received.append(data))
	facade.conversion_data_failed.connect(func(error: String) -> void: received.append(error))
	facade.deep_link_received.connect(func(result: Dictionary) -> void: received.append(result))
	facade.att_status_received.connect(func(status: int) -> void: received.append(status))
	facade.event_logged.connect(func(event_name: String, success: bool, code: int) -> void: received.append([event_name, success, code]))

	native.conversion_data_received.emit({"af_status": "Organic"})
	native.conversion_data_failed.emit("timeout")
	native.deep_link_received.emit({"status": "found", "deeplink_value": "level_7"})
	native.att_status_received.emit(2)
	native.event_logged.emit("af_login", false, 40)
	check_eq(received, [{"af_status": "Organic"}, "timeout", {"status": "found", "deeplink_value": "level_7"}, 2, ["af_login", false, 40]], "relayed signals")
	facade.free()


func test_without_native_plugin_every_call_is_a_harmless_default() -> void:
	var facade := _make_facade()

	facade.set_debug(true)
	facade.set_customer_user_id("user")
	facade.disable_skan(true)
	facade.init("key", "123")
	check(not facade.request_tracking_authorization(1.0), "ATT request accepted without a plugin")
	facade.start()
	facade.log_event("af_login", {"af_level": 3})
	check_eq(facade.get_appsflyer_id(), "", "appsflyer id")
	check_eq(facade.get_att_status(), -1, "att status")
	facade.free()
