extends Node

## Server-authoritative round/role state machine, replicated to all peers via RPC.

enum State { LOBBY, HIDING, SEEKING, ROUND_OVER }
enum Role { NONE, HIDER, HUNTER }

const HIDE_TIME := 8.0
const SEEK_TIME := 90.0
const TAG_RADIUS := 1.5

signal state_changed(new_state: int)
signal player_tagged(id: int)
signal round_finished(hunter_won: bool)

var state: int = State.LOBBY
var hunter_id: int = 0
var hider_ids: Array = []
var tagged: Dictionary = {} # id -> bool
var time_left: float = 0.0
var my_role: int = Role.NONE

var _known_players: Array = [] # server-side only: every id (human + bot)


func on_player_added(id: int, _is_bot: bool) -> void:
	if not multiplayer.is_server():
		return
	if not _known_players.has(id):
		_known_players.append(id)


func on_player_removed(id: int) -> void:
	if not multiplayer.is_server():
		return
	_known_players.erase(id)


func start_round() -> void:
	if not multiplayer.is_server():
		return
	if state == State.HIDING or state == State.SEEKING:
		return
	if _known_players.size() < 2:
		return
	var new_hunter: int = _known_players[randi() % _known_players.size()]
	var hiders: Array = _known_players.filter(func(id): return id != new_hunter)
	_broadcast_state.rpc(State.HIDING, new_hunter, hiders, HIDE_TIME)
	await get_tree().create_timer(HIDE_TIME).timeout
	if not multiplayer.is_server() or state != State.HIDING:
		return
	_broadcast_state.rpc(State.SEEKING, new_hunter, hiders, SEEK_TIME)


@rpc("authority", "call_local", "reliable")
func _broadcast_state(new_state: int, h_id: int, hiders: Array, duration: float) -> void:
	state = new_state
	hunter_id = h_id
	hider_ids = hiders
	time_left = duration
	if new_state == State.HIDING:
		tagged.clear()
	var my_id := multiplayer.get_unique_id()
	if my_id == h_id:
		my_role = Role.HUNTER
	elif hiders.has(my_id):
		my_role = Role.HIDER
	else:
		my_role = Role.NONE
	state_changed.emit(new_state)


func _process(delta: float) -> void:
	if state == State.HIDING or state == State.SEEKING:
		time_left = max(0.0, time_left - delta)
	if not multiplayer.is_server():
		return
	if state == State.SEEKING:
		_check_tags()
		if time_left <= 0.0:
			_finish_round(false)


func _check_tags() -> void:
	var hunter_node = NetworkManager.players.get(hunter_id)
	if hunter_node == null or not is_instance_valid(hunter_node):
		return
	var everyone_tagged := true
	for id in hider_ids:
		if tagged.get(id, false):
			continue
		var hider_node = NetworkManager.players.get(id)
		if hider_node == null or not is_instance_valid(hider_node):
			continue
		if hunter_node.global_position.distance_to(hider_node.global_position) <= TAG_RADIUS:
			tagged[id] = true
			_notify_tag.rpc(id)
		else:
			everyone_tagged = false
	if everyone_tagged and hider_ids.size() > 0:
		_finish_round(true)


@rpc("authority", "call_local", "reliable")
func _notify_tag(id: int) -> void:
	tagged[id] = true
	player_tagged.emit(id)


func _finish_round(hunter_won: bool) -> void:
	if not multiplayer.is_server():
		return
	_announce_round_over.rpc(hunter_won)


@rpc("authority", "call_local", "reliable")
func _announce_round_over(hunter_won: bool) -> void:
	state = State.ROUND_OVER
	state_changed.emit(State.ROUND_OVER)
	round_finished.emit(hunter_won)
