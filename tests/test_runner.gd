extends Node

## Headless test runner. Finds every `test_*.gd` under tests/unit and
## tests/integration, runs each `test_*` method on a fresh instance, prints a
## report, and -- the part the old smoke test was missing -- exits non-zero when
## something is wrong, so CI can actually gate on it.
##
##   godot --headless --path . res://tests/TestRunner.tscn
##   godot --headless --path . res://tests/TestRunner.tscn -- --filter=vision
##
## `--filter=` matches against "<file>.<method>", so `--filter=game_manager`
## runs one file and `--filter=sight_range` runs one test.

const TEST_DIRS := ["res://tests/unit", "res://tests/integration"]

var _passed: int = 0
var _failed: int = 0
var _xfailed: int = 0
var _xpassed: int = 0
var _assertions: int = 0
var _report: Array[String] = []


func _ready() -> void:
	await _run_all()


func _run_all() -> void:
	var filter := _filter_from_cmdline()
	var script_paths := _collect_scripts()
	if script_paths.is_empty():
		print("[tests] no test scripts found under ", ", ".join(TEST_DIRS))
		get_tree().quit(1)
		return

	print("")
	print("Bella's Game -- test suite")
	if not filter.is_empty():
		print("filter: ", filter)
	print("")

	var started := Time.get_ticks_msec()
	for path in script_paths:
		await _run_script(path, filter)
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0

	print("")
	if not _report.is_empty():
		print("Failures:")
		for line in _report:
			print(line)
		print("")

	var total := _passed + _failed + _xfailed + _xpassed
	print("%d tests, %d assertions, %.2fs" % [total, _assertions, elapsed])
	print("  passed  %d" % _passed)
	print("  failed  %d" % _failed)
	print("  xfail   %d  (known bugs, documented and tolerated)" % _xfailed)
	print("  xpass   %d  (expected to fail but passed -- fix the test)" % _xpassed)

	var broken := _failed + _xpassed
	print("")
	print("RESULT: %s" % ("FAILED" if broken > 0 else "OK"))
	get_tree().quit(1 if broken > 0 else 0)


func _run_script(path: String, filter: String) -> void:
	var script: GDScript = load(path)
	if script == null:
		_failed += 1
		_report.append("  %s -- could not be loaded" % path)
		return

	var label := path.get_file().trim_suffix(".gd").trim_prefix("test_")
	var methods := _test_methods(script)
	var printed_header := false

	for method in methods:
		if not filter.is_empty() and not ("%s.%s" % [label, method]).contains(filter):
			continue
		if not printed_header:
			print("  %s" % label)
			printed_header = true
		await _run_one(script, label, method)


## A fresh instance per test method, so state never leaks between tests.
func _run_one(script: GDScript, label: String, method: String) -> void:
	var test: Node = script.new()
	add_child(test)

	await test.call("before_each")
	await test.call(method)
	await test.call("after_each")
	test.call("_release_tracked")

	var failures: Array = test.get("_failures")
	var expected: String = test.get("_expected_failure")
	var asserted: int = int(test.get("_assertion_count"))
	_assertions += asserted

	if asserted == 0:
		# A GDScript runtime error aborts the rest of the method without
		# unwinding, which used to look exactly like a clean pass.
		_failed += 1
		print("    FAIL   %s" % method)
		_report.append("  %s.%s\n      no assertions ran -- the test body probably "
			% [label, method] + "hit a script error, check the log above")
	elif failures.is_empty() and expected.is_empty():
		_passed += 1
		print("    PASS   %s" % method)
	elif failures.is_empty() and not expected.is_empty():
		_xpassed += 1
		print("    XPASS  %s" % method)
		_report.append("  %s.%s expected to fail but passed -- if the bug is fixed, "
			% [label, method] + "drop the expect_failure() line.\n      was: %s" % expected)
	elif not expected.is_empty():
		_xfailed += 1
		print("    XFAIL  %s  (%s)" % [method, expected])
	else:
		_failed += 1
		print("    FAIL   %s" % method)
		for failure in failures:
			_report.append("  %s.%s\n      %s" % [label, method, failure])

	test.queue_free()


func _test_methods(script: GDScript) -> Array[String]:
	var probe: Object = script.new()
	var names: Array[String] = []
	for entry in probe.get_method_list():
		var method_name: String = entry.name
		if method_name.begins_with("test_") and not names.has(method_name):
			names.append(method_name)
	if probe is Node:
		(probe as Node).free()
	names.sort()
	return names


func _collect_scripts() -> Array[String]:
	var found: Array[String] = []
	for dir_path in TEST_DIRS:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file in dir.get_files():
			# Godot hands back .remap/.import names in some contexts; normalise.
			var clean := file.trim_suffix(".remap")
			if clean.begins_with("test_") and clean.ends_with(".gd"):
				found.append("%s/%s" % [dir_path, clean])
	found.sort()
	return found


func _filter_from_cmdline() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			return arg.trim_prefix("--filter=")
	return ""
