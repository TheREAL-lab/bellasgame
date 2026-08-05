extends "res://tests/test_case.gd"

## Which way a squishy is pointing.
##
## This matters for more than looks: AIController._can_see builds the vision
## cone around `-visual.global_transform.basis.z`, so if `visual` is yawed the
## wrong way round, every bot hunter searches with its cone pointing out of the
## back of its head.

const PlayerScene := preload("res://scenes/Player.tscn")
const SquishyScript := preload("res://scripts/Squishy.gd")


func before_each() -> void:
	GameManager.state = GameManager.State.LOBBY
	GameManager.hunter_id = 0
	GameManager.hider_ids = []
	GameManager.tagged = {}
	NetworkManager.players.clear()


func after_each() -> void:
	GameManager.state = GameManager.State.LOBBY
	GameManager.time_left = 0.0
	NetworkManager.players.clear()


## A real Player from the real scene, driven as a bot so we can feed it
## movement directly through apply_ai_input instead of faking keyboard input.
func _make_walking_bot(id: int) -> CharacterBody3D:
	var bot: CharacterBody3D = PlayerScene.instantiate()
	bot.player_id = id
	bot.player_name = "Testy"
	bot.is_bot = true
	add_child(track(bot))
	# The brain would fight us for the input; we're testing the body.
	bot.ai_controller.set_physics_process(false)
	return bot


## Establishes the convention the rest of the file leans on: every squishy is
## modelled looking down -Z, so -basis.z is genuinely "where it is looking".
func test_every_squishy_is_built_facing_negative_z() -> void:
	for species_index in 6:
		var visual: Node3D = SquishyScript.new()
		add_child(track(visual))
		visual.build(species_index, Color.WHITE)
		assert_lt(visual.eye_left.position.z, 0.0,
			"%s has its eyes on the -Z side" % visual.species_name())


func test_a_walking_squishy_faces_the_way_it_is_going() -> void:
	expect_failure("Player._move yaws `visual` with atan2(direction.x, "
		+ "direction.z), which lines the model's +Z (its tail) up with the "
		+ "direction of travel -- so characters moonwalk, and because "
		+ "AIController._can_see reads -basis.z, bot hunters only notice "
		+ "hiders standing behind them")
	var bot := _make_walking_bot(-1)
	_begin_round()

	# Several directions, none of them the identity orientation, so a character
	# that simply never turns cannot pass this by standing still.
	for travel in [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]:
		await _walk(bot, travel)
		var facing: Vector3 = -bot.visual.global_transform.basis.z
		assert_gt(facing.dot(travel), 0.8,
			"walking toward %s, the squishy looks toward %s" % [travel, facing])


## Guards the test above: if the bot never actually moves, its facing proves
## nothing, so check the body is really travelling where we point it.
func test_a_bot_walks_in_the_direction_it_is_given() -> void:
	var bot := _make_walking_bot(-1)
	_begin_round()

	await _walk(bot, Vector3(1, 0, 0))

	var horizontal := Vector3(bot.velocity.x, 0.0, bot.velocity.z)
	assert_gt(horizontal.length(), 1.0, "the bot is moving")
	assert_gt(horizontal.normalized().dot(Vector3(1, 0, 0)), 0.9, "and moving toward +X")


## Nobody may move outside a running round, and the round-over check in
## GameManager._process fires the moment the clock reads zero -- so a test that
## wants a character to walk has to put time on the clock.
func _begin_round() -> void:
	GameManager.state = GameManager.State.SEEKING
	GameManager.time_left = 999.0


func _walk(bot: CharacterBody3D, travel: Vector3, frames: int = 30) -> void:
	for frame in frames:
		bot.apply_ai_input(Vector2(travel.x, travel.z), false)
		await get_tree().physics_frame
