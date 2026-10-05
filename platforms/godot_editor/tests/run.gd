extends SceneTree

const SUITES: Array[String] = ["res://tests/test_facade.gd", "res://tests/test_ios_export_plugin.gd"]


class ScriptErrorLogger extends Logger:
	var errors: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_mutex.lock()
		errors.append("script error: %s (%s:%d in %s)" % [rationale if not rationale.is_empty() else code, file, line, function])
		_mutex.unlock()

	func take() -> PackedStringArray:
		_mutex.lock()
		var taken := errors
		errors = []
		_mutex.unlock()
		return taken


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var logger := ScriptErrorLogger.new()
	OS.add_logger(logger)
	var total := 0
	var failed := 0
	for path in SUITES:
		for method in load(path).new().get_method_list():
			var test_name: String = method.name
			if not test_name.begins_with("test_"):
				continue
			var suite: Object = load(path).new()
			suite.tree = self
			logger.take()
			await suite.call(test_name)
			suite.failures.append_array(logger.take())
			total += 1
			if suite.failures.is_empty():
				print("  ok    %s" % test_name)
			else:
				failed += 1
				print("  FAIL  %s\n        %s" % [test_name, "\n        ".join(suite.failures)])
	OS.remove_logger(logger)
	print("%d/%d passed" % [total - failed, total])
	quit(1 if failed > 0 else 0)
