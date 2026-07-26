extends CharacterBody3D

## Works for both human-controlled and AI-controlled (bot) players.
## Human input is only processed on the owning client (client-authoritative
## movement); the server drives bots directly via AIController.

const SPEED := 5.0
const JUMP_VELOCITY := 4.5
const GRAVITY := 9.8
const MOUSE_SENSITIVITY := 0.0025

const PALETTE := [
	Color(1.0, 0.62, 0.8),  # bubblegum pink
	Color(0.6, 0.85, 1.0),  # sky blue
	Color(1.0, 0.85, 0.4),  # sunshine yellow
	Color(0.65, 0.9, 0.55), # mint green
	Color(0.85, 0.65, 1.0), # lilac
]
const HUNTER_COLOR := Color(1.0, 0.35, 0.3)

var player_id: int = 0
var player_name: String = "Player"
var is_bot: bool = false
var is_tagged: bool = false

var input_dir: Vector2 = Vector2.ZERO
var wants_jump: bool = false

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var name_label: Label3D = $NameLabel
@onready var ai_controller: Node = $AIController

var _material: StandardMaterial3D
var _idle_tween: Tween


func _ready() -> void:
	name_label.text = player_name

	_material = StandardMaterial3D.new()
	_material.albedo_color = PALETTE[abs(player_id) % PALETTE.size()]
	body_mesh.material_override = _material

	if is_bot:
		camera.current = false
		ai_controller.activate(self)
	else:
		ai_controller.set_physics_process(false)
		if is_multiplayer_authority():
			camera.current = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			camera.current = false

	set_process_unhandled_input(not is_bot and is_multiplayer_authority())

	GameManager.state_changed.connect(_on_game_state_changed)
	GameManager.player_tagged.connect(_on_player_tagged_signal)

	_start_idle_squish()


func _on_game_state_changed(new_state: int) -> void:
	var am_hunter := player_id == GameManager.hunter_id
	_material.albedo_color = HUNTER_COLOR if am_hunter else PALETTE[abs(player_id) % PALETTE.size()]

	if new_state == GameManager.State.HIDING:
		is_tagged = false
		modulate_visibility(true)
		if is_multiplayer_authority():
			global_position = _spawn_position()
			velocity = Vector3.ZERO


func _on_player_tagged_signal(id: int) -> void:
	if id != player_id:
		return
	is_tagged = true
	modulate_visibility(false)
	_squish_pulse(0.4, 0.3)


func modulate_visibility(visible_and_solid: bool) -> void:
	body_mesh.transparency = 0.0 if visible_and_solid else 0.75
	set_collision_layer_value(1, visible_and_solid)


func _spawn_position() -> Vector3:
	var offset := Vector3(randf_range(-2.5, 2.5), 1.0, randf_range(-2.5, 2.5))
	return Vector3(0, 1, 9) + offset


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clamp(spring_arm.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.2, 0.6)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if is_tagged:
		return
	if not is_bot and is_multiplayer_authority():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		wants_jump = Input.is_action_just_pressed("jump")
	if not is_multiplayer_authority():
		return
	_move(delta)


func _move(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0
		if wants_jump:
			velocity.y = JUMP_VELOCITY
			_squish_pulse(1.35, 0.18)
	wants_jump = false

	var direction: Vector3
	if is_bot:
		direction = Vector3(input_dir.x, 0.0, input_dir.y)
	else:
		direction = camera_pivot.global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	direction.y = 0.0

	if direction.length_squared() > 0.001:
		direction = direction.normalized()
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
		var target_yaw := atan2(direction.x, direction.z)
		body_mesh.rotation.y = lerp_angle(body_mesh.rotation.y, target_yaw, 10.0 * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED * delta * 8.0)
		velocity.z = move_toward(velocity.z, 0.0, SPEED * delta * 8.0)

	move_and_slide()


func apply_ai_input(direction: Vector2, jump: bool) -> void:
	input_dir = direction
	wants_jump = jump


func _start_idle_squish() -> void:
	_idle_tween = create_tween().set_loops()
	_idle_tween.tween_property(body_mesh, "scale", Vector3(1.05, 0.92, 1.05), 0.9).set_trans(Tween.TRANS_SINE)
	_idle_tween.tween_property(body_mesh, "scale", Vector3(0.95, 1.08, 0.95), 0.9).set_trans(Tween.TRANS_SINE)


func _squish_pulse(stretch: float, duration: float) -> void:
	var squash := 1.0 - (stretch - 1.0)
	var tween := create_tween()
	tween.tween_property(body_mesh, "scale", Vector3(squash, stretch, squash), duration * 0.4).set_trans(Tween.TRANS_BACK)
	tween.tween_property(body_mesh, "scale", Vector3.ONE, duration * 0.6).set_trans(Tween.TRANS_ELASTIC)
