extends Node

## AUTOLOAD. Server-authoritative battle royale: who is alive, who knocked out
## whom, where the storm is, and who won. The server owns every decision here;
## clients are told the results and render them.
##
## The storm deliberately carries no per-frame replication. Every peer is given
## the phase's start circle, end circle and duration once, and then works out the
## radius itself from the phase clock -- so a hundred bots running from a wall
## costs nothing on the wire.

enum State { LOBBY, PLAYING, MATCH_OVER }

const MAX_HEALTH := 140.0
const DROP_HEIGHT := 15.0

## wait = how long the current circle holds, shrink = how long the wall takes to
## close, radius = what it closes to, dps = what it costs you to be outside.
## Runs about three and a half minutes end to end.
const PHASES := [
	{"wait": 35.0, "shrink": 35.0, "radius": 95.0, "dps": 2.0},
	{"wait": 25.0, "shrink": 30.0, "radius": 62.0, "dps": 4.0},
	{"wait": 20.0, "shrink": 25.0, "radius": 38.0, "dps": 7.0},
	{"wait": 16.0, "shrink": 20.0, "radius": 20.0, "dps": 11.0},
	{"wait": 14.0, "shrink": 16.0, "radius": 7.0, "dps": 16.0},
]

signal state_changed(new_state: int)
signal alive_changed
signal player_eliminated(id: int, by_id: int)
signal storm_phase_changed
signal match_finished(winner_id: int)

var state: int = State.LOBBY
var alive: Dictionary = {}            # id -> true while still standing
var placements: Dictionary = {}       # id -> finishing position (1 is the win)
var knockouts: Dictionary = {}        # id -> how many they knocked out
var total_players: int = 0
var winner_id: int = 0

var storm_center: Vector3 = Vector3.ZERO
var storm_radius: float = 999.0
var storm_dps: float = 0.0
var phase_index: int = -1
var phase_time_left: float = 0.0
var closing: bool = false             # true while the wall is actually moving

var _from_center: Vector3 = Vector3.ZERO
var _from_radius: float = 999.0
var _to_center: Vector3 = Vector3.ZERO
var _to_radius: float = 999.0
var _phase_duration: float = 1.0
var _known_players: Array = []
var _damage_accum: float = 0.0

## Scales how far away a squishy still animates. The performance guard in Main
## winds this down when frames get expensive; nothing else should touch it.
var detail_scale: float = 1.0


func on_player_added(id: int, _is_bot: bool) -> void:
	if not multiplayer.is_server():
		return
	if not _known_players.has(id):
		_known_players.append(id)


func on_player_removed(id: int) -> void:
	if not multiplayer.is_server():
		return
	_known_players.erase(id)
	if alive.has(id):
		alive.erase(id)
		alive_changed.emit()


func start_match() -> void:
	if not multiplayer.is_server():
		return
	if state == State.PLAYING:
		return
	if _known_players.size() < 2:
		return

	var roster := _known_players.duplicate()
	_begin.rpc(roster)

	# First circle covers the whole island, so the opening minute is about
	# finding a weapon rather than running.
	var island = get_tree().get_first_node_in_group("arena_root")
	var start_radius: float = island.ISLAND_RADIUS if island != null else 100.0
	_set_phase.rpc(-1, Vector3.ZERO, start_radius, Vector3.ZERO, start_radius,
		PHASES[0].wait, 0.0, false)


@rpc("authority", "call_local", "reliable")
func _begin(roster: Array) -> void:
	state = State.PLAYING
	alive.clear()
	placements.clear()
	knockouts.clear()
	winner_id = 0
	for id in roster:
		alive[id] = true
		knockouts[id] = 0
	total_players = roster.size()
	state_changed.emit(state)
	alive_changed.emit()


func alive_count() -> int:
	return alive.size()


func is_alive(id: int) -> bool:
	return alive.get(id, false)


## Called by Player on the server when someone's health runs out. Placement is
## simply how many were still standing at that moment, which is what a battle
## royale means by "you came 7th".
func register_elimination(id: int, by_id: int) -> void:
	if not multiplayer.is_server():
		return
	if not alive.get(id, false):
		return
	var placement := alive.size()
	if by_id != id and knockouts.has(by_id):
		knockouts[by_id] = int(knockouts.get(by_id, 0)) + 1
	_confirm_elimination.rpc(id, by_id, placement, knockouts.get(by_id, 0))

	if alive.size() <= 1:
		var last := 0
		for other in alive.keys():
			last = other
		_finish.rpc(last, knockouts)


@rpc("authority", "call_local", "reliable")
func _confirm_elimination(id: int, by_id: int, placement: int, killer_kos: int) -> void:
	alive.erase(id)
	placements[id] = placement
	if by_id != id:
		knockouts[by_id] = killer_kos
	player_eliminated.emit(id, by_id)
	alive_changed.emit()


@rpc("authority", "call_local", "reliable")
func _finish(winner: int, final_knockouts: Dictionary) -> void:
	state = State.MATCH_OVER
	winner_id = winner
	knockouts = final_knockouts
	if winner != 0:
		placements[winner] = 1
	state_changed.emit(state)
	match_finished.emit(winner)


## Every peer gets the same two circles and the same clock, and interpolates.
@rpc("authority", "call_local", "reliable")
func _set_phase(index: int, from_c: Vector3, from_r: float, to_c: Vector3, to_r: float,
		duration: float, dps: float, is_closing: bool) -> void:
	phase_index = index
	_from_center = from_c
	_from_radius = from_r
	_to_center = to_c
	_to_radius = to_r
	_phase_duration = maxf(duration, 0.01)
	phase_time_left = duration
	storm_dps = dps
	closing = is_closing
	storm_center = from_c
	storm_radius = from_r
	storm_phase_changed.emit()


func _process(delta: float) -> void:
	if state != State.PLAYING:
		return

	# Interpolating on every peer keeps the wall in the same place for everyone
	# without a single packet per frame.
	if phase_time_left > 0.0:
		phase_time_left = maxf(0.0, phase_time_left - delta)
	var t: float = 1.0 - (phase_time_left / _phase_duration)
	if closing:
		storm_center = _from_center.lerp(_to_center, t)
		storm_radius = lerpf(_from_radius, _to_radius, t)
	else:
		storm_center = _from_center
		storm_radius = _from_radius

	if not multiplayer.is_server():
		return

	_apply_storm_damage(delta)
	if phase_time_left <= 0.0:
		_advance_phase()


## Ticked rather than applied every frame: a hundred players each taking a
## sixtieth of a point of damage is a lot of RPC traffic for no visible gain.
func _apply_storm_damage(delta: float) -> void:
	if storm_dps <= 0.0:
		return
	_damage_accum += delta
	if _damage_accum < 0.5:
		return
	var tick := _damage_accum
	_damage_accum = 0.0

	var flat_center := Vector2(storm_center.x, storm_center.z)
	for id in alive.keys():
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var flat_pos := Vector2(node.global_position.x, node.global_position.z)
		if flat_pos.distance_to(flat_center) > storm_radius:
			node.take_damage(storm_dps * tick, 0)


func _advance_phase() -> void:
	var next := phase_index + 1
	if closing:
		# The wall just finished moving; hold here for a breath before the next.
		if next >= PHASES.size():
			_set_phase.rpc(next, storm_center, storm_radius, storm_center, storm_radius,
				9999.0, PHASES[PHASES.size() - 1].dps, false)
			return
		# Hold at the circle we just closed to, and keep charging the rate that
		# circle set -- the next phase's harsher rate starts when it starts.
		var holding_dps: float = PHASES[phase_index].dps if phase_index >= 0 else 0.0
		_set_phase.rpc(phase_index, storm_center, storm_radius, storm_center, storm_radius,
			PHASES[next].wait, holding_dps, false)
		return

	if next >= PHASES.size():
		_set_phase.rpc(next, storm_center, storm_radius, storm_center, storm_radius,
			9999.0, PHASES[PHASES.size() - 1].dps, false)
		return

	var phase: Dictionary = PHASES[next]
	var new_center := _pick_next_center(float(phase.radius))
	_set_phase.rpc(next, storm_center, storm_radius, new_center, float(phase.radius),
		float(phase.shrink), float(phase.dps), true)


## The next circle is placed at random but always fits inside the current one, so
## running for the middle is never wrong -- only slow.
func _pick_next_center(next_radius: float) -> Vector3:
	var slack: float = maxf(0.0, storm_radius - next_radius)
	var angle := randf() * TAU
	var dist := sqrt(randf()) * slack
	return storm_center + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)


## Where the wall is heading, for the HUD and the ground marker.
func next_center() -> Vector3:
	return _to_center


func next_radius() -> float:
	return _to_radius


func distance_outside(pos: Vector3) -> float:
	var flat := Vector2(pos.x - storm_center.x, pos.z - storm_center.z)
	return flat.length() - storm_radius


## Somewhere safe to run to, for bots and for the HUD arrow. Aims a little inside
## the edge rather than dead centre, so bots do not all pile onto one point.
func safe_point_near(pos: Vector3, margin: float = 6.0) -> Vector3:
	var flat := Vector3(pos.x - storm_center.x, 0.0, pos.z - storm_center.z)
	var usable: float = maxf(storm_radius - margin, 1.0)
	if flat.length() <= usable:
		return pos
	return storm_center + flat.normalized() * usable


func spawn_point_for(id: int) -> Vector3:
	var island = get_tree().get_first_node_in_group("arena_root")
	if island == null or island.spawn_points.is_empty():
		return Vector3(0, DROP_HEIGHT, 0)
	var index: int = _known_players.find(id)
	if index < 0:
		index = absi(id)
	var point: Vector3 = island.spawn_points[index % island.spawn_points.size()]
	return Vector3(point.x, DROP_HEIGHT, point.z)


## The nearest living player to a point, ignoring one id (usually the asker).
func nearest_alive_to(origin: Vector3, except_id: int, max_range: float = INF) -> Node3D:
	var best: Node3D = null
	var best_dist := max_range
	for id in alive.keys():
		if id == except_id:
			continue
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var d: float = origin.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


func placement_of(id: int) -> int:
	return int(placements.get(id, alive.size()))


func knockouts_of(id: int) -> int:
	return int(knockouts.get(id, 0))
