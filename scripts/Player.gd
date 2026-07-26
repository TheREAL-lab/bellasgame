extends CharacterBody3D

## Shared by human and AI players. Humans drive their own body (the owning peer
## has multiplayer authority); bots are driven by the server via AIController.

const WALK_SPEED := 5.2
const HUNTER_SPEED := 5.9        # the Hunter is slightly faster, so chases resolve
const ACCEL := 45.0
const FRICTION := 30.0
const AIR_CONTROL := 0.35
const JUMP_VELOCITY := 5.2
const GRAVITY := 16.0            # snappier than real gravity: less floaty, more toy-like
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.12
const MOUSE_SENSITIVITY := 0.0022

const PALETTE := [
	Color(1.0, 0.55, 0.78),  # bubblegum
	Color(0.45, 0.8, 1.0),   # sky
	Color(1.0, 0.83, 0.35),  # sunshine
	Color(0.55, 0.9, 0.55),  # mint
	Color(0.78, 0.6, 1.0),   # lilac
	Color(1.0, 0.66, 0.42),  # peach
]
const HUNTER_COLOR := Color(1.0, 0.36, 0.32)

var player_id: int = 0
var player_name: String = "Player"
var is_bot: bool = false
var is_tagged: bool = false

var input_dir: Vector2 = Vector2.ZERO
var wants_jump: bool = false

var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _was_grounded: bool = true

@onready var visual: Node3D = $Visual
@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var name_label: Label3D = $NameLabel
@onready var ai_controller: Node = $AIController
@onready var poof: GPUParticles3D = $Poof


func _ready() -> void:
	NetworkManager.register_player(self)
	name_label.text = player_name
	spring_arm.rotation.x = -0.30    # start looking slightly down at the character
	visual.set_base_color(_my_color())

	if is_bot:
		camera.current = false
		ai_controller.activate(self)
	else:
		ai_controller.set_physics_process(false)
		if is_multiplayer_authority():
			camera.current = true
			name_label.visible = false      # don't stare at your own nameplate
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			camera.current = false

	set_process_unhandled_input(not is_bot and is_multiplayer_authority())

	GameManager.state_changed.connect(_on_game_state_changed)
	GameManager.player_tagged.connect(_on_player_tagged)


func _exit_tree() -> void:
	NetworkManager.unregister_player(self)


func _my_color() -> Color:
	return PALETTE[abs(player_id) % PALETTE.size()]


func is_hunter() -> bool:
	return player_id == GameManager.hunter_id


func _on_game_state_changed(new_state: int) -> void:
	var hunter := is_hunter()
	visual.set_base_color(HUNTER_COLOR if hunter else _my_color())
	visual.set_hunter_glow(hunter)

	_update_name_visibility()

	if new_state == GameManager.State.HIDING:
		is_tagged = false
		visual.set_ghost(false)
		set_collision_layer_value(1, true)
		if is_multiplayer_authority():
			global_position = GameManager.spawn_point_for(player_id)
			velocity = Vector3.ZERO
			visual.pop(0.5)


func _on_player_tagged(id: int) -> void:
	if id != player_id:
		return
	is_tagged = true
	visual.set_ghost(true)
	visual.pop(-0.6)
	set_collision_layer_value(1, false)
	poof.restart()
	poof.emitting = true
	_update_name_visibility()


## Hiders go nameless once the search starts -- otherwise a floating nameplate
## gives away every hiding spot. The Hunter stays labelled so kids can see
## who is IT at a glance.
func _update_name_visibility() -> void:
	if not is_bot and is_multiplayer_authority():
		name_label.visible = false
		return
	if GameManager.state == GameManager.State.SEEKING and not is_hunter() and not is_tagged:
		name_label.visible = false
	else:
		name_label.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clamp(
			spring_arm.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.1, 0.55)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	if not is_bot and is_multiplayer_authority():
		if _can_move():
			input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			if Input.is_action_just_pressed("jump"):
				_jump_buffer = JUMP_BUFFER
		else:
			input_dir = Vector2.ZERO

	if is_multiplayer_authority():
		_move(delta)

	# Visuals run on every peer so remote players animate too.
	var speed_ratio: float = clamp(Vector2(velocity.x, velocity.z).length() / WALK_SPEED, 0.0, 1.0)
	visual.animate(delta, speed_ratio, is_on_floor())

	if is_hunter() and not is_tagged:
		var prey := GameManager.nearest_hider_to(global_position)
		if prey != null:
			visual.look_at_point(prey.global_position + Vector3.UP, delta)


## Nobody moves before the round starts, and the Hunter is frozen while the
## hiders scatter -- that waiting is the whole ritual of hide and seek.
func _can_move() -> bool:
	if is_tagged:
		return false
	match GameManager.state:
		GameManager.State.HIDING:
			return not is_hunter()
		GameManager.State.SEEKING:
			return true
		_:
			return false


func _move(delta: float) -> void:
	var grounded := is_on_floor()

	if grounded:
		_coyote = COYOTE_TIME
		if not _was_grounded:
			visual.pop(-0.45)          # landing splat
	else:
		_coyote = max(0.0, _coyote - delta)
		velocity.y -= GRAVITY * delta

	_jump_buffer = max(0.0, _jump_buffer - delta)
	if is_bot and wants_jump:
		_jump_buffer = JUMP_BUFFER
	wants_jump = false

	if _jump_buffer > 0.0 and _coyote > 0.0 and _can_move():
		velocity.y = JUMP_VELOCITY
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

	var speed := HUNTER_SPEED if is_hunter() else WALK_SPEED
	var control := 1.0 if grounded else AIR_CONTROL
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if direction.length_squared() > 0.001:
		direction = direction.normalized()
		horizontal = horizontal.move_toward(direction * speed, ACCEL * control * delta)
		var target_yaw := atan2(direction.x, direction.z)
		visual.rotation.y = lerp_angle(visual.rotation.y, target_yaw, 12.0 * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, FRICTION * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	_was_grounded = grounded
	move_and_slide()


func apply_ai_input(direction: Vector2, jump: bool) -> void:
	input_dir = Vector2.ZERO if not _can_move() else direction
	wants_jump = jump
