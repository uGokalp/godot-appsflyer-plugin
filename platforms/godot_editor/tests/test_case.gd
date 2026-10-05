extends RefCounted

var tree: SceneTree
var failures: PackedStringArray = []


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])


func silence_errors() -> bool:
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	return printing


func restore_errors(printing: bool) -> void:
	Engine.print_error_messages = printing
