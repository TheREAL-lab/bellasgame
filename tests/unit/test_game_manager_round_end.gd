extends "res://tests/test_case.gd"

## GameManager's server-authoritative round logic: tagging, who wins, scoring,
## and role rotation.
##
## No networking is needed. Godot reports is_server() == true and unique id 1
## when no multiplayer peer is set, and `call_local` RPCs run locally, so the
## whole server path is reachable in-process.

const FakePlayer := preload("res://tests/helpers/fake_player.gd")
const FakeArena := preload("res://tests/helpers/fake_arena.gd")

const HUNTER := 1
const HIDER_A := -1
const HIDER_B := -2

var _finish_calls: Array = []      # each entry is the hunter_won flag
var _tag_events: Array = []        # each entry is a tagged id


func before_each() -> void:
	_reset_singletons()
	_finish_calls = []
	_tag_events = []
	GameManager.round_finished.connect(_on_round_finished)
	GameManager.player_tagged.connect(_on_player_tagged)


func after_each() -> void:
	GameManager.round_finished.disconnect(_on_round_finished)
	GameManager.player_tagged.disconnect(_on_player_tagged)
	_reset_singletons()


func _on_round_finished(hunter_won: bool) -> void:
	_finish_calls.append(hunter_won)


func _on_player_tagged(id: int) -> void:
	_tag_events.append(id)


## GameManager and NetworkManager are autoloads that outlive every test, so wipe
## them back to a lobby-fresh state on both sides of each one.
func _reset_singletons() -> void:
	GameManager.state = GameManager.State.LOBBY
	GameManager.hunter_id = 0
	GameManager.hider_ids = []
	GameManager.tagged = {}
	GameManager.scores = {}
	GameManager.time_left = 0.0
	GameManager.my_role = GameManager.Role.NONE
	GameManager.round_number = 0
	GameManager._known_players = []
	GameManager._last_hunter = 0
	NetworkManager.players.clear()
	NetworkManager.player_names.clear()
	NetworkManager.local_player = null


func _spawn(id: int, position: Vector3) -> CharacterBody3D:
	var node := FakePlayer.make(id, position)
	add_child(track(node))
	NetworkManager.players[id] = node
	return node


## Put the game into the seeking phase with a hunter and a set of hiders.
## `hiders` maps player id -> world position.
func _begin_seeking(hunter_position: Vector3, hiders: Dictionary) -> void:
	_spawn(HUNTER, hunter_position)
	for id in hiders:
		_spawn(id, hiders[id])
	GameManager.hunter_id = HUNTER
	GameManager.hider_ids = hiders.keys()
	GameManager.state = GameManager.State.SEEKING
	GameManager.time_left = 30.0


## Simulate a peer dropping out: the node goes away and NetworkManager forgets
## it, exactly as _on_peer_disconnected does.
func _disconnect_player(id: int) -> void:
	var node: Node = NetworkManager.players.get(id)
	NetworkManager.players.erase(id)
	if node != null and is_instance_valid(node):
		_tracked.erase(node)
		remove_child(node)
		node.free()
	GameManager.on_player_removed(id)


# --- tagging ------------------------------------------------------------

func test_a_hider_inside_the_tag_radius_is_caught() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 1.0), HIDER_B: Vector3(0, 0, 9.0)})

	GameManager._check_tags()

	assert_true(GameManager.tagged.get(HIDER_A, false), "hider 1.0m away")
	assert_false(GameManager.tagged.get(HIDER_B, false), "hider 9.0m away")
	assert_eq(_tag_events, [HIDER_A], "tag was announced once, for the near hider")


func test_a_hider_outside_the_tag_radius_is_left_alone() -> void:
	# TAG_RADIUS is 1.6m.
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 1.7)})

	GameManager._check_tags()

	assert_false(GameManager.tagged.get(HIDER_A, false), "hider 1.7m away")
	assert_eq(_tag_events, [], "nothing announced")


func test_catching_the_last_hider_ends_the_round() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 1.0)})

	GameManager._check_tags()

	assert_eq(_finish_calls, [true], "round ended once, hunter won")
	assert_eq(GameManager.state, GameManager.State.ROUND_OVER)


func test_nearest_hider_to_skips_players_already_caught() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 3.0), HIDER_B: Vector3(0, 0, 8.0)})
	GameManager.tagged[HIDER_A] = true

	var prey := GameManager.nearest_hider_to(Vector3.ZERO)

	assert_not_null(prey)
	assert_eq(prey.player_id, HIDER_B, "the closer hider is already out")


# --- scoring ------------------------------------------------------------

func test_a_hunter_win_awards_the_hunter_one_point() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 9.0), HIDER_B: Vector3(0, 0, 9.0)})
	GameManager.tagged[HIDER_A] = true
	GameManager.tagged[HIDER_B] = true

	GameManager._finish_round(true)

	assert_eq(GameManager.scores.get(HUNTER, 0), 1, "hunter")
	assert_eq(GameManager.scores.get(HIDER_A, 0), 0, "caught hider")


func test_running_out_of_time_awards_every_hider_who_survived() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 9.0), HIDER_B: Vector3(0, 0, 9.0)})
	GameManager.tagged[HIDER_A] = true

	GameManager._finish_round(false)

	assert_eq(_finish_calls, [false], "hiders won")
	assert_eq(GameManager.scores.get(HIDER_B, 0), 1, "hider who stayed hidden")
	assert_eq(GameManager.scores.get(HIDER_A, 0), 0, "hider who was caught")
	assert_eq(GameManager.scores.get(HUNTER, 0), 0, "hunter")


# --- starting a round ---------------------------------------------------

func test_the_same_player_is_not_it_twice_in_a_row() -> void:
	GameManager._known_players = [HUNTER, HIDER_A, HIDER_B]

	# start_round() suspends on a HIDE_TIME timer, but it picks the hunter and
	# broadcasts before that, so calling it without awaiting is enough.
	var previous := 0
	for round_index in 6:
		GameManager.state = GameManager.State.LOBBY
		GameManager.start_round()
		assert_ne(GameManager.hunter_id, previous, "round %d" % (round_index + 1))
		assert_false(GameManager.hider_ids.has(GameManager.hunter_id),
			"the hunter is not also listed as a hider")
		previous = GameManager.hunter_id


func test_a_round_needs_at_least_two_players() -> void:
	GameManager._known_players = [HUNTER]

	GameManager.start_round()

	assert_eq(GameManager.state, GameManager.State.LOBBY, "still waiting in the lobby")


func test_starting_a_round_is_ignored_while_one_is_running() -> void:
	GameManager._known_players = [HUNTER, HIDER_A]
	GameManager.state = GameManager.State.SEEKING
	GameManager.round_number = 5

	GameManager.start_round()

	assert_eq(GameManager.round_number, 5, "no second round started on top")


# --- the HUD's danger hint ----------------------------------------------

func test_danger_peaks_when_the_hunter_is_on_top_of_you() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3.ZERO})
	GameManager.my_role = GameManager.Role.HIDER
	NetworkManager.local_player = NetworkManager.players[HIDER_A]

	assert_almost_eq(GameManager.local_player_danger(), 1.0)


func test_danger_is_zero_beyond_the_warning_range() -> void:
	# CLOSE_WARNING_RANGE is 7.0m.
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 8.0)})
	GameManager.my_role = GameManager.Role.HIDER
	NetworkManager.local_player = NetworkManager.players[HIDER_A]

	assert_almost_eq(GameManager.local_player_danger(), 0.0)


func test_danger_is_zero_once_you_are_caught() -> void:
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3.ZERO})
	GameManager.my_role = GameManager.Role.HIDER
	NetworkManager.local_player = NetworkManager.players[HIDER_A]
	NetworkManager.local_player.is_tagged = true

	assert_almost_eq(GameManager.local_player_danger(), 0.0)


# --- known bugs ---------------------------------------------------------
# These document defects found while writing the suite. They are expected to
# fail; when a fix lands, the runner reports XPASS and fails the build so the
# expect_failure() line gets removed with it.

func test_hiders_remaining_ignores_players_who_left_the_game() -> void:
	expect_failure("hiders_remaining() counts ids whose player node is gone, "
		+ "so the HUD keeps saying someone is still hiding after they quit")
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 9.0), HIDER_B: Vector3(0, 0, 9.0)})

	_disconnect_player(HIDER_B)

	assert_eq(GameManager.hiders_remaining(), 1, "only one hider is still playing")


func test_the_round_does_not_end_when_every_hider_disconnects() -> void:
	expect_failure("_check_tags() counts a missing node as 'not remaining', so "
		+ "the hunter is declared the winner without tagging anybody")
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 9.0), HIDER_B: Vector3(0, 0, 9.0)})

	_disconnect_player(HIDER_A)
	_disconnect_player(HIDER_B)
	GameManager._check_tags()

	assert_eq(_finish_calls, [], "nobody was caught, so nobody won")


func test_the_round_is_announced_once_when_the_last_tag_lands_on_the_final_tick() -> void:
	expect_failure("_process() runs _check_tags() and the timeout check in the "
		+ "same frame with no guard, so both endings fire and the scoreboard "
		+ "shows the loser")
	_begin_seeking(Vector3.ZERO, {HIDER_A: Vector3(0, 0, 1.0)})
	GameManager.time_left = 0.0

	GameManager._process(0.0)

	assert_eq(_finish_calls, [true], "one ending, and it is the hunter's win")


func test_spawn_point_for_an_unknown_id_does_not_reuse_a_hider_spawn() -> void:
	expect_failure("maxi(hider_ids.find(id), 0) turns 'not found' into index 0, "
		+ "so a stray id spawns on top of the first hider")
	add_child(track(FakeArena.new()))
	GameManager.hunter_id = HUNTER
	GameManager.hider_ids = [HIDER_A, HIDER_B]

	var first_hider_spawn := GameManager.spawn_point_for(HIDER_A)
	var stranger_spawn := GameManager.spawn_point_for(9999)

	assert_ne(stranger_spawn, first_hider_spawn, "two players sent to one spawn point")
