extends Node

## Base class for every test. Subclass it, add methods named `test_*`, and the
## runner picks them up. Test methods may await -- the runner awaits each one,
## so both plain and coroutine tests work without any extra ceremony.
##
## Known-bug tests: call `expect_failure("...")` at the top of a test that
## documents a bug we haven't fixed yet. A failing expected-failure is reported
## as XFAIL and does not break the build; if it starts *passing*, the runner
## fails loudly so the stale expectation gets removed along with the bug.

var _failures: Array[String] = []
var _assertion_count: int = 0
var _expected_failure: String = ""
var _tracked: Array[Node] = []


## Overridable lifecycle hooks. Either may await.
func before_each() -> void:
	pass


func after_each() -> void:
	pass


## Mark the current test as documenting a known, unfixed bug.
func expect_failure(reason: String) -> void:
	_expected_failure = reason


## Register a node for automatic cleanup after the test finishes.
func track(node: Node) -> Node:
	_tracked.append(node)
	return node


## Let the physics server catch up -- new bodies aren't in the space until a
## physics frame has run, so raycast tests need this before querying.
func settle(frames: int = 1) -> void:
	for i in frames:
		await get_tree().physics_frame


# --- assertions ---------------------------------------------------------

func assert_true(value: Variant, context: String = "") -> void:
	_record(value is bool and value, "expected true, got %s" % _show(value), context)


func assert_false(value: Variant, context: String = "") -> void:
	_record(value is bool and not value, "expected false, got %s" % _show(value), context)


func assert_eq(actual: Variant, expected: Variant, context: String = "") -> void:
	_record(_same(actual, expected),
		"expected %s, got %s" % [_show(expected), _show(actual)], context)


func assert_ne(actual: Variant, unexpected: Variant, context: String = "") -> void:
	_record(not _same(actual, unexpected),
		"expected anything other than %s" % _show(unexpected), context)


func assert_almost_eq(actual: float, expected: float, epsilon: float = 0.0001,
		context: String = "") -> void:
	_record(absf(actual - expected) <= epsilon,
		"expected %s (+/- %s), got %s" % [expected, epsilon, actual], context)


func assert_gt(actual: float, floor_value: float, context: String = "") -> void:
	_record(actual > floor_value, "expected > %s, got %s" % [floor_value, actual], context)


func assert_lt(actual: float, ceiling: float, context: String = "") -> void:
	_record(actual < ceiling, "expected < %s, got %s" % [ceiling, actual], context)


func assert_null(value: Variant, context: String = "") -> void:
	_record(value == null, "expected null, got %s" % _show(value), context)


func assert_not_null(value: Variant, context: String = "") -> void:
	_record(value != null, "expected a value, got null", context)


func fail(message: String) -> void:
	_record(false, message, "")


# --- internals ----------------------------------------------------------

func _record(ok: bool, message: String, context: String) -> void:
	_assertion_count += 1
	if ok:
		return
	_failures.append(message if context.is_empty() else "%s -- %s" % [context, message])


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(a, b)
	if a is Vector3 and b is Vector3:
		return (a as Vector3).is_equal_approx(b)
	return a == b


func _show(value: Variant) -> String:
	if value == null:
		return "null"
	if value is String:
		return '"%s"' % value
	return str(value)


func _release_tracked() -> void:
	for node in _tracked:
		if is_instance_valid(node):
			node.free()
	_tracked.clear()
