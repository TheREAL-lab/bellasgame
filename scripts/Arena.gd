extends Node3D

## Builds the playfield procedurally (props, spawn points, navigation) so the
## level can be re-tuned by editing one table instead of hand-placing nodes.

const ARENA_HALF := 13.0
const WALL_HEIGHT := 3.5

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D

var hunter_spawn: Vector3 = Vector3(0, 1.2, 0)
var hider_spawns: Array[Vector3] = []
var hiding_spots: Array[Vector3] = []

# type, position, size/radius, color. Laid out by hand for good sightlines:
# a ring of cover near the walls, chunky blockers mid-field, and a cluster in
# the middle so the Hunter's opening sweep never sees the whole map at once.
const PROPS := [
	{"type": "mushroom", "pos": Vector2(5.5, 5.0), "size": 1.5, "color": Color(1.0, 0.45, 0.5)},
	{"type": "mushroom", "pos": Vector2(-6.0, 4.0), "size": 1.8, "color": Color(0.95, 0.85, 0.4)},
	{"type": "mushroom", "pos": Vector2(1.5, -7.5), "size": 1.6, "color": Color(0.7, 0.55, 1.0)},
	{"type": "mushroom", "pos": Vector2(-8.5, -6.0), "size": 1.4, "color": Color(0.5, 0.9, 0.7)},
	{"type": "block", "pos": Vector2(8.5, -3.0), "size": 2.2, "color": Color(1.0, 0.72, 0.35)},
	{"type": "block", "pos": Vector2(-3.5, -2.0), "size": 1.8, "color": Color(0.6, 0.82, 1.0)},
	{"type": "block", "pos": Vector2(3.0, 8.5), "size": 2.0, "color": Color(1.0, 0.6, 0.8)},
	{"type": "block", "pos": Vector2(-9.0, 1.0), "size": 1.7, "color": Color(0.85, 0.7, 1.0)},
	{"type": "block", "pos": Vector2(9.5, 7.5), "size": 1.9, "color": Color(0.65, 0.95, 0.6)},
	{"type": "pillar", "pos": Vector2(-1.0, 3.5), "size": 1.0, "color": Color(0.55, 0.85, 1.0)},
	{"type": "pillar", "pos": Vector2(6.5, 0.5), "size": 0.9, "color": Color(1.0, 0.8, 0.5)},
	{"type": "pillar", "pos": Vector2(-5.0, -8.5), "size": 1.1, "color": Color(1.0, 0.65, 0.85)},
	{"type": "bush", "pos": Vector2(2.5, 2.0), "size": 1.3, "color": Color(0.45, 0.8, 0.5)},
	{"type": "bush", "pos": Vector2(-2.5, 7.5), "size": 1.5, "color": Color(0.4, 0.75, 0.45)},
	{"type": "bush", "pos": Vector2(7.5, -8.0), "size": 1.4, "color": Color(0.5, 0.85, 0.55)},
	{"type": "bush", "pos": Vector2(-7.5, 8.5), "size": 1.2, "color": Color(0.45, 0.8, 0.5)},
	{"type": "tree", "pos": Vector2(-10.5, -9.5), "size": 1.7, "color": Color(0.35, 0.7, 0.45)},
	{"type": "tree", "pos": Vector2(10.0, 10.5), "size": 1.9, "color": Color(0.4, 0.75, 0.5)},
	{"type": "tree", "pos": Vector2(-1.5, 10.5), "size": 1.6, "color": Color(0.32, 0.66, 0.42)},
	{"type": "tree", "pos": Vector2(11.0, -9.5), "size": 1.8, "color": Color(0.38, 0.72, 0.46)},
	{"type": "rock", "pos": Vector2(-2.0, -10.0), "size": 1.3, "color": Color(0.66, 0.68, 0.78)},
	{"type": "rock", "pos": Vector2(5.5, -10.5), "size": 1.0, "color": Color(0.72, 0.72, 0.8)},
	{"type": "rock", "pos": Vector2(-10.5, 5.5), "size": 1.2, "color": Color(0.62, 0.65, 0.75)},
	{"type": "candy", "pos": Vector2(4.0, -4.5), "size": 1.0, "color": Color(1.0, 0.4, 0.5)},
	{"type": "candy", "pos": Vector2(-6.5, -2.5), "size": 1.0, "color": Color(0.5, 0.8, 1.0)},
]


func _ready() -> void:
	add_to_group("arena_root")
	$Players.add_to_group("players_container")
	$MultiplayerSpawner.add_to_group("player_spawner")
	$MultiplayerSpawner.spawn_function = _spawn_player_node

	_build_ground()
	_build_walls()
	_build_props()
	_compute_spawns()
	_bake_navigation()
	# Decoration goes on last, outside the nav region, so it never affects pathing.
	_build_wall_trim()
	_scatter_flowers()
	_build_balloons()
	_build_clouds()
	_build_pond()
	_build_lamps()
	_build_rainbow()


## Runs on every peer with identical data, so player identity replicates.
func _spawn_player_node(data: Dictionary) -> Node:
	var player: Node3D = preload("res://scenes/Player.tscn").instantiate()
	player.name = str(data.id)
	player.player_id = data.id
	player.player_name = data.name
	player.is_bot = data.bot
	player.set_multiplayer_authority(1 if data.bot else int(data.id))
	return player


func _make_material(color: Color, roughness: float = 0.75) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat


func _add_body(parent: Node, mesh: Mesh, shape: Shape3D, xform: Transform3D,
		mat: StandardMaterial3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = xform
	parent.add_child(body)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)

	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	return body


func _build_ground() -> void:
	var size := ARENA_HALF * 2.0
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, 1.0, size)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size, 1.0, size)
	var xform := Transform3D(Basis(), Vector3(0, -0.5, 0))
	_add_body(nav_region, mesh, shape, xform, _make_material(Color(0.42, 0.72, 0.42), 0.95))


func _build_walls() -> void:
	var span := ARENA_HALF * 2.0
	var mat := _make_material(Color(0.6, 0.52, 0.8), 0.85)
	var configs := [
		{"size": Vector3(span, WALL_HEIGHT, 1.0), "pos": Vector3(0, WALL_HEIGHT * 0.5, -ARENA_HALF)},
		{"size": Vector3(span, WALL_HEIGHT, 1.0), "pos": Vector3(0, WALL_HEIGHT * 0.5, ARENA_HALF)},
		{"size": Vector3(1.0, WALL_HEIGHT, span), "pos": Vector3(-ARENA_HALF, WALL_HEIGHT * 0.5, 0)},
		{"size": Vector3(1.0, WALL_HEIGHT, span), "pos": Vector3(ARENA_HALF, WALL_HEIGHT * 0.5, 0)},
	]
	for cfg in configs:
		var mesh := BoxMesh.new()
		mesh.size = cfg.size
		var shape := BoxShape3D.new()
		shape.size = cfg.size
		_add_body(nav_region, mesh, shape, Transform3D(Basis(), cfg.pos), mat)


func _build_props() -> void:
	for prop in PROPS:
		var pos: Vector2 = prop.pos
		var ground := Vector3(pos.x, 0.0, pos.y)
		match prop.type:
			"mushroom":
				_build_mushroom(ground, prop.size, prop.color)
			"block":
				_build_block(ground, prop.size, prop.color)
			"pillar":
				_build_pillar(ground, prop.size, prop.color)
			"bush":
				_build_bush(ground, prop.size, prop.color)
			"tree":
				_build_tree(ground, prop.size, prop.color)
			"rock":
				_build_rock(ground, prop.size, prop.color)
			"candy":
				_build_candy_cane(ground, prop.size, prop.color)
		# Hiding spots sit just behind each prop, away from the arena centre.
		var away := Vector3(pos.x, 0, pos.y).normalized()
		if away.length_squared() < 0.01:
			away = Vector3.FORWARD
		hiding_spots.append(ground + away * (prop.size + 0.6) + Vector3.UP)


func _build_mushroom(base: Vector3, size: float, color: Color) -> void:
	var stem_h: float = size * 1.1
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = size * 0.28
	stem_mesh.bottom_radius = size * 0.34
	stem_mesh.height = stem_h
	var stem_shape := CylinderShape3D.new()
	stem_shape.radius = size * 0.34
	stem_shape.height = stem_h
	var stem_body := _add_body(nav_region, stem_mesh, stem_shape,
		Transform3D(Basis(), base + Vector3(0, stem_h * 0.5, 0)),
		_make_material(Color(0.98, 0.95, 0.88)))

	# The cap is decoration only -- no collider, so it never blocks navigation.
	var cap := MeshInstance3D.new()
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = size * 0.85
	cap_mesh.height = size * 1.0
	cap_mesh.is_hemisphere = true
	cap.mesh = cap_mesh
	cap.material_override = _make_material(color, 0.55)
	cap.position = Vector3(0, stem_h * 0.5, 0)
	stem_body.add_child(cap)


func _build_block(base: Vector3, size: float, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, size, size)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size, size, size)
	var xform := Transform3D(Basis(Vector3.UP, randf_range(-0.3, 0.3)), base + Vector3(0, size * 0.5, 0))
	_add_body(nav_region, mesh, shape, xform, _make_material(color, 0.6))


func _build_pillar(base: Vector3, size: float, color: Color) -> void:
	var height: float = size * 2.6
	var mesh := CylinderMesh.new()
	mesh.top_radius = size * 0.55
	mesh.bottom_radius = size * 0.55
	mesh.height = height
	var shape := CylinderShape3D.new()
	shape.radius = size * 0.55
	shape.height = height
	_add_body(nav_region, mesh, shape,
		Transform3D(Basis(), base + Vector3(0, height * 0.5, 0)),
		_make_material(color, 0.5))


func _build_bush(base: Vector3, size: float, color: Color) -> void:
	var shape := SphereShape3D.new()
	shape.radius = size * 0.75
	var mesh := SphereMesh.new()
	mesh.radius = size * 0.75
	mesh.height = size * 1.5
	var body := _add_body(nav_region, mesh, shape,
		Transform3D(Basis(), base + Vector3(0, size * 0.6, 0)),
		_make_material(color, 0.95))

	# A couple of extra lobes make the bush read as foliage rather than a ball.
	for i in 3:
		var lobe := MeshInstance3D.new()
		var lobe_mesh := SphereMesh.new()
		lobe_mesh.radius = size * 0.45
		lobe_mesh.height = size * 0.9
		lobe.mesh = lobe_mesh
		lobe.material_override = _make_material(color.lightened(0.12), 0.95)
		var angle := TAU * float(i) / 3.0
		lobe.position = Vector3(cos(angle) * size * 0.5, size * 0.25, sin(angle) * size * 0.5)
		body.add_child(lobe)


func _build_tree(base: Vector3, size: float, color: Color) -> void:
	var trunk_h: float = size * 1.6
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = size * 0.2
	trunk_mesh.bottom_radius = size * 0.28
	trunk_mesh.height = trunk_h
	var trunk_shape := CylinderShape3D.new()
	trunk_shape.radius = size * 0.28
	trunk_shape.height = trunk_h
	var trunk := _add_body(nav_region, trunk_mesh, trunk_shape,
		Transform3D(Basis(), base + Vector3(0, trunk_h * 0.5, 0)),
		_make_material(Color(0.62, 0.44, 0.32)))

	# Three stacked canopy blobs, decoration only so pathing stays clean.
	for i in 3:
		var blob := MeshInstance3D.new()
		var blob_mesh := SphereMesh.new()
		var r: float = size * (0.95 - float(i) * 0.18)
		blob_mesh.radius = r
		blob_mesh.height = r * 1.7
		blob.mesh = blob_mesh
		blob.material_override = _make_material(color.lightened(float(i) * 0.08), 0.9)
		blob.position = Vector3(
			sin(float(i) * 2.1) * size * 0.16,
			trunk_h * 0.5 + size * (0.55 + float(i) * 0.62),
			cos(float(i) * 2.1) * size * 0.16)
		trunk.add_child(blob)


func _build_rock(base: Vector3, size: float, color: Color) -> void:
	var shape := SphereShape3D.new()
	shape.radius = size * 0.7
	var mesh := SphereMesh.new()
	mesh.radius = size * 0.7
	mesh.height = size * 1.1
	mesh.radial_segments = 7
	mesh.rings = 4
	var body := _add_body(nav_region, mesh, shape,
		Transform3D(Basis(Vector3.UP, randf_range(0.0, TAU)), base + Vector3(0, size * 0.42, 0)),
		_make_material(color, 1.0))
	body.get_child(0).scale = Vector3(1.0, 0.8, 1.15)


func _build_candy_cane(base: Vector3, size: float, color: Color) -> void:
	var height: float = size * 3.4
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = size * 0.13
	pole_mesh.bottom_radius = size * 0.13
	pole_mesh.height = height
	var pole_shape := CylinderShape3D.new()
	pole_shape.radius = size * 0.22
	pole_shape.height = height
	var pole := _add_body(nav_region, pole_mesh, pole_shape,
		Transform3D(Basis(), base + Vector3(0, height * 0.5, 0)),
		_make_material(Color(0.99, 0.98, 1.0), 0.3))

	# Stripes wrap the pole; the hook on top makes it read as a candy cane.
	for i in 6:
		var stripe := MeshInstance3D.new()
		var stripe_mesh := CylinderMesh.new()
		stripe_mesh.top_radius = size * 0.145
		stripe_mesh.bottom_radius = size * 0.145
		stripe_mesh.height = height * 0.075
		stripe.mesh = stripe_mesh
		stripe.material_override = _make_material(color, 0.3)
		stripe.position.y = -height * 0.42 + float(i) * height * 0.16
		stripe.rotation.z = 0.35
		pole.add_child(stripe)

	for i in 5:
		var hook := MeshInstance3D.new()
		var hook_mesh := SphereMesh.new()
		hook_mesh.radius = size * 0.14
		hook_mesh.height = size * 0.28
		hook.mesh = hook_mesh
		hook.material_override = _make_material(
			color if i % 2 == 0 else Color(0.99, 0.98, 1.0), 0.3)
		var angle := PI * float(i) / 4.0
		hook.position = Vector3(sin(angle) * size * 0.45, height * 0.5 + (1.0 - cos(angle)) * size * 0.45, 0)
		pole.add_child(hook)


## A still pond with a stone rim -- pure decoration, but it breaks up the lawn.
func _build_pond() -> void:
	var centre := Vector3(-8.0, 0.0, -1.5)
	var water := MeshInstance3D.new()
	var water_mesh := CylinderMesh.new()
	water_mesh.top_radius = 2.4
	water_mesh.bottom_radius = 2.4
	water_mesh.height = 0.06
	water.mesh = water_mesh
	var water_mat := _make_material(Color(0.42, 0.72, 0.95), 0.05)
	water_mat.metallic = 0.35
	water.material_override = water_mat
	water.position = centre + Vector3(0, 0.04, 0)
	add_child(water)

	for i in 14:
		var angle := TAU * float(i) / 14.0
		var stone := MeshInstance3D.new()
		var stone_mesh := SphereMesh.new()
		stone_mesh.radius = 0.3
		stone_mesh.height = 0.42
		stone_mesh.radial_segments = 6
		stone.mesh = stone_mesh
		stone.material_override = _make_material(Color(0.7, 0.71, 0.8), 1.0)
		stone.position = centre + Vector3(cos(angle) * 2.55, 0.1, sin(angle) * 2.55)
		stone.scale = Vector3(1.0, 0.7, 1.0)
		add_child(stone)


## Lamp posts with warm point lights, so the playground has pools of light.
func _build_lamps() -> void:
	var spots := [Vector2(6.0, 3.0), Vector2(-4.5, 6.5), Vector2(-6.0, -7.0), Vector2(8.5, -6.5)]
	for spot in spots:
		var post := Node3D.new()
		post.position = Vector3(spot.x, 0, spot.y)
		add_child(post)

		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.07
		pole_mesh.bottom_radius = 0.1
		pole_mesh.height = 3.2
		pole.mesh = pole_mesh
		pole.material_override = _make_material(Color(0.35, 0.33, 0.45), 0.5)
		pole.position.y = 1.6
		post.add_child(pole)

		var globe := MeshInstance3D.new()
		var globe_mesh := SphereMesh.new()
		globe_mesh.radius = 0.28
		globe_mesh.height = 0.56
		globe.mesh = globe_mesh
		var globe_mat := _make_material(Color(1.0, 0.95, 0.75), 0.2)
		globe_mat.emission_enabled = true
		globe_mat.emission = Color(1.0, 0.9, 0.65)
		globe_mat.emission_energy_multiplier = 2.5
		globe.material_override = globe_mat
		globe.position.y = 3.35
		post.add_child(globe)

		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.88, 0.68)
		light.light_energy = 1.6
		light.omni_range = 7.0
		light.shadow_enabled = false
		light.position.y = 3.35
		post.add_child(light)


## A rainbow arch over the arena, because Bella asked for cool things.
func _build_rainbow() -> void:
	var colors := [
		Color(1.0, 0.42, 0.42), Color(1.0, 0.68, 0.35), Color(1.0, 0.9, 0.45),
		Color(0.55, 0.87, 0.55), Color(0.5, 0.75, 1.0), Color(0.72, 0.55, 1.0),
	]
	var arch := Node3D.new()
	arch.position = Vector3(0, 0, -ARENA_HALF - 3.0)
	arch.rotation.y = 0.15
	add_child(arch)

	for band in colors.size():
		var radius: float = 15.0 - float(band) * 0.85
		for i in 26:
			var t := PI * float(i) / 25.0
			var seg := MeshInstance3D.new()
			var seg_mesh := BoxMesh.new()
			seg_mesh.size = Vector3(0.9, 0.85, 0.85)
			seg.mesh = seg_mesh
			var mat := _make_material(colors[band], 0.6)
			mat.emission_enabled = true
			mat.emission = colors[band]
			mat.emission_energy_multiplier = 0.35
			seg.material_override = mat
			seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			seg.position = Vector3(cos(t) * radius, sin(t) * radius, 0)
			seg.rotation.z = t
			arch.add_child(seg)


## A candy-striped cap along the top of each wall, so the boundary reads as part
## of the playground instead of a blank slab.
func _build_wall_trim() -> void:
	var colors := [Color(1.0, 0.55, 0.72), Color(1.0, 0.85, 0.45)]
	var span := ARENA_HALF * 2.0
	var segments := 24
	var seg_len := span / float(segments)
	for axis in 2:
		for sign_i in 2:
			var edge: float = ARENA_HALF if sign_i == 0 else -ARENA_HALF
			for i in segments:
				var along := -ARENA_HALF + seg_len * (float(i) + 0.5)
				var mi := MeshInstance3D.new()
				var mesh := BoxMesh.new()
				mesh.size = (Vector3(seg_len * 0.94, 0.45, 1.35) if axis == 0
					else Vector3(1.35, 0.45, seg_len * 0.94))
				mi.mesh = mesh
				mi.material_override = _make_material(colors[i % colors.size()], 0.5)
				mi.position = (Vector3(along, WALL_HEIGHT + 0.15, edge) if axis == 0
					else Vector3(edge, WALL_HEIGHT + 0.15, along))
				add_child(mi)


## Flowers are drawn as a single MultiMesh so hundreds of them cost one draw call.
func _scatter_flowers() -> void:
	var petal_colors := [
		Color(1.0, 0.35, 0.55), Color(1.0, 0.75, 0.2),
		Color(0.72, 0.45, 1.0), Color(1.0, 0.55, 0.75),
		Color(0.35, 0.62, 0.35), Color(0.98, 0.98, 1.0),
	]
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.13
	mesh.bottom_radius = 0.13
	mesh.height = 0.05
	mesh.radial_segments = 6

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mesh.material = mat

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh

	var placements: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260726
	for i in 260:
		var x := rng.randf_range(-ARENA_HALF + 1.0, ARENA_HALF - 1.0)
		var z := rng.randf_range(-ARENA_HALF + 1.0, ARENA_HALF - 1.0)
		# Keep the Hunter's starting circle clear so the centre reads as a stage.
		if Vector2(x, z).length() < 2.2:
			continue
		placements.append({
			"pos": Vector3(x, 0.02, z),
			"scale": rng.randf_range(0.55, 1.25),
			"color": petal_colors[rng.randi() % petal_colors.size()],
		})

	multimesh.instance_count = placements.size()
	for i in placements.size():
		var p: Dictionary = placements[i]
		var flower_basis := Basis().scaled(Vector3(p.scale, 1.0, p.scale))
		multimesh.set_instance_transform(i, Transform3D(flower_basis, p.pos))
		multimesh.set_instance_color(i, p.color)

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## Balloons in the corners give the skyline something cheerful to read against.
func _build_balloons() -> void:
	var corners := [
		Vector3(-ARENA_HALF + 2.0, 0, -ARENA_HALF + 2.0),
		Vector3(ARENA_HALF - 2.0, 0, -ARENA_HALF + 2.0),
		Vector3(-ARENA_HALF + 2.0, 0, ARENA_HALF - 2.0),
		Vector3(ARENA_HALF - 2.0, 0, ARENA_HALF - 2.0),
	]
	var colors := [
		Color(1.0, 0.45, 0.5), Color(0.5, 0.75, 1.0),
		Color(1.0, 0.82, 0.4), Color(0.7, 0.55, 1.0),
	]
	for i in corners.size():
		var cluster := Node3D.new()
		cluster.position = corners[i]
		add_child(cluster)
		for j in 3:
			var angle := TAU * float(j) / 3.0
			var height := 4.2 + float(j) * 0.55

			var string := MeshInstance3D.new()
			var string_mesh := CylinderMesh.new()
			string_mesh.top_radius = 0.02
			string_mesh.bottom_radius = 0.02
			string_mesh.height = height
			string.mesh = string_mesh
			string.material_override = _make_material(Color(0.95, 0.95, 0.98))
			string.position = Vector3(cos(angle) * 0.3, height * 0.5, sin(angle) * 0.3)
			cluster.add_child(string)

			var balloon := MeshInstance3D.new()
			var balloon_mesh := SphereMesh.new()
			balloon_mesh.radius = 0.42
			balloon_mesh.height = 1.0
			balloon.mesh = balloon_mesh
			var balloon_mat := _make_material(colors[(i + j) % colors.size()], 0.25)
			balloon_mat.emission_enabled = true
			balloon_mat.emission = colors[(i + j) % colors.size()]
			balloon_mat.emission_energy_multiplier = 0.25
			balloon.material_override = balloon_mat
			balloon.position = Vector3(cos(angle) * 0.3, height + 0.4, sin(angle) * 0.3)
			cluster.add_child(balloon)


func _build_clouds() -> void:
	var mat := _make_material(Color(1, 1, 1), 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 7:
		var cloud := Node3D.new()
		var angle := TAU * float(i) / 7.0 + rng.randf_range(-0.3, 0.3)
		var dist := rng.randf_range(30.0, 45.0)
		cloud.position = Vector3(cos(angle) * dist, rng.randf_range(16.0, 23.0), sin(angle) * dist)
		add_child(cloud)
		for j in 4:
			var puff := MeshInstance3D.new()
			var puff_mesh := SphereMesh.new()
			var r := rng.randf_range(1.4, 2.6)
			puff_mesh.radius = r
			puff_mesh.height = r * 1.5
			puff.mesh = puff_mesh
			puff.material_override = mat
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			puff.position = Vector3(rng.randf_range(-2.2, 2.2), rng.randf_range(-0.4, 0.4),
				rng.randf_range(-1.2, 1.2))
			cloud.add_child(puff)


func _compute_spawns() -> void:
	hunter_spawn = Vector3(0, 1.2, 0)
	var ring := ARENA_HALF - 2.5
	for i in 8:
		var angle := TAU * float(i) / 8.0
		hider_spawns.append(Vector3(cos(angle) * ring, 1.2, sin(angle) * ring))


func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = 0.5
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source_geometry, nav_region)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)
	nav_region.navigation_mesh = nav_mesh
