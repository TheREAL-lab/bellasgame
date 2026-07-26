extends Node

## Drives a bot Player: server-only. Hiders path to a random hiding spot and
## sit tight; the Hunter patrols hiding spots and chases the nearest visible hider.

const CHASE_RANGE := 18.0
const REPATH_INTERVAL := 3.0
const CHASE_REPATH_INTERVAL := 0.4

var parent: CharacterBody3D
var nav_agent: NavigationAgent3D
var _repath_timer: float = 0.0


func activate(p: CharacterBody3D) -> void:
	parent = p
	nav_agent = parent.get_node("NavigationAgent3D")
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if parent == null or parent.is_tagged:
		return
	if GameManager.state == GameManager.State.LOBBY or GameManager.state == GameManager.State.ROUND_OVER:
		parent.apply_ai_input(Vector2.ZERO, false)
		return

	_repath_timer -= delta
	var am_hunter: bool = parent.player_id == GameManager.hunter_id

	if GameManager.state == GameManager.State.HIDING:
		if am_hunter:
			parent.apply_ai_input(Vector2.ZERO, false)
			return
		if _repath_timer <= 0.0:
			nav_agent.target_position = _random_spot_position()
			_repath_timer = REPATH_INTERVAL
	elif GameManager.state == GameManager.State.SEEKING:
		if am_hunter:
			if _repath_timer <= 0.0:
				_pick_chase_or_patrol_target()
				_repath_timer = CHASE_REPATH_INTERVAL
		else:
			if _repath_timer <= 0.0 and nav_agent.is_navigation_finished():
				nav_agent.target_position = _random_spot_position()
				_repath_timer = REPATH_INTERVAL

	_follow_path()


func _pick_chase_or_patrol_target() -> void:
	var nearest := _find_nearest_hider()
	if nearest != null:
		nav_agent.target_position = nearest.global_position
	elif nav_agent.is_navigation_finished():
		nav_agent.target_position = _random_spot_position()


func _find_nearest_hider() -> Node3D:
	var best: Node3D = null
	var best_dist := CHASE_RANGE
	for id in NetworkManager.players.keys():
		if id == parent.player_id:
			continue
		if GameManager.tagged.get(id, false):
			continue
		var node: Node3D = NetworkManager.players[id]
		if node == null or not is_instance_valid(node):
			continue
		var d := parent.global_position.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


func _random_spot_position() -> Vector3:
	var arena = get_tree().get_first_node_in_group("arena_root")
	if arena == null or arena.hiding_spots.is_empty():
		return parent.global_position
	return arena.hiding_spots[randi() % arena.hiding_spots.size()]


func _follow_path() -> void:
	if nav_agent.is_navigation_finished():
		parent.apply_ai_input(Vector2.ZERO, false)
		return
	var next_pos := nav_agent.get_next_path_position()
	var to_next := next_pos - parent.global_position
	to_next.y = 0.0
	if to_next.length() < 0.05:
		parent.apply_ai_input(Vector2.ZERO, false)
		return
	var dir := to_next.normalized()
	parent.apply_ai_input(Vector2(dir.x, dir.z), false)
