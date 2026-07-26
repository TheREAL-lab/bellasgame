extends Node3D

## Builds and animates the squishy blob character out of primitives, so the
## whole look can be tuned from code without any imported art assets.

const EYE_WHITE := Color(1, 1, 1)
const PUPIL := Color(0.13, 0.1, 0.16)
const BLUSH := Color(1.0, 0.55, 0.65)

var body: MeshInstance3D
var eye_left: Node3D
var eye_right: Node3D
var ears: Array[MeshInstance3D] = []
var feet: Array[MeshInstance3D] = []

var _body_mat: StandardMaterial3D
var _base_color: Color = Color.WHITE
var _walk_phase: float = 0.0
var _blink_t: float = 0.0
var _squash: float = 1.0       # >1 = stretched tall, <1 = squashed flat
var _squash_vel: float = 0.0
var _is_ghost: bool = false


func _ready() -> void:
	_build()


func _build() -> void:
	_body_mat = StandardMaterial3D.new()
	_body_mat.roughness = 0.35
	_body_mat.rim_enabled = true
	_body_mat.rim = 0.6
	_body_mat.rim_tint = 0.4

	body = MeshInstance3D.new()
	var body_mesh := SphereMesh.new()
	body_mesh.radius = 0.45
	body_mesh.height = 0.9
	body_mesh.radial_segments = 32
	body_mesh.rings = 16
	body.mesh = body_mesh
	body.material_override = _body_mat
	body.position.y = 0.45
	add_child(body)

	# Ears: two little rounded nubs that flop as the character moves.
	for side in [-1.0, 1.0]:
		var ear := MeshInstance3D.new()
		var ear_mesh := SphereMesh.new()
		ear_mesh.radius = 0.14
		ear_mesh.height = 0.34
		ear.mesh = ear_mesh
		ear.material_override = _body_mat
		ear.position = Vector3(0.22 * side, 0.42, 0.0)
		ear.rotation.z = -0.35 * side
		body.add_child(ear)
		ears.append(ear)

	# Feet: little flattened blobs that bob while walking.
	for side in [-1.0, 1.0]:
		var foot := MeshInstance3D.new()
		var foot_mesh := SphereMesh.new()
		foot_mesh.radius = 0.15
		foot_mesh.height = 0.18
		foot.mesh = foot_mesh
		foot.material_override = _body_mat
		foot.position = Vector3(0.2 * side, -0.4, -0.05)
		body.add_child(foot)
		feet.append(foot)

	eye_left = _make_eye(-0.16)
	eye_right = _make_eye(0.16)
	_make_blush(-0.3)
	_make_blush(0.3)


func _make_eye(x_offset: float) -> Node3D:
	var holder := Node3D.new()
	holder.position = Vector3(x_offset, 0.1, -0.36)
	body.add_child(holder)

	var white := MeshInstance3D.new()
	var white_mesh := SphereMesh.new()
	white_mesh.radius = 0.115
	white_mesh.height = 0.23
	white.mesh = white_mesh
	var white_mat := StandardMaterial3D.new()
	white_mat.albedo_color = EYE_WHITE
	white_mat.roughness = 0.2
	white.material_override = white_mat
	holder.add_child(white)

	var pupil := MeshInstance3D.new()
	var pupil_mesh := SphereMesh.new()
	pupil_mesh.radius = 0.06
	pupil_mesh.height = 0.12
	pupil.mesh = pupil_mesh
	var pupil_mat := StandardMaterial3D.new()
	pupil_mat.albedo_color = PUPIL
	pupil_mat.roughness = 0.1
	pupil.material_override = pupil_mat
	pupil.position = Vector3(0, 0, -0.07)
	holder.add_child(pupil)

	var glint := MeshInstance3D.new()
	var glint_mesh := SphereMesh.new()
	glint_mesh.radius = 0.025
	glint_mesh.height = 0.05
	glint.mesh = glint_mesh
	var glint_mat := StandardMaterial3D.new()
	glint_mat.albedo_color = Color.WHITE
	glint_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glint.material_override = glint_mat
	glint.position = Vector3(-0.035, 0.04, -0.1)
	holder.add_child(glint)

	return holder


func _make_blush(x_offset: float) -> void:
	var cheek := MeshInstance3D.new()
	var cheek_mesh := SphereMesh.new()
	cheek_mesh.radius = 0.09
	cheek_mesh.height = 0.1
	cheek.mesh = cheek_mesh
	var cheek_mat := StandardMaterial3D.new()
	cheek_mat.albedo_color = BLUSH
	cheek_mat.roughness = 0.6
	cheek.material_override = cheek_mat
	cheek.position = Vector3(x_offset, -0.04, -0.3)
	cheek.scale = Vector3(1.3, 0.8, 0.5)
	body.add_child(cheek)


func set_base_color(color: Color) -> void:
	_base_color = color
	if _body_mat:
		_body_mat.albedo_color = color


func set_hunter_glow(active: bool) -> void:
	if _body_mat == null:
		return
	_body_mat.emission_enabled = active
	_body_mat.emission = Color(1.0, 0.35, 0.25)
	_body_mat.emission_energy_multiplier = 0.9 if active else 0.0


func set_ghost(is_ghost: bool) -> void:
	_is_ghost = is_ghost
	if _body_mat == null:
		return
	if is_ghost:
		_body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_body_mat.albedo_color = Color(_base_color.r, _base_color.g, _base_color.b, 0.35)
	else:
		_body_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		_body_mat.albedo_color = _base_color


## Kick the squash spring: >1 stretches tall (jump), <1 squashes flat (land).
func pop(amount: float) -> void:
	_squash_vel += amount


func animate(delta: float, speed_ratio: float, grounded: bool) -> void:
	if body == null:
		return

	# Spring the squash value back toward 1.0 so every hit wobbles out smoothly.
	var stiffness := 90.0
	var damping := 11.0
	_squash_vel += (1.0 - _squash) * stiffness * delta
	_squash_vel *= 1.0 - min(damping * delta, 1.0)
	_squash += _squash_vel * delta

	# Gentle idle breathing, and a faster bounce while running.
	_walk_phase += delta * lerp(2.2, 15.0, speed_ratio)
	var bounce: float = sin(_walk_phase) * lerp(0.02, 0.07, speed_ratio)
	var stretch: float = _squash + bounce
	var width: float = 1.0 / sqrt(max(stretch, 0.15))

	body.scale = Vector3(width, stretch, width)
	body.position.y = 0.45 + max(0.0, sin(_walk_phase) * 0.06 * speed_ratio)

	if _is_ghost:
		body.position.y += 0.25 + sin(_walk_phase * 0.5) * 0.08

	# Ears trail behind the motion for a floppy, toy-like feel.
	for i in ears.size():
		var side := -1.0 if i == 0 else 1.0
		ears[i].rotation.z = -0.35 * side + sin(_walk_phase + i) * 0.25 * speed_ratio
		ears[i].rotation.x = -_squash_vel * 0.08

	# Feet paddle while running, tuck up while airborne.
	for i in feet.size():
		var offset: float = 0.0 if i == 0 else PI
		if grounded:
			feet[i].position.z = -0.05 + sin(_walk_phase + offset) * 0.16 * speed_ratio
			feet[i].position.y = -0.4 + max(0.0, sin(_walk_phase + offset)) * 0.08 * speed_ratio
		else:
			feet[i].position.y = lerp(feet[i].position.y, -0.3, delta * 8.0)

	_animate_blink(delta)


func _animate_blink(delta: float) -> void:
	_blink_t -= delta
	if _blink_t <= 0.0:
		_blink_t = randf_range(2.0, 5.5)
		var tween := create_tween()
		tween.tween_property(eye_left, "scale:y", 0.1, 0.06)
		tween.parallel().tween_property(eye_right, "scale:y", 0.1, 0.06)
		tween.tween_property(eye_left, "scale:y", 1.0, 0.09)
		tween.parallel().tween_property(eye_right, "scale:y", 1.0, 0.09)


## Make the eyes glance toward a world position (used so the Hunter visibly
## locks onto whoever it is chasing).
func look_at_point(target: Vector3, delta: float) -> void:
	var local := body.to_local(target)
	var yaw: float = clamp(local.x * 0.35, -0.05, 0.05)
	var pitch: float = clamp(local.y * 0.2, -0.03, 0.03)
	for eye in [eye_left, eye_right]:
		eye.position.x = lerp(eye.position.x, (-0.16 if eye == eye_left else 0.16) + yaw, delta * 6.0)
		eye.position.y = lerp(eye.position.y, 0.1 + pitch, delta * 6.0)
