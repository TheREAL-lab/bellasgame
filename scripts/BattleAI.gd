extends Node

## Server-only bot brain: loot something, find somebody, fight them, and don't
## drown in the storm. Replaces the old hide-and-seek controller.
##
## The shape of this file is dictated by there being a hundred of them. Anything
## expensive -- searching for targets, line-of-sight rays, asking the navigation
## server for a new path -- happens on a staggered "think" tick, never every
## frame. Per frame each bot does little more than steer along the path it
## already has.

enum Mood { LOOT, HUNT, FIGHT, FLEE, RETREAT }

const SIGHT_RANGE := 20.0
## Below this share of health a squishy would rather be somewhere else. Bots that
## run away when hurt are the single biggest reason a match lasts minutes rather
## than seconds -- without it every fight ran to a knockout.
const RETREAT_HEALTH := 0.35
const SIGHT_ANGLE := deg_to_rad(80.0)
## Close enough that a bot will drop what it is doing and fight back. Above this
## and a bot still on its foam bonker would rather go and find a real weapon.
const PROVOKE_RANGE := 11.0
const THINK_INTERVAL := 0.28
const REPATH_MIN := 0.5
const STORM_MARGIN := 8.0
const LOOT_INTEREST := 45.0      # how far a bot will walk for a weapon
const MELEE_CLOSE := 2.2
const STRAFE_RANGE := 12.0       # inside this a shooter sidesteps instead of charging

var parent: CharacterBody3D
var nav_agent: NavigationAgent3D

var mood: int = Mood.LOOT
var _think_timer: float = 0.0
var _repath_timer: float = 0.0
var _jump_cooldown: float = 0.0
var _target: Node3D = null
var _target_seen_at: float = 0.0
var _strafe_dir: float = 1.0

var _boldness: float = 0.5       # how willing this bot is to pick a fight
var _accuracy: float = 0.5       # how badly it sprays
var _jumpiness: float = 0.3
var _reaction: float = 0.3


func activate(p: CharacterBody3D) -> void:
	parent = p
	nav_agent = parent.get_node("NavigationAgent3D")
	_boldness = randf_range(0.2, 0.95)
	_accuracy = randf_range(0.35, 0.92)
	_jumpiness = randf_range(0.05, 0.4)
	_reaction = randf_range(0.12, 0.5)
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	# Spread the first think across the interval so a hundred bots never all
	# reason on the same frame.
	_think_timer = randf() * THINK_INTERVAL
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or parent == null:
		return
	if parent.is_down or MatchManager.state != MatchManager.State.PLAYING:
		parent.apply_ai_input(Vector2.ZERO, false)
		return

	_jump_cooldown -= delta
	_think_timer -= delta
	_repath_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL * randf_range(0.85, 1.15)
		_think()

	_act(delta)


## The expensive half: decide what this bot is doing and where it is going.
func _think() -> void:
	var here := parent.global_position

	# Nothing else matters if the wall is coming for you.
	var outside := MatchManager.distance_outside(here)
	if outside > -STORM_MARGIN:
		mood = Mood.FLEE
		_go_to(MatchManager.safe_point_near(here, STORM_MARGIN * 1.5))
		return

	_refresh_target()

	if _target != null:
		var threat: float = here.distance_to(_target.global_position)

		# Hurt squishies leg it. Bold ones hold their ground a little longer.
		if parent.health < parent.max_health * RETREAT_HEALTH * (1.0 + _boldness * 0.4):
			mood = Mood.RETREAT
			var away: Vector3 = (here - _target.global_position).normalized()
			_go_to(MatchManager.safe_point_near(here + away * 26.0, STORM_MARGIN))
			return

		# Right on top of you is a fight whether you wanted one or not.
		if threat <= PROVOKE_RANGE:
			mood = Mood.FIGHT
			return

		# Otherwise it depends who you are. A bot still holding the foam bonker
		# goes shopping instead, and a timid one keeps out of it -- between them
		# these two rules are what stopped every match opening with a hundred
		# squishies sprinting into one brawl.
		if parent.weapon.tier == 0 or _boldness < 0.55:
			var escape := _nearest_loot(here)
			if escape != Vector3.ZERO:
				mood = Mood.LOOT
				_go_to(escape)
				return
			mood = Mood.HUNT
			_go_to(_wander_target(here))
			return

		mood = Mood.FIGHT
		return

	if parent.weapon.tier == 0 or not parent.has_hat:
		var spot := _nearest_loot(here)
		if spot != Vector3.ZERO and here.distance_to(spot) < LOOT_INTEREST:
			mood = Mood.LOOT
			_go_to(spot)
			return

	mood = Mood.HUNT
	var prey := MatchManager.nearest_alive_to(here, parent.player_id)
	if prey != null and _boldness > 0.3:
		_go_to(prey.global_position)
	else:
		_go_to(_wander_target(here))


## The cheap half: steer along the current path, and shoot if there is something
## to shoot at.
func _act(delta: float) -> void:
	if mood == Mood.FIGHT and _target != null and is_instance_valid(_target) \
			and not _target.is_down:
		_fight(delta)
		return
	_follow_path()


func _fight(delta: float) -> void:
	var here := parent.global_position
	var to_target: Vector3 = _target.global_position - here
	var dist := to_target.length()
	var flat := Vector3(to_target.x, 0.0, to_target.z).normalized()

	# Eyes follow whoever you are fighting. Costs nothing, reads as intent.
	parent.visual.look_at_point(_target.global_position + Vector3.UP, delta)

	var is_melee: bool = parent.weapon.kind == Weapons.Kind.MELEE
	var want_range: float = MELEE_CLOSE if is_melee else minf(parent.weapon.reach * 0.6, STRAFE_RANGE)

	var move := Vector2.ZERO
	if dist > want_range * 1.15:
		move = Vector2(flat.x, flat.z)                       # close in
	elif dist < want_range * 0.6 and not is_melee:
		move = Vector2(-flat.x, -flat.z)                     # back off
	else:
		# Sidestep, so a firefight is not two squishies standing still.
		var side := flat.cross(Vector3.UP) * _strafe_dir
		move = Vector2(side.x, side.z)

	var jump := false
	if _jump_cooldown <= 0.0 and randf() < _jumpiness * 0.04:
		jump = true
		_jump_cooldown = randf_range(0.8, 2.5)

	parent.apply_ai_input(move, jump)

	# Aim at the chest, with an error that shrinks as the bot gets better and
	# grows with distance -- so a far-off bot is a threat, not a sniper.
	if dist <= parent.weapon.reach:
		var miss: float = (1.0 - _accuracy) * 0.09
		var aim: Vector3 = (_target.global_position + Vector3.UP * 0.6
			- parent.aim_origin()).normalized()
		aim += Vector3(randf_range(-miss, miss), randf_range(-miss, miss) * 0.5,
			randf_range(-miss, miss))
		parent.try_attack(aim.normalized())


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
	# Bots wearing a hat hold jump while airborne, so they hover over things
	# instead of thumping into them.
	parent.apply_ai_input(Vector2(dir.x, dir.z), jump, parent.has_hat)


## Repathing is rate limited: asking the navigation server for a fresh path a
## hundred times a frame is the single easiest way to kill the frame rate.
func _go_to(target: Vector3) -> void:
	if _repath_timer > 0.0:
		return
	_repath_timer = REPATH_MIN
	nav_agent.target_position = target


func _refresh_target() -> void:
	if _target != null and (not is_instance_valid(_target) or _target.is_down):
		_target = null

	var found := _find_visible_enemy()
	if found != null:
		_target = found
		_target_seen_at = float(Time.get_ticks_msec()) / 1000.0
		return

	# Keep chasing for a moment after losing sight, so breaking line of sight is
	# an escape rather than an off switch.
	var now := float(Time.get_ticks_msec()) / 1000.0
	if _target != null and now - _target_seen_at > 2.5 + _boldness * 2.0:
		_target = null


func _find_visible_enemy() -> Node3D:
	var here := parent.global_position
	var best: Node3D = null
	var best_dist := SIGHT_RANGE
	for id in MatchManager.alive.keys():
		if id == parent.player_id:
			continue
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node) or node.is_down:
			continue
		var d: float = here.distance_to(node.global_position)
		if d >= best_dist:
			continue
		if not _can_see(node):
			continue
		best_dist = d
		best = node
	return best


## Inside the vision cone and not blocked by scenery. The raycast mask is 1 only,
## so props break line of sight but other squishies never do -- ducking behind a
## mushroom works, hiding behind a friend does not.
func _can_see(target: Node3D) -> bool:
	var from: Vector3 = parent.aim_origin()
	var to: Vector3 = target.global_position + Vector3.UP * 0.6
	var offset: Vector3 = to - from

	var facing: Vector3 = -parent.visual.global_transform.basis.z
	facing.y = 0.0
	var flat := Vector3(offset.x, 0.0, offset.z)
	if facing.length_squared() > 0.001 and flat.length_squared() > 0.001:
		if facing.normalized().angle_to(flat.normalized()) > SIGHT_ANGLE:
			return false

	var space := parent.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude = [parent.get_rid(), target.get_rid()]
	return space.intersect_ray(query).is_empty()


func _nearest_loot(from: Vector3) -> Vector3:
	var loot = get_tree().get_first_node_in_group("loot")
	if loot == null:
		return Vector3.ZERO
	var index: int = loot.nearest_index(from, LOOT_INTEREST)
	if index < 0:
		return Vector3.ZERO
	return loot.items[index].pos


func _wander_target(from: Vector3) -> Vector3:
	var island = get_tree().get_first_node_in_group("arena_root")
	if island == null or island.landmarks.is_empty():
		return from
	var spot: Vector3 = island.landmarks[randi() % island.landmarks.size()]
	# Never wander somewhere the storm already owns.
	return MatchManager.safe_point_near(spot, STORM_MARGIN)
