class_name Player
extends CharacterBody3D

## Shared by you and by all hundred bots. Humans drive their own body (the owning
## peer has multiplayer authority); bots are driven by the server via BattleAI.
##
## Damage is always decided by the server, never by the shooter's machine, so a
## laggy peer cannot knock anybody out on its own say-so.

const WALK_SPEED := 5.6
const ACCEL := 45.0
const FRICTION := 30.0
const AIR_CONTROL := 0.35
const JUMP_VELOCITY := 5.2
const GRAVITY := 16.0            # snappier than real gravity: less floaty, more toy-like
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.12
const MOUSE_SENSITIVITY := 0.0022

## Spinny hat. Not flight -- a propeller that holds you up while it has puff in
## it, and lets you drift down gently when it hasn't.
const HAT_JUMP_BONUS := 1.18
const HOVER_RISE := 3.4          # how fast the propeller lifts you
const HOVER_ACCEL := 26.0
const HOVER_CHARGE := 2.6        # seconds of propeller per landing
const HOVER_REGEN := 1.4         # seconds of charge earned per second on the ground
const GLIDE_GRAVITY := 0.42      # share of gravity while wearing a hat and falling

const PICKUP_REACH := 2.6
const LOD_DISTANCE := 45.0       # past this, bots stop animating
const LOD_INTERVAL := 0.25

const PALETTE := [
	Color(1.0, 0.55, 0.78),  # bubblegum
	Color(0.45, 0.8, 1.0),   # sky
	Color(1.0, 0.83, 0.35),  # sunshine
	Color(0.55, 0.9, 0.55),  # mint
	Color(0.78, 0.6, 1.0),   # lilac
	Color(1.0, 0.66, 0.42),  # peach
]

var player_id: int = 0
var player_name: String = "Player"
var is_bot: bool = false
var is_down: bool = false
var slot: int = -1               # cosmetic slot, handed out by the server at spawn
var species_override: int = -1   # what the shop picked, or -1 to use the slot
var color_override: int = -1
## Perks ride along in the spawn data rather than being read from SaveData here.
## SaveData is *this machine's* wallet, so asking it about somebody else's player
## would hand every squishy on screen the local player's upgrades.
var perks: Array = []

var health: float = 100.0
var max_health: float = 100.0
var weapon: Dictionary = {}
var has_hat: bool = false
var hover_left: float = 0.0
var coins_found: int = 0

var input_dir: Vector2 = Vector2.ZERO
var wants_jump: bool = false
var holding_jump: bool = false
var aim_dir: Vector3 = Vector3.FORWARD

var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _was_grounded: bool = true
var _attack_cd: float = 0.0
var _lod_timer: float = 0.0
var _far_away: bool = false

@onready var visual: Node3D = $Visual
@onready var camera_pivot: Node3D = $CameraPivot
@onready var name_label: Label3D = $NameLabel
@onready var ai_controller: Node = $BattleAI
@onready var poof: GPUParticles3D = $Poof


func _ready() -> void:
	NetworkManager.register_player(self)

	max_health = MatchManager.MAX_HEALTH
	if perks.has("sturdy"):
		max_health += 20.0
	health = max_health
	weapon = Weapons.by_id(_starting_weapon_id())

	visual.build(_species_index(), _my_color())
	visual.hold(Weapons.build_model(weapon))
	name_label.text = player_name

	_take_lobby_position()

	if is_bot:
		# A hundred spring arms doing shape casts every frame is the single most
		# expensive thing a bot can own, and it never looks through its camera.
		camera_pivot.queue_free()
		ai_controller.activate(self)
	else:
		ai_controller.set_physics_process(false)
		var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
		if is_multiplayer_authority():
			camera.current = true
			name_label.visible = false      # don't stare at your own nameplate
			$CameraPivot/SpringArm3D.rotation.x = -0.30
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			camera.current = false

	set_process_unhandled_input(not is_bot and is_multiplayer_authority())
	MatchManager.state_changed.connect(_on_match_state_changed)


func _exit_tree() -> void:
	NetworkManager.unregister_player(self)


## Species and colour repeat every six slots, but the colour shifts a step each
## time it wraps, so even a full lobby never contains two identical squishies.
func _my_color() -> Color:
	if color_override >= 0:
		return PALETTE[color_override % PALETTE.size()]
	var s := _slot()
	return PALETTE[(s + s / PALETTE.size()) % PALETTE.size()]


func _species_index() -> int:
	if species_override >= 0:
		return species_override
	return _slot() % 6


## Slots come from NetworkManager so appearance doesn't depend on the peer id,
## which is arbitrary for anyone who joins. The fallback only matters when a
## Player is run outside the spawner, e.g. opening Player.tscn in the editor.
func _slot() -> int:
	if slot >= 0:
		return slot
	return player_id - 1 if player_id > 0 else 1 - player_id


func _take_lobby_position() -> void:
	if not is_multiplayer_authority():
		return
	var island = get_tree().get_first_node_in_group("arena_root")
	if island == null or island.spawn_points.is_empty():
		return
	var spawns: Array = island.spawn_points
	global_position = spawns[_slot() % spawns.size()]


## The Better Bonker perk is the only thing that changes what you land holding.
func _starting_weapon_id() -> String:
	return "lolly" if perks.has("sharp") else Weapons.STARTING_ID


func _on_match_state_changed(new_state: int) -> void:
	if new_state != MatchManager.State.PLAYING:
		return
	# Everyone drops in fresh: full health, starting bonker, no hat.
	is_down = false
	health = max_health
	has_hat = false
	hover_left = 0.0
	coins_found = 0
	visual.set_ghost(false)
	visual.set_hat(false)
	set_collision_layer_value(2, true)
	if multiplayer.is_server():
		equip(_starting_weapon_id())
	if is_multiplayer_authority():
		global_position = MatchManager.spawn_point_for(player_id)
		velocity = Vector3.ZERO
		visual.pop(0.4)


# --- kit -------------------------------------------------------------------

func equip(weapon_id: String) -> void:
	if multiplayer.is_server():
		_set_weapon.rpc(weapon_id)
	else:
		_set_weapon(weapon_id)


@rpc("authority", "call_local", "reliable")
func _set_weapon(weapon_id: String) -> void:
	weapon = Weapons.by_id(weapon_id)
	visual.hold(Weapons.build_model(weapon))


func give_hat() -> void:
	if multiplayer.is_server():
		_set_hat.rpc(true)


@rpc("authority", "call_local", "reliable")
func _set_hat(on: bool) -> void:
	has_hat = on
	visual.set_hat(on)
	if on:
		hover_left = hover_capacity()


## How much propeller a landing gives you back. Public because the HUD draws it.
func hover_capacity() -> float:
	return HOVER_CHARGE * (1.5 if perks.has("whirl") else 1.0)


func collect_coins(amount: int) -> void:
	if multiplayer.is_server():
		_add_coins.rpc(amount)


@rpc("authority", "call_local", "reliable")
func _add_coins(amount: int) -> void:
	coins_found += amount


# --- damage ----------------------------------------------------------------

## Server only. Everything that can hurt somebody funnels through here so there
## is exactly one place that decides whether a squishy is still standing.
func take_damage(amount: float, from_id: int) -> void:
	if not multiplayer.is_server():
		return
	if is_down or MatchManager.state != MatchManager.State.PLAYING:
		return
	health = maxf(0.0, health - amount)
	_flash_hit.rpc(from_id)
	if not is_bot:
		_sync_health.rpc(health)
	if health <= 0.0:
		_go_down(from_id)


@rpc("authority", "call_local", "unreliable")
func _flash_hit(_from_id: int) -> void:
	visual.flash_hit()


@rpc("authority", "call_local", "reliable")
func _sync_health(value: float) -> void:
	health = value


func _go_down(by_id: int) -> void:
	# Drop what you were carrying so whoever got you can pick it up -- that swap
	# is most of the reason to fight somebody rather than run away.
	var loot = get_tree().get_first_node_in_group("loot")
	if loot != null:
		var here := global_position + Vector3.UP * 0.4
		if weapon.tier > 0:
			loot.drop.rpc("weapon", weapon.id, 0, here)
		if has_hat:
			loot.drop.rpc("hat", "", 0, here + Vector3(0.9, 0, 0))
		if coins_found > 0:
			loot.drop.rpc("coins", "", coins_found, here + Vector3(-0.9, 0, 0))
	_fall_over.rpc(by_id)
	MatchManager.register_elimination(player_id, by_id)


@rpc("authority", "call_local", "reliable")
func _fall_over(_by_id: int) -> void:
	is_down = true
	health = 0.0
	velocity = Vector3.ZERO
	visual.set_ghost(true)
	visual.set_hat(false)
	visual.hold(null)
	visual.pop(-0.7)
	set_collision_layer_value(2, false)     # ghosts don't body-block the living
	poof.restart()
	poof.emitting = true
	name_label.visible = false


# --- attacking -------------------------------------------------------------

func aim_origin() -> Vector3:
	return global_position + Vector3.UP * 0.95


## Called by you through input, and by BattleAI for bots. Returns false when the
## weapon is still cooling down, which is what stops a bot machine-gunning a
## lollipop hammer.
func try_attack(direction: Vector3) -> bool:
	if _attack_cd > 0.0 or is_down or not _can_move():
		return false
	_attack_cd = float(weapon.cooldown)
	aim_dir = direction.normalized()
	if multiplayer.is_server():
		_resolve_attack(aim_dir)
	else:
		_request_attack.rpc_id(1, aim_dir)
	return true


@rpc("any_peer", "reliable")
func _request_attack(direction: Vector3) -> void:
	if not multiplayer.is_server():
		return
	# Only the peer that owns this body may swing it.
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	if is_down or MatchManager.state != MatchManager.State.PLAYING:
		return
	_resolve_attack(direction.normalized())


func _resolve_attack(direction: Vector3) -> void:
	if weapon.kind == Weapons.Kind.MELEE:
		_resolve_melee(direction)
	else:
		_resolve_ranged(direction)


## Melee is a forgiving cone rather than a ray. Missing a swing because a hitbox
## was two centimetres off is not fun for anybody, least of all a beginner.
func _resolve_melee(direction: Vector3) -> void:
	var reach: float = weapon.reach
	var origin := aim_origin()
	for id in MatchManager.alive.keys():
		if id == player_id:
			continue
		var other = NetworkManager.players.get(id)
		if other == null or not is_instance_valid(other) or other.is_down:
			continue
		var offset: Vector3 = other.global_position + Vector3.UP * 0.6 - origin
		if offset.length() > reach:
			continue
		if direction.angle_to(offset.normalized()) > 0.9:      # about 50 degrees
			continue
		other.take_damage(float(weapon.damage), player_id)
	_show_swing.rpc(origin, direction, reach)


func _resolve_ranged(direction: Vector3) -> void:
	var origin := aim_origin()
	var reach: float = weapon.reach
	var spread: float = weapon.spread
	var space := get_world_3d().direct_space_state
	var ends := PackedVector3Array()

	for pellet in int(weapon.pellets):
		var dir := direction
		if spread > 0.0:
			dir = (direction + Vector3(
				randf_range(-spread, spread), randf_range(-spread, spread),
				randf_range(-spread, spread))).normalized()
		var to := origin + dir * reach
		var query := PhysicsRayQueryParameters3D.create(origin, to)
		query.collision_mask = 1 | 2        # scenery blocks shots, players take them
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			ends.append(to)
			continue
		ends.append(hit.position)
		var body = hit.collider
		if body != null and body.has_method("take_damage") and not body.is_down:
			body.take_damage(float(weapon.damage), player_id)

	_show_shot.rpc(origin, ends, weapon.color)


@rpc("authority", "call_local", "unreliable")
func _show_swing(origin: Vector3, direction: Vector3, reach: float) -> void:
	visual.swing()
	if _too_far_to_bother(origin):
		return
	_tracer(origin, origin + direction * reach * 0.7, weapon.color, 0.09, 0.09)


@rpc("authority", "call_local", "unreliable")
func _show_shot(origin: Vector3, ends: PackedVector3Array, color: Color) -> void:
	visual.recoil()
	if _too_far_to_bother(origin):
		return
	for end in ends:
		_tracer(origin, end, color, 0.05, 0.07)


## A hundred bots trading shots across an island is a lot of tracers nobody can
## see. Anything happening far from your eyes skips its visuals entirely.
func _too_far_to_bother(origin: Vector3) -> bool:
	var me = NetworkManager.local_player
	if me == null or not is_instance_valid(me):
		return true
	return me.global_position.distance_to(origin) > 55.0


func _tracer(from: Vector3, to: Vector3, color: Color, thickness: float, life: float) -> void:
	var length := from.distance_to(to)
	if length < 0.05:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, length)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mi)
	mi.global_position = (from + to) * 0.5
	mi.look_at(to, Vector3.UP)

	var tween := mi.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, life)
	tween.tween_callback(mi.queue_free)


# --- input and movement ----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		var arm: SpringArm3D = $CameraPivot/SpringArm3D
		arm.rotation.x = clamp(arm.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.1, 0.55)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	_attack_cd = maxf(0.0, _attack_cd - delta)

	if not is_bot and is_multiplayer_authority():
		_read_input()

	if is_multiplayer_authority():
		_move(delta)

	_update_lod(delta)
	if not _far_away:
		var speed_ratio: float = clamp(
			Vector2(velocity.x, velocity.z).length() / WALK_SPEED, 0.0, 1.0)
		visual.animate(delta, speed_ratio, is_on_floor())


func _read_input() -> void:
	if not _can_move():
		input_dir = Vector2.ZERO
		holding_jump = false
		return
	input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	holding_jump = Input.is_action_pressed("jump")
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = JUMP_BUFFER
	if Input.is_action_pressed("attack"):
		try_attack(_look_dir())
	if Input.is_action_just_pressed("pickup"):
		_grab_nearest()


## Aim straight out of the camera. In third person that is a small lie about
## where the muzzle is, but it is the direction you are looking at, which is the
## direction you meant.
func _look_dir() -> Vector3:
	var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
	return -camera.global_transform.basis.z


## Explicit pickup, for when you actually do want the shotgun over the rifle.
func _grab_nearest() -> void:
	var loot = get_tree().get_first_node_in_group("loot")
	if loot == null:
		return
	var index: int = loot.nearest_index(global_position, PICKUP_REACH)
	if index < 0:
		return
	if multiplayer.is_server():
		loot.take(index, player_id)
	else:
		_request_pickup.rpc_id(1, index)


@rpc("any_peer", "reliable")
func _request_pickup(index: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	var loot = get_tree().get_first_node_in_group("loot")
	if loot != null:
		loot.take(index, player_id)


## Nobody moves before the match starts or after they are out. Being down still
## leaves you in the world as a ghost so you can watch how it finishes.
func _can_move() -> bool:
	if is_down:
		return false
	return MatchManager.state == MatchManager.State.PLAYING


func _move(delta: float) -> void:
	var grounded := is_on_floor()

	if grounded:
		_coyote = COYOTE_TIME
		if not _was_grounded:
			visual.pop(-0.45)          # landing splat
		if has_hat:
			hover_left = minf(hover_capacity(), hover_left + HOVER_REGEN * delta)
	else:
		_coyote = maxf(0.0, _coyote - delta)
		_apply_air(delta)

	_jump_buffer = maxf(0.0, _jump_buffer - delta)
	if is_bot and wants_jump:
		_jump_buffer = JUMP_BUFFER
	wants_jump = false

	if _jump_buffer > 0.0 and _coyote > 0.0 and _can_move():
		velocity.y = JUMP_VELOCITY * (HAT_JUMP_BONUS if has_hat else 1.0)
		_jump_buffer = 0.0
		_coyote = 0.0
		visual.pop(0.55)               # stretch tall off the ground
	elif grounded and velocity.y < 0.0:
		velocity.y = 0.0

	var direction: Vector3
	if is_bot:
		direction = Vector3(input_dir.x, 0.0, input_dir.y)
	else:
		direction = camera_pivot.global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	direction.y = 0.0

	var control := 1.0 if grounded else AIR_CONTROL
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if direction.length_squared() > 0.001:
		direction = direction.normalized()
		horizontal = horizontal.move_toward(direction * WALK_SPEED, ACCEL * control * delta)
		var target_yaw := atan2(direction.x, direction.z)
		visual.rotation.y = lerp_angle(visual.rotation.y, target_yaw, 12.0 * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, FRICTION * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	_was_grounded = grounded
	move_and_slide()


## The spinny hat, in three lines: hold jump and the propeller pulls you up while
## it has charge; let go and you drift instead of drop. Never quite flying.
func _apply_air(delta: float) -> void:
	if has_hat and holding_jump and hover_left > 0.0:
		hover_left = maxf(0.0, hover_left - delta)
		velocity.y = move_toward(velocity.y, HOVER_RISE, HOVER_ACCEL * delta)
		visual.spin_propeller(delta, 26.0)
		return
	if has_hat and velocity.y < 0.0:
		velocity.y -= GRAVITY * GLIDE_GRAVITY * delta
		visual.spin_propeller(delta, 9.0)
		return
	velocity.y -= GRAVITY * delta


## Bots far from your eyes skip their animation entirely. The mesh detail itself
## is dropped by the engine through visibility ranges, so this only has to deal
## with the per-frame maths.
func _update_lod(delta: float) -> void:
	if not is_bot:
		return
	_lod_timer -= delta
	if _lod_timer > 0.0:
		return
	_lod_timer = LOD_INTERVAL
	var me = NetworkManager.local_player
	if me == null or not is_instance_valid(me):
		_far_away = false
		return
	var dist := global_position.distance_to(me.global_position)
	_far_away = dist > LOD_DISTANCE * MatchManager.detail_scale
	name_label.visible = not is_down and dist < 22.0


func apply_ai_input(direction: Vector2, jump: bool, hold: bool = false) -> void:
	input_dir = Vector2.ZERO if not _can_move() else direction
	wants_jump = jump
	holding_jump = hold
