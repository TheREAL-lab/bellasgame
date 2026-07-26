extends Node

## Server-authoritative round flow, replicated to every peer over RPC.
## The server owns all timing and tag decisions; clients only render the result.

enum State { LOBBY, HIDING, SEEKING, ROUND_OVER }
enum Role { NONE, HIDER, HUNTER }

const HIDE_TIME := 10.0
const SEEK_TIME := 90.0
const TAG_RADIUS := 1.6
const CLOSE_WARNING_RANGE := 7.0

signal state_changed(new_state: int)
signal player_tagged(id: int)
signal round_finished(hunter_won: bool)
signal scores_changed

var state: int = State.LOBBY
var hunter_id: int = 0
var hider_ids: Array = []
var tagged: Dictionary = {}          # id -> true once caught
var scores: Dictionary = {}          # id -> rounds won
var time_left: float = 0.0
var my_role: int = Role.NONE
var round_number: int = 0

var _known_players: Array = []       # server-side roster (humans + bots)
var _last_hunter: int = 0


func on_player_added(id: int, _is_bot: bool) -> void:
	if not multiplayer.is_server():
		return
	if not _known_players.has(id):
		_known_players.append(id)
	if not scores.has(id):
		scores[id] = 0


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

	# Avoid handing the same player the Hunter role twice in a row when we can.
	var candidates: Array = _known_players.filter(func(id): return id != _last_hunter)
	if candidates.is_empty():
		candidates = _known_players.duplicate()
	var new_hunter: int = candidates[randi() % candidates.size()]
	_last_hunter = new_hunter

	var hiders: Array = _known_players.filter(func(id): return id != new_hunter)
	round_number += 1

	_broadcast_state.rpc(State.HIDING, new_hunter, hiders, HIDE_TIME, round_number)
	await get_tree().create_timer(HIDE_TIME).timeout
	if not multiplayer.is_server() or state != State.HIDING:
		return
	_broadcast_state.rpc(State.SEEKING, new_hunter, hiders, SEEK_TIME, round_number)


@rpc("authority", "call_local", "reliable")
func _broadcast_state(new_state: int, h_id: int, hiders: Array, duration: float, round_no: int) -> void:
	state = new_state
	hunter_id = h_id
	hider_ids = hiders
	time_left = duration
	round_number = round_no
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
	var remaining := 0
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
			remaining += 1
	if remaining == 0 and hider_ids.size() > 0:
		_finish_round(true)


@rpc("authority", "call_local", "reliable")
func _notify_tag(id: int) -> void:
	tagged[id] = true
	player_tagged.emit(id)


func _finish_round(hunter_won: bool) -> void:
	if not multiplayer.is_server():
		return
	if hunter_won:
		scores[hunter_id] = scores.get(hunter_id, 0) + 1
	else:
		for id in hider_ids:
			if not tagged.get(id, false):
				scores[id] = scores.get(id, 0) + 1
	_announce_round_over.rpc(hunter_won, scores)


@rpc("authority", "call_local", "reliable")
func _announce_round_over(hunter_won: bool, new_scores: Dictionary) -> void:
	state = State.ROUND_OVER
	scores = new_scores
	scores_changed.emit()
	state_changed.emit(State.ROUND_OVER)
	round_finished.emit(hunter_won)


## Deterministic spawn placement so every peer agrees where players start:
## the Hunter in the middle, hiders spread evenly around the outside.
func spawn_point_for(id: int) -> Vector3:
	var arena = get_tree().get_first_node_in_group("arena_root")
	if arena == null:
		return Vector3(0, 1, 0)
	if id == hunter_id:
		return arena.hunter_spawn
	var index: int = maxi(hider_ids.find(id), 0)
	var spawns: Array = arena.hider_spawns
	if spawns.is_empty():
		return Vector3(0, 1, 0)
	return spawns[index % spawns.size()]


func nearest_hider_to(origin: Vector3) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for id in hider_ids:
		if tagged.get(id, false):
			continue
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var d: float = origin.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


func hiders_remaining() -> int:
	var count := 0
	for id in hider_ids:
		if not tagged.get(id, false):
			count += 1
	return count


## How close the Hunter is to the local player, for the "getting warmer" HUD hint.
func local_player_danger() -> float:
	if my_role != Role.HIDER or state != State.SEEKING:
		return 0.0
	var me = NetworkManager.local_player
	var hunter = NetworkManager.players.get(hunter_id)
	if me == null or hunter == null or not is_instance_valid(me) or not is_instance_valid(hunter):
		return 0.0
	if me.is_tagged:
		return 0.0
	var d: float = me.global_position.distance_to(hunter.global_position)
	return clamp(1.0 - (d / CLOSE_WARNING_RANGE), 0.0, 1.0)
