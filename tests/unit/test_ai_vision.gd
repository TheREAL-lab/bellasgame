extends "res://tests/test_case.gd"

## AIController._can_see -- the vision cone plus line-of-sight check that lets
## you break a bot's line of sight by ducking behind a mushroom.
##
## These drive `_can_see` directly against a real physics space. The bot's
## facing is set on `visual` using the model's own convention (the squishy is
## built with its eyes at -Z, so -basis.z is the way it looks); whether
## Player._move actually orients `visual` that way is covered separately in
## test_player_facing.gd.

const FakePlayer := preload("res://tests/helpers/fake_player.gd")
const AIControllerScript := preload("res://scripts/AIController.gd")

const SIGHT_RANGE := 14.0     # mirrors AIController.SIGHT_RANGE
const SIGHT_ANGLE_DEG := 75.0 # mirrors AIController.SIGHT_ANGLE

var _ai: Node
var _bot: CharacterBody3D


func before_each() -> void:
	_bot = FakePlayer.make(-1, Vector3.ZERO)
	add_child(track(_bot))

	_ai = AIControllerScript.new()
	add_child(track(_ai))
	# Never let the brain tick: activate() is skipped, so nav_agent is null.
	_ai.set_physics_process(false)
	_ai.parent = _bot


## Drop a target the bot might see. `solid` gives it the real Player capsule on
## layer 2, for proving that players don't block each other's sight.
func _target_at(position: Vector3, solid: bool = false) -> CharacterBody3D:
	var node := FakePlayer.make(-2, position, solid)
	add_child(track(node))
	return node


## Scenery: a static box on layer 1, like every prop Arena.gd builds.
func _wall_at(position: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = position
	add_child(track(body))
	return body


## Place a target `degrees` off the bot's facing, at `distance` metres.
func _target_at_angle(degrees: float, distance: float) -> CharacterBody3D:
	var radians := deg_to_rad(degrees)
	# The bot's default orientation looks down -Z.
	return _target_at(Vector3(sin(radians) * distance, 0.0, -cos(radians) * distance))


func test_sees_a_hider_straight_ahead() -> void:
	var target := _target_at(Vector3(0, 0, -6))
	await settle()
	assert_true(_ai._can_see(target), "clear line of sight, 6m ahead")


func test_cannot_see_a_hider_beyond_sight_range() -> void:
	var target := _target_at(Vector3(0, 0, -(SIGHT_RANGE + 2.0)))
	await settle()
	assert_false(_ai._can_see(target), "%.0fm away, past the %.0fm limit"
		% [SIGHT_RANGE + 2.0, SIGHT_RANGE])


func test_sees_a_hider_just_inside_the_vision_cone() -> void:
	var target := _target_at_angle(SIGHT_ANGLE_DEG - 5.0, 6.0)
	await settle()
	assert_true(_ai._can_see(target), "%.0f degrees off centre" % (SIGHT_ANGLE_DEG - 5.0))


func test_cannot_see_a_hider_just_outside_the_vision_cone() -> void:
	var target := _target_at_angle(SIGHT_ANGLE_DEG + 5.0, 6.0)
	await settle()
	assert_false(_ai._can_see(target), "%.0f degrees off centre" % (SIGHT_ANGLE_DEG + 5.0))


func test_cannot_see_a_hider_directly_behind() -> void:
	var target := _target_at(Vector3(0, 0, 6))
	await settle()
	assert_false(_ai._can_see(target), "stood right behind the bot")


## The headline promise in the README: hide behind a prop and IT loses you.
func test_scenery_blocks_line_of_sight() -> void:
	var target := _target_at(Vector3(0, 0, -6))
	_wall_at(Vector3(0, 1, -3), Vector3(4, 2, 1))
	await settle()
	assert_false(_ai._can_see(target), "a prop stands between bot and hider")


## _can_see masks to layer 1 on purpose, so a team-mate wandering through the
## line of sight must not act as cover.
func test_another_player_does_not_block_line_of_sight() -> void:
	var target := _target_at(Vector3(0, 0, -6))
	var blocker := FakePlayer.make(-3, Vector3(0, 0, -3), true)
	add_child(track(blocker))
	await settle()
	assert_true(_ai._can_see(target), "another player is not cover")


## The cone has to be attached to the bot's head, not to the world axes.
func test_the_vision_cone_turns_with_the_bot() -> void:
	var behind := _target_at(Vector3(0, 0, 6))
	await settle()

	assert_false(_ai._can_see(behind), "before turning round")
	_bot.face_towards(behind.global_position)
	assert_true(_ai._can_see(behind), "after turning to look at them")
