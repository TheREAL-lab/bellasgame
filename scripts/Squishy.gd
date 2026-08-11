class_name Squishy
extends Node3D

## Builds and animates a squishy character out of primitives. Every player gets
## a different species -- different silhouette, ears, and little extras -- so
## they're told apart by shape as well as colour.

enum Species { BUNNY, CAT, BEAR, FROG, CHICK, PUPPY }

const SPECIES_NAMES := ["Bunny", "Kitty", "Bear", "Froggy", "Chick", "Puppy"]

const EYE_WHITE := Color(1, 1, 1)
const PUPIL := Color(0.13, 0.1, 0.16)
const BLUSH := Color(1.0, 0.55, 0.65)
const HIT_FLASH := Color(1.0, 0.95, 0.95)

## Past this the ears, eyes, feet, snout and weapon stop drawing and the squishy
## is just its body sphere. With a hundred of them on an island that is the
## difference between a game and a slideshow, and at forty metres a bunny and a
## bear are the same three pixels anyway.
const DETAIL_RANGE := 38.0

var species: int = Species.BUNNY

var body: MeshInstance3D
var eye_left: Node3D
var eye_right: Node3D
var ears: Array[Node3D] = []
var feet: Array[MeshInstance3D] = []
var tail: Node3D = null
var hold_point: Node3D = null
var hat: Node3D = null

var _propeller: Node3D = null
var _weapon_model: Node3D = null
var _hold_rest: Vector3 = Vector3.ZERO
var _flash_tween: Tween = null
var _body_mat: StandardMaterial3D
var _accent_mat: StandardMaterial3D
var _base_color: Color = Color.WHITE
var _body_width: float = 1.0
var _eye_height: float = 0.1
var _eye_base_x: Vector2 = Vector2(-0.16, 0.16)
var _walk_phase: float = 0.0
var _blink_t: float = 0.0
var _squash: float = 1.0        # >1 stretched tall, <1 squashed flat
var _squash_vel: float = 0.0
var _is_ghost: bool = false
var _built: bool = false


func build(species_index: int, color: Color) -> void:
	species = species_index % Species.size()
	_base_color = color
	if _built:
		return
	_built = true
	_build_materials()
	_build_body()
	_build_ears()
	_build_face()
	_build_feet()
	_build_extras()
	_build_hold_point()
	_build_hat()
	_apply_detail_range(body)


func species_name() -> String:
	return SPECIES_NAMES[species]


func _build_materials() -> void:
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = _base_color
	_body_mat.roughness = 0.35
	_body_mat.rim_enabled = true
	_body_mat.rim = 0.6
	_body_mat.rim_tint = 0.4

	_accent_mat = StandardMaterial3D.new()
	_accent_mat.albedo_color = _base_color.lightened(0.45)
	_accent_mat.roughness = 0.45


## Each species gets its own proportions, which is most of the silhouette.
func _build_body() -> void:
	var radius := 0.45
	var height := 0.9
	match species:
		Species.BUNNY:
			radius = 0.42; height = 0.95
		Species.CAT:
			radius = 0.43; height = 0.88
		Species.BEAR:
			radius = 0.52; height = 0.92
		Species.FROG:
			radius = 0.52; height = 0.72     # wide and low
		Species.CHICK:
			radius = 0.38; height = 0.8      # small and round
		Species.PUPPY:
			radius = 0.46; height = 0.88

	_body_width = radius / 0.45

	body = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 32
	mesh.rings = 16
	body.mesh = mesh
	body.material_override = _body_mat
	body.position.y = height * 0.5
	add_child(body)

	# A paler belly patch gives the blob a front and reads as a tummy.
	if species != Species.FROG:
		var belly := MeshInstance3D.new()
		var belly_mesh := SphereMesh.new()
		belly_mesh.radius = radius * 0.62
		belly_mesh.height = height * 0.62
		belly.mesh = belly_mesh
		belly.material_override = _accent_mat
		belly.position = Vector3(0, -height * 0.12, -radius * 0.55)
		belly.scale = Vector3(1.0, 1.0, 0.6)
		body.add_child(belly)


func _build_ears() -> void:
	match species:
		Species.BUNNY:
			for side in [-1.0, 1.0]:
				ears.append(_add_ear(Vector3(0.17 * side, 0.5, 0.0),
					Vector3(0.6, 2.6, 0.5), -0.18 * side, 0.13))
		Species.CAT:
			for side in [-1.0, 1.0]:
				var ear := _add_cone_ear(Vector3(0.24 * side, 0.42, -0.05), 0.17, 0.34)
				ear.rotation.z = -0.3 * side
				ears.append(ear)
		Species.BEAR:
			for side in [-1.0, 1.0]:
				ears.append(_add_ear(Vector3(0.31 * side, 0.42, 0.0),
					Vector3(1.0, 1.0, 0.7), 0.0, 0.17))
		Species.FROG:
			# Eyes on top instead of ears -- handled in _build_face.
			pass
		Species.CHICK:
			var tuft := _add_ear(Vector3(0.0, 0.46, -0.02), Vector3(0.5, 1.3, 0.5), 0.0, 0.11)
			ears.append(tuft)
		Species.PUPPY:
			for side in [-1.0, 1.0]:
				# Floppy ears hang down the sides of the head.
				var ear := _add_ear(Vector3(0.33 * side, 0.16, -0.02),
					Vector3(0.55, 1.7, 0.8), 0.0, 0.15)
				ear.rotation.z = -0.25 * side
				ears.append(ear)


func _add_ear(pos: Vector3, stretch: Vector3, tilt: float, radius: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pos
	pivot.rotation.z = tilt
	body.add_child(pivot)

	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _body_mat
	mesh_instance.scale = stretch
	mesh_instance.position.y = radius * stretch.y * 0.5
	pivot.add_child(mesh_instance)

	var inner := MeshInstance3D.new()
	var inner_mesh := SphereMesh.new()
	inner_mesh.radius = radius * 0.55
	inner_mesh.height = radius * 1.1
	inner.mesh = inner_mesh
	inner.material_override = _accent_mat
	inner.scale = Vector3(stretch.x * 0.8, stretch.y * 0.85, 0.4)
	inner.position = Vector3(0, radius * stretch.y * 0.5, -radius * 0.55)
	pivot.add_child(inner)
	return pivot


func _add_cone_ear(pos: Vector3, radius: float, height: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pos
	body.add_child(pivot)

	var mesh_instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _body_mat
	mesh_instance.position.y = height * 0.5
	pivot.add_child(mesh_instance)
	return pivot


func _build_face() -> void:
	var front := -0.36 * _body_width
	match species:
		Species.FROG:
			# Bulging eyes perched on top of the head.
			eye_left = _make_eye(Vector3(-0.26, 0.34, -0.16), 0.17)
			eye_right = _make_eye(Vector3(0.26, 0.34, -0.16), 0.17)
		Species.CHICK:
			eye_left = _make_eye(Vector3(-0.13, 0.12, front), 0.095)
			eye_right = _make_eye(Vector3(0.13, 0.12, front), 0.095)
		Species.BEAR:
			eye_left = _make_eye(Vector3(-0.17, 0.12, front), 0.1)
			eye_right = _make_eye(Vector3(0.17, 0.12, front), 0.1)
		_:
			eye_left = _make_eye(Vector3(-0.16, 0.1, front), 0.115)
			eye_right = _make_eye(Vector3(0.16, 0.1, front), 0.115)
	_eye_height = eye_left.position.y
	_eye_base_x = Vector2(eye_left.position.x, eye_right.position.x)

	if species != Species.FROG:
		_make_blush(-0.3 * _body_width)
		_make_blush(0.3 * _body_width)


func _make_eye(pos: Vector3, size: float) -> Node3D:
	var holder := Node3D.new()
	holder.position = pos
	body.add_child(holder)

	var white := MeshInstance3D.new()
	var white_mesh := SphereMesh.new()
	white_mesh.radius = size
	white_mesh.height = size * 2.0
	white.mesh = white_mesh
	var white_mat := StandardMaterial3D.new()
	white_mat.albedo_color = EYE_WHITE
	white_mat.roughness = 0.2
	white.material_override = white_mat
	holder.add_child(white)

	var pupil := MeshInstance3D.new()
	var pupil_mesh := SphereMesh.new()
	pupil_mesh.radius = size * 0.52
	pupil_mesh.height = size * 1.04
	pupil.mesh = pupil_mesh
	var pupil_mat := StandardMaterial3D.new()
	pupil_mat.albedo_color = PUPIL
	pupil_mat.roughness = 0.1
	pupil.material_override = pupil_mat
	pupil.position = Vector3(0, 0, -size * 0.6)
	holder.add_child(pupil)

	var glint := MeshInstance3D.new()
	var glint_mesh := SphereMesh.new()
	glint_mesh.radius = size * 0.22
	glint_mesh.height = size * 0.44
	glint.mesh = glint_mesh
	var glint_mat := StandardMaterial3D.new()
	glint_mat.albedo_color = Color.WHITE
	glint_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glint.material_override = glint_mat
	glint.position = Vector3(-size * 0.3, size * 0.35, -size * 0.85)
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
	cheek.position = Vector3(x_offset, -0.04, -0.3 * _body_width)
	cheek.scale = Vector3(1.3, 0.8, 0.5)
	body.add_child(cheek)


func _build_feet() -> void:
	var spread := 0.2 * _body_width
	var foot_size := 0.15
	if species == Species.FROG:
		spread = 0.3
		foot_size = 0.18
	for side in [-1.0, 1.0]:
		var foot := MeshInstance3D.new()
		var foot_mesh := SphereMesh.new()
		foot_mesh.radius = foot_size
		foot_mesh.height = foot_size * 1.2
		foot.mesh = foot_mesh
		foot.material_override = _accent_mat
		foot.position = Vector3(spread * side, -0.4, -0.05)
		body.add_child(foot)
		feet.append(foot)


## Species-specific flourishes: a beak, a snout, a tail.
func _build_extras() -> void:
	match species:
		Species.CHICK:
			var beak := MeshInstance3D.new()
			var beak_mesh := CylinderMesh.new()
			beak_mesh.top_radius = 0.0
			beak_mesh.bottom_radius = 0.09
			beak_mesh.height = 0.18
			beak_mesh.radial_segments = 8
			beak.mesh = beak_mesh
			var beak_mat := StandardMaterial3D.new()
			beak_mat.albedo_color = Color(1.0, 0.68, 0.2)
			beak.material_override = beak_mat
			beak.position = Vector3(0, -0.02, -0.4)
			beak.rotation.x = -PI * 0.5
			body.add_child(beak)
		Species.PUPPY, Species.BEAR:
			var snout := MeshInstance3D.new()
			var snout_mesh := SphereMesh.new()
			snout_mesh.radius = 0.15
			snout_mesh.height = 0.24
			snout.mesh = snout_mesh
			snout.material_override = _accent_mat
			snout.position = Vector3(0, -0.06, -0.38 * _body_width)
			snout.scale = Vector3(1.2, 0.9, 0.9)
			body.add_child(snout)

			var nose := MeshInstance3D.new()
			var nose_mesh := SphereMesh.new()
			nose_mesh.radius = 0.06
			nose_mesh.height = 0.1
			nose.mesh = nose_mesh
			var nose_mat := StandardMaterial3D.new()
			nose_mat.albedo_color = PUPIL
			nose.material_override = nose_mat
			nose.position = Vector3(0, 0.02, -0.5 * _body_width)
			body.add_child(nose)
		Species.BUNNY:
			tail = Node3D.new()
			tail.position = Vector3(0, -0.1, 0.42 * _body_width)
			body.add_child(tail)
			var puff := MeshInstance3D.new()
			var puff_mesh := SphereMesh.new()
			puff_mesh.radius = 0.14
			puff_mesh.height = 0.28
			puff.mesh = puff_mesh
			puff.material_override = _accent_mat
			tail.add_child(puff)
		Species.CAT:
			tail = Node3D.new()
			tail.position = Vector3(0, -0.05, 0.4 * _body_width)
			body.add_child(tail)
			for i in 4:
				var seg := MeshInstance3D.new()
				var seg_mesh := SphereMesh.new()
				seg_mesh.radius = 0.08 - float(i) * 0.012
				seg_mesh.height = seg_mesh.radius * 2.0
				seg.mesh = seg_mesh
				seg.material_override = _body_mat
				seg.position = Vector3(0, float(i) * 0.14, float(i) * 0.06)
				tail.add_child(seg)


func set_base_color(color: Color) -> void:
	_base_color = color
	if _body_mat:
		_body_mat.albedo_color = color
	if _accent_mat:
		_accent_mat.albedo_color = color.lightened(0.45)


## Where a weapon hangs: out in front and a little to the right, at about the
## height a squishy with no arms would hold one if it had any.
func _build_hold_point() -> void:
	hold_point = Node3D.new()
	_hold_rest = Vector3(0.34 * _body_width, -0.02, -0.34)
	hold_point.position = _hold_rest
	body.add_child(hold_point)


## The spinny hat is built once and hidden, rather than made and freed each time
## somebody picks one up -- a hundred bots swapping hats would churn constantly.
func _build_hat() -> void:
	hat = Node3D.new()
	hat.position = Vector3(0, 0.44, 0)
	hat.visible = false
	body.add_child(hat)

	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(1.0, 0.42, 0.5)
	cap_mat.roughness = 0.4

	var cap := MeshInstance3D.new()
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = 0.22
	cap_mesh.height = 0.24
	cap_mesh.is_hemisphere = true
	cap_mesh.radial_segments = 12
	cap.mesh = cap_mesh
	cap.material_override = cap_mat
	hat.add_child(cap)

	var blade_mat := StandardMaterial3D.new()
	blade_mat.albedo_color = Color(0.45, 0.8, 1.0)
	blade_mat.roughness = 0.3

	_propeller = Node3D.new()
	_propeller.position.y = 0.26
	hat.add_child(_propeller)
	for i in 2:
		var blade := MeshInstance3D.new()
		var blade_mesh := BoxMesh.new()
		blade_mesh.size = Vector3(0.4, 0.02, 0.085)
		blade.mesh = blade_mesh
		blade.material_override = blade_mat
		blade.rotation.y = PI * float(i) / 2.0
		_propeller.add_child(blade)


## Everything hanging off the body gets a visibility range so the engine drops it
## at distance without this script doing anything per frame. The body sphere
## itself keeps no range -- it *is* the far-away version.
func _apply_detail_range(node: Node) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			child.visibility_range_end = DETAIL_RANGE
		_apply_detail_range(child)


func set_hat(on: bool) -> void:
	if hat != null:
		hat.visible = on


func spin_propeller(delta: float, speed: float) -> void:
	if _propeller != null and hat.visible:
		_propeller.rotation.y += delta * speed


## Swap the held model. Passing null empties the hands, which is what being
## knocked out does.
func hold(model: Node3D) -> void:
	if hold_point == null:
		return
	if _weapon_model != null and is_instance_valid(_weapon_model):
		_weapon_model.queue_free()
	_weapon_model = model
	if model != null:
		hold_point.add_child(model)
		_apply_detail_range(hold_point)


## A swing is a quick shove forward and back -- no skeleton, no keyframes, just
## the hold point doing the acting.
func swing() -> void:
	if hold_point == null:
		return
	var tween := hold_point.create_tween()
	tween.tween_property(hold_point, "position", _hold_rest + Vector3(-0.1, 0.12, -0.3), 0.08)
	tween.tween_property(hold_point, "position", _hold_rest, 0.16)
	tween.parallel().tween_property(hold_point, "rotation:x", 0.0, 0.16)


func recoil() -> void:
	if hold_point == null:
		return
	var tween := hold_point.create_tween()
	tween.tween_property(hold_point, "position", _hold_rest + Vector3(0, 0.03, 0.11), 0.04)
	tween.tween_property(hold_point, "position", _hold_rest, 0.1)


## A white blink on the whole squishy. Readable across a field at a glance, which
## a health bar over a distant bot is not.
func flash_hit() -> void:
	if _body_mat == null or _is_ghost:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_body_mat.albedo_color = HIT_FLASH
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_mat, "albedo_color", _base_color, 0.22)


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

	# Spring the squash back toward 1.0 so every hit wobbles out smoothly.
	_squash_vel += (1.0 - _squash) * 90.0 * delta
	_squash_vel *= 1.0 - min(11.0 * delta, 1.0)
	_squash += _squash_vel * delta

	# Frogs hop rather than trot, so their gait cycle is slower and deeper.
	var gait: float = 11.0 if species == Species.FROG else 15.0
	_walk_phase += delta * lerp(2.2, gait, speed_ratio)
	var bounce: float = sin(_walk_phase) * lerp(0.02, 0.07, speed_ratio)
	var stretch: float = _squash + bounce
	var width: float = 1.0 / sqrt(max(stretch, 0.15))

	body.scale = Vector3(width, stretch, width)
	body.position.y = _rest_height() + max(0.0, sin(_walk_phase) * 0.06 * speed_ratio)

	if _is_ghost:
		body.position.y += 0.25 + sin(_walk_phase * 0.5) * 0.08

	# A hat idles slowly on the ground; Player spins it up properly mid-hover.
	if hat != null and hat.visible and _propeller != null:
		_propeller.rotation.y += delta * 4.0

	_animate_ears(delta, speed_ratio)
	_animate_feet(delta, speed_ratio, grounded)
	_animate_tail(speed_ratio)
	_animate_blink(delta)


func _rest_height() -> float:
	match species:
		Species.FROG:
			return 0.36
		Species.CHICK:
			return 0.4
		Species.BEAR:
			return 0.46
		_:
			return 0.45


func _animate_ears(_delta: float, speed_ratio: float) -> void:
	for i in ears.size():
		var side := -1.0 if i == 0 else 1.0
		var swing: float = sin(_walk_phase + float(i)) * 0.25 * speed_ratio
		match species:
			Species.BUNNY:
				ears[i].rotation.z = -0.18 * side + swing * 0.8
				ears[i].rotation.x = -_squash_vel * 0.14
			Species.PUPPY:
				# Floppy ears lag behind and flap when airborne.
				ears[i].rotation.z = -0.25 * side + swing * 1.1
				ears[i].rotation.x = -_squash_vel * 0.2
			Species.CAT:
				ears[i].rotation.z = -0.3 * side + swing * 0.3
			Species.CHICK:
				ears[i].rotation.z = swing * 1.4
			_:
				ears[i].rotation.z = swing * 0.4
				ears[i].rotation.x = -_squash_vel * 0.06


func _animate_feet(delta: float, speed_ratio: float, grounded: bool) -> void:
	for i in feet.size():
		var offset: float = 0.0 if i == 0 else PI
		if grounded:
			feet[i].position.z = -0.05 + sin(_walk_phase + offset) * 0.16 * speed_ratio
			feet[i].position.y = -0.4 + max(0.0, sin(_walk_phase + offset)) * 0.08 * speed_ratio
		else:
			feet[i].position.y = lerp(feet[i].position.y, -0.3, delta * 8.0)


func _animate_tail(speed_ratio: float) -> void:
	if tail == null:
		return
	tail.rotation.x = sin(_walk_phase * 0.8) * 0.15 * (0.4 + speed_ratio)
	tail.rotation.z = sin(_walk_phase * 1.3) * 0.2 * (0.3 + speed_ratio)


func _animate_blink(delta: float) -> void:
	_blink_t -= delta
	if _blink_t <= 0.0:
		_blink_t = randf_range(2.0, 5.5)
		var tween := create_tween()
		tween.tween_property(eye_left, "scale:y", 0.1, 0.06)
		tween.parallel().tween_property(eye_right, "scale:y", 0.1, 0.06)
		tween.tween_property(eye_left, "scale:y", 1.0, 0.09)
		tween.parallel().tween_property(eye_right, "scale:y", 1.0, 0.09)


## Glance toward a world position, so IT visibly locks onto whoever it's chasing.
func look_at_point(target: Vector3, delta: float) -> void:
	if body == null:
		return
	var local := body.to_local(target)
	var yaw: float = clamp(local.x * 0.35, -0.05, 0.05)
	var pitch: float = clamp(local.y * 0.2, -0.03, 0.03)
	eye_left.position.x = lerp(eye_left.position.x, _eye_base_x.x + yaw, delta * 6.0)
	eye_right.position.x = lerp(eye_right.position.x, _eye_base_x.y + yaw, delta * 6.0)
	eye_left.position.y = lerp(eye_left.position.y, _eye_height + pitch, delta * 6.0)
	eye_right.position.y = lerp(eye_right.position.y, _eye_height + pitch, delta * 6.0)
