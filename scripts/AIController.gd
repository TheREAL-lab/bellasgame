extends Node

## Server-only bot brain. Bots hide behind props when they're Hiders, and
## sweep the arena then chase on sight when they're the Hunter.
## Each bot gets a small random personality so the three don't move as a block.

const SIGHT_RANGE := 14.0
const SIGHT_ANGLE := deg_to_rad(75.0)
const REPATH_HIDE := 2.5
const REPATH_PATROL := 1.0
const REPATH_CHASE := 0.3
const PANIC_RANGE := 5.0

var parent: CharacterBody3D
var nav_agent: NavigationAgent3D

var _repath_timer: float = 0.0
var _reaction_delay: float = 0.0
var _boldness: float = 0.5       # how far from cover this bot is willing to roam
var _jumpiness: float = 0.3      # chance of a happy little hop while moving
var _jump_cooldown: float = 0.0
var _chasing: Node3D = null


func activate(p: CharacterBody3D) -> void:
	parent = p
	nav_agent = parent.get_node("NavigationAgent3D")
	_boldness = randf_range(0.25, 0.9)
	_jumpiness = randf_range(0.1, 0.5)
	_reaction_delay = randf_range(0.15, 0.6)
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or parent == null:
		return
	if parent.is_tagged or GameManager.state == GameManager.State.LOBBY \
			or GameManager.state == GameManager.State.ROUND_OVER:
		parent.apply_ai_input(Vector2.ZERO, false)
		return

	# IT stands still and counts while everyone scatters.
	if parent.is_hunter() and GameManager.state == GameManager.State.HIDING:
		parent.apply_ai_input(Vector2.ZERO, false)
		return

	_repath_timer -= delta
	_jump_cooldown -= delta

	if parent.is_hunter():
		_act_as_hunter(delta)
	else:
		_act_as_hider(delta)

	_follow_path()


func _act_as_hunter(delta: float) -> void:
	var visible_prey := _find_visible_hider()
	if visible_prey != null:
		# Small reaction delay so the bot doesn't feel robotically instant.
		_reaction_delay -= delta
		if _reaction_delay <= 0.0:
			_chasing = visible_prey
	else:
		_reaction_delay = randf_range(0.15, 0.6)
		if _chasing != null and not _can_see(_chasing):
			_chasing = null

	if _chasing != null and is_instance_valid(_chasing) \
			and not GameManager.tagged.get(_chasing.player_id, false):
		if _repath_timer <= 0.0:
			nav_agent.target_position = _chasing.global_position
			_repath_timer = REPATH_CHASE
	elif _repath_timer <= 0.0 or nav_agent.is_navigation_finished():
		nav_agent.target_position = _search_target()
		_repath_timer = REPATH_PATROL


func _act_as_hider(_delta: float) -> void:
	var hunter = NetworkManager.players.get(GameManager.hunter_id)
	var threatened := false
	if hunter != null and is_instance_valid(hunter) \
			and GameManager.state == GameManager.State.SEEKING:
		var dist: float = parent.global_position.distance_to(hunter.global_position)
		threatened = dist < PANIC_RANGE

	if threatened:
		# Bolt for cover on the far side of the arena from the Hunter.
		if _repath_timer <= 0.0:
			nav_agent.target_position = _flee_target(hunter.global_position)
			_repath_timer = REPATH_CHASE
	elif _repath_timer <= 0.0 and nav_agent.is_navigation_finished():
		nav_agent.target_position = _cover_target()
		_repath_timer = REPATH_HIDE


func _cover_target() -> Vector3:
	var arena = get_tree().get_first_node_in_group("arena_root")
	if arena == null or arena.hiding_spots.is_empty():
		return parent.global_position
	var spots: Array = arena.hiding_spots
	# Bolder bots pick a spot anywhere; timid ones stick to the nearest few.
	if randf() < _boldness:
		return spots[randi() % spots.size()]
	var best: Vector3 = spots[0]
	var best_d := INF
	for spot in spots:
		var d: float = parent.global_position.distance_to(spot)
		if d > 1.0 and d < best_d:
			best_d = d
			best = spot
	return best


func _flee_target(threat: Vector3) -> Vector3:
	var arena = get_tree().get_first_node_in_group("arena_root")
	if arena == null or arena.hiding_spots.is_empty():
		return parent.global_position
	var best: Vector3 = arena.hiding_spots[0]
	var best_score := -INF
	for spot in arena.hiding_spots:
		# Prefer cover that is far from the Hunter but not far from us.
		var score: float = spot.distance_to(threat) - parent.global_position.distance_to(spot) * 0.5
		if score > best_score:
			best_score = score
			best = spot
	return best


func _search_target() -> Vector3:
	var arena = get_tree().get_first_node_in_group("arena_root")
	if arena == null or arena.hiding_spots.is_empty():
		return parent.global_position
	# Sweep toward cover the Hunter isn't standing next to already.
	var spots: Array = arena.hiding_spots
	var candidate: Vector3 = spots[randi() % spots.size()]
	if parent.global_position.distance_to(candidate) < 3.0:
		candidate = spots[randi() % spots.size()]
	return candidate


func _find_visible_hider() -> Node3D:
	var best: Node3D = null
	var best_dist := SIGHT_RANGE
	for id in GameManager.hider_ids:
		if GameManager.tagged.get(id, false):
			continue
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var d: float = parent.global_position.distance_to(node.global_position)
		if d < best_dist and _can_see(node):
			best_dist = d
			best = node
	return best


## Line of sight: inside the vision cone and not blocked by a prop.
func _can_see(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	var from := parent.global_position + Vector3.UP * 0.6
	var to := target.global_position + Vector3.UP * 0.6
	var offset := to - from
	if offset.length() > SIGHT_RANGE:
		return false

	var facing: Vector3 = -parent.visual.global_transform.basis.z
	facing.y = 0.0
	var flat := Vector3(offset.x, 0.0, offset.z)
	if facing.length_squared() > 0.001 and flat.length_squared() > 0.001:
		if facing.normalized().angle_to(flat.normalized()) > SIGHT_ANGLE:
			return false

	var space := parent.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1     # only scenery blocks sight, never other players
	query.exclude = [parent.get_rid(), target.get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty()


func _follow_path() -> void:
	if nav_agent.is_navigation_finished():
		parent.apply_ai_input(Vector2.ZERO, false)
		return
	var next_pos := nav_agent.get_next_path_position()
	var to_next := next_pos - parent.global_position
	to_next.y = 0.0
	if to_next.length() < 0.1:
		parent.apply_ai_input(Vector2.ZERO, false)
		return

	var dir := to_next.normalized()
	var jump := false
	if _jump_cooldown <= 0.0 and randf() < _jumpiness * 0.01:
		jump = true
		_jump_cooldown = randf_range(1.5, 4.0)
	parent.apply_ai_input(Vector2(dir.x, dir.z), jump)
