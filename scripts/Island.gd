extends Node3D

## Builds the island every match is fought on: one flat disc of grass ringed by
## sand and sea, scattered with the same primitive props the playground used.
##
## Everything is seeded off ISLAND_SEED, so the island is the same shape every
## time -- you can learn where the good loot lives, which is most of the fun of
## a battle royale -- while still being generated rather than hand-placed.

const ISLAND_RADIUS := 140.0     # grass; the playable part
const BEACH_WIDTH := 9.0         # sand ring you can still walk on
const SEA_RADIUS := 420.0
const ISLAND_SEED := 20260811

const PROP_COUNT := 380
const CAMP_COUNT := 14           # block clusters that act as loot hotspots
const MIN_PROP_GAP := 4.2

## Props stop drawing their fiddly bits at this range. With a hundred squishies
## and three hundred props on screen at once, detail you cannot see is the first
## thing that has to go.
const DETAIL_RANGE := 70.0

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D

var spawn_points: Array[Vector3] = []
var loot_spots: Array[Vector3] = []
var landmarks: Array[Vector3] = []       # where bots wander when they have nothing better to do

var _rng := RandomNumberGenerator.new()
var _placed: Array[Vector2] = []


func _ready() -> void:
	add_to_group("arena_root")
	$Players.add_to_group("players_container")
	$MultiplayerSpawner.add_to_group("player_spawner")
	$MultiplayerSpawner.spawn_function = _spawn_player_node

	_rng.seed = ISLAND_SEED

	# Order matters: anything that should block movement or pathing has to exist
	# before the bake, and anything purely decorative has to come after it.
	_build_ground()
	_build_boundary()
	_build_camps()
	_build_props()
	_compute_spawns()
	_bake_navigation()

	_build_sea()
	_scatter_flowers()
	_build_clouds()

	# The storm draws itself from MatchManager; it lives here so it is torn down
	# with the island rather than outliving the match.
	var storm := preload("res://scripts/Storm.gd").new()
	storm.name = "Storm"
	add_child(storm)

	var loot := preload("res://scripts/Loot.gd").new()
	loot.name = "Loot"
	add_child(loot)
	loot.build(loot_spots, ISLAND_SEED + 11)


## Runs on every peer with identical data, so player identity replicates.
func _spawn_player_node(data: Dictionary) -> Node:
	var player: Node3D = preload("res://scenes/Player.tscn").instantiate()
	player.name = str(data.id)
	player.player_id = data.id
	player.player_name = data.name
	player.is_bot = data.bot
	player.slot = data.slot
	player.species_override = data.species
	player.color_override = data.color
	player.perks = data.perks
	player.set_multiplayer_authority(1 if data.bot else int(data.id))
	return player


# --- building blocks -------------------------------------------------------

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


## Decoration hung off a prop: drawn, never collided with, and dropped entirely
## once it is far enough away to be a smudge.
func _add_detail(parent: Node3D, mesh: Mesh, mat: StandardMaterial3D,
		pos: Vector3, range_end: float = DETAIL_RANGE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.visibility_range_end = range_end
	parent.add_child(mi)
	return mi


func _disc(radius: float, height: float, segments: int = 48) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segments
	return m


## One collider for the whole island. Sand and grass are drawn on top of it as
## flat discs with no colliders of their own, so the navmesh sees a single clean
## surface instead of two overlapping ones.
func _build_ground() -> void:
	var full := ISLAND_RADIUS + BEACH_WIDTH
	var shape := CylinderShape3D.new()
	shape.radius = full
	shape.height = 2.0

	var body := StaticBody3D.new()
	body.position = Vector3(0, -1.0, 0)
	nav_region.add_child(body)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	var sand := MeshInstance3D.new()
	sand.mesh = _disc(full, 2.0, 64)
	sand.material_override = _make_material(Color(0.94, 0.87, 0.66), 1.0)
	body.add_child(sand)

	# Grass sits a hair proud of the sand so the shoreline reads as a lip.
	var grass := MeshInstance3D.new()
	grass.mesh = _disc(ISLAND_RADIUS, 2.04, 64)
	grass.material_override = _make_material(Color(0.42, 0.72, 0.42), 0.95)
	grass.position.y = 0.02
	body.add_child(grass)


## An invisible fence just inside the waterline. There is no swimming in this
## game, and walking into the sea forever is a sad way to lose.
func _build_boundary() -> void:
	var full := ISLAND_RADIUS + BEACH_WIDTH - 1.0
	var segments := 40
	var seg_len := TAU * full / float(segments) * 1.05
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		var shape := BoxShape3D.new()
		shape.size = Vector3(seg_len, 6.0, 1.0)

		var body := StaticBody3D.new()
		body.position = Vector3(cos(angle) * full, 3.0, sin(angle) * full)
		body.rotation.y = -angle + PI * 0.5
		nav_region.add_child(body)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)


func _far_enough(pos: Vector2, gap: float) -> bool:
	for other in _placed:
		if other.distance_to(pos) < gap:
			return false
	return true


## Rejection sampling: pick a spot, keep it only if nothing is already crowding
## it. Cheap, and it gives a much more natural scatter than a grid would.
func _pick_spot(max_radius: float, gap: float) -> Vector2:
	for _attempt in 24:
		var angle := _rng.randf_range(0.0, TAU)
		# sqrt keeps the scatter even instead of bunching everything in the middle
		var dist := sqrt(_rng.randf()) * max_radius
		var pos := Vector2(cos(angle) * dist, sin(angle) * dist)
		if _far_enough(pos, gap):
			_placed.append(pos)
			return pos
	return Vector2.ZERO


## Camps are the reason to run somewhere specific: a huddle of blocks with the
## good loot in the middle and something to duck behind when it goes wrong.
func _build_camps() -> void:
	for i in CAMP_COUNT:
		var centre := _pick_spot(ISLAND_RADIUS - 18.0, 26.0)
		if centre == Vector2.ZERO and i > 0:
			continue
		var hue := _rng.randf()
		var walls := _rng.randi_range(4, 6)
		for w in walls:
			var angle := TAU * float(w) / float(walls) + _rng.randf_range(-0.2, 0.2)
			var away := _rng.randf_range(3.0, 5.0)
			var size := _rng.randf_range(2.0, 3.4)
			var at := centre + Vector2(cos(angle), sin(angle)) * away
			_build_block(Vector3(at.x, 0, at.y), size,
				Color.from_hsv(fmod(hue + float(w) * 0.06, 1.0), 0.42, 0.95))
			_placed.append(at)

		landmarks.append(Vector3(centre.x, 1.0, centre.y))
		# Three drops per camp, so two players landing on one still have to fight
		# over the third rather than both leaving happy.
		for l in 3:
			var angle := TAU * float(l) / 3.0 + _rng.randf()
			loot_spots.append(Vector3(
				centre.x + cos(angle) * 1.8, 0.6, centre.y + sin(angle) * 1.8))


func _build_props() -> void:
	var kinds := ["mushroom", "tree", "tree", "bush", "bush", "rock", "pillar", "candy"]
	for i in PROP_COUNT:
		var pos := _pick_spot(ISLAND_RADIUS - 3.0, MIN_PROP_GAP)
		if pos == Vector2.ZERO:
			continue
		var kind: String = kinds[_rng.randi() % kinds.size()]
		var size := _rng.randf_range(1.2, 2.1)
		var ground := Vector3(pos.x, 0.0, pos.y)
		match kind:
			"mushroom":
				_build_mushroom(ground, size, Color.from_hsv(_rng.randf(), 0.55, 1.0))
			"tree":
				_build_tree(ground, size * 1.15,
					Color.from_hsv(_rng.randf_range(0.24, 0.38), 0.55, _rng.randf_range(0.6, 0.8)))
			"bush":
				_build_bush(ground, size * 0.8,
					Color.from_hsv(_rng.randf_range(0.25, 0.36), 0.5, 0.75))
			"rock":
				_build_rock(ground, size, Color(0.66, 0.68, 0.78).lightened(_rng.randf() * 0.2))
			"pillar":
				_build_pillar(ground, size * 0.7, Color.from_hsv(_rng.randf(), 0.35, 1.0))
			"candy":
				_build_candy_cane(ground, size * 0.7, Color.from_hsv(_rng.randf(), 0.7, 1.0))

		# Half the props are worth walking to. With a hundred squishies
		# looking for a weapon at once, thin loot means most of them never
		# find one and the match is decided by who spawned near a camp.
		if i % 2 == 0:
			var away := Vector3(pos.x, 0, pos.y).normalized()
			if away.length_squared() < 0.01:
				away = Vector3.FORWARD
			loot_spots.append(ground + away * (size + 1.0) + Vector3.UP * 0.6)
		if i % 12 == 0:
			landmarks.append(ground + Vector3.UP)


func _build_mushroom(base: Vector3, size: float, color: Color) -> void:
	var stem_h: float = size * 1.1
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = size * 0.28
	stem_mesh.bottom_radius = size * 0.34
	stem_mesh.height = stem_h
	stem_mesh.radial_segments = 10
	var stem_shape := CylinderShape3D.new()
	stem_shape.radius = size * 0.34
	stem_shape.height = stem_h
	var stem_body := _add_body(nav_region, stem_mesh, stem_shape,
		Transform3D(Basis(), base + Vector3(0, stem_h * 0.5, 0)),
		_make_material(Color(0.98, 0.95, 0.88)))

	# The cap is decoration only -- no collider, so it never blocks navigation.
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = size * 0.85
	cap_mesh.height = size * 1.0
	cap_mesh.is_hemisphere = true
	cap_mesh.radial_segments = 14
	_add_detail(stem_body, cap_mesh, _make_material(color, 0.55),
		Vector3(0, stem_h * 0.5, 0), DETAIL_RANGE * 2.0)


func _build_block(base: Vector3, size: float, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, size * 1.4, size)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size, size * 1.4, size)
	var xform := Transform3D(Basis(Vector3.UP, _rng.randf_range(-0.4, 0.4)),
		base + Vector3(0, size * 0.7, 0))
	_add_body(nav_region, mesh, shape, xform, _make_material(color, 0.6))


func _build_pillar(base: Vector3, size: float, color: Color) -> void:
	var height: float = size * 2.8
	var mesh := CylinderMesh.new()
	mesh.top_radius = size * 0.55
	mesh.bottom_radius = size * 0.55
	mesh.height = height
	mesh.radial_segments = 10
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
	mesh.radial_segments = 12
	mesh.rings = 7
	var body := _add_body(nav_region, mesh, shape,
		Transform3D(Basis(), base + Vector3(0, size * 0.6, 0)),
		_make_material(color, 0.95))

	for i in 3:
		var lobe_mesh := SphereMesh.new()
		lobe_mesh.radius = size * 0.45
		lobe_mesh.height = size * 0.9
		lobe_mesh.radial_segments = 10
		lobe_mesh.rings = 6
		var angle := TAU * float(i) / 3.0
		_add_detail(body, lobe_mesh, _make_material(color.lightened(0.12), 0.95),
			Vector3(cos(angle) * size * 0.5, size * 0.25, sin(angle) * size * 0.5))


func _build_tree(base: Vector3, size: float, color: Color) -> void:
	var trunk_h: float = size * 1.7
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = size * 0.2
	trunk_mesh.bottom_radius = size * 0.28
	trunk_mesh.height = trunk_h
	trunk_mesh.radial_segments = 8
	var trunk_shape := CylinderShape3D.new()
	trunk_shape.radius = size * 0.28
	trunk_shape.height = trunk_h
	var trunk := _add_body(nav_region, trunk_mesh, trunk_shape,
		Transform3D(Basis(), base + Vector3(0, trunk_h * 0.5, 0)),
		_make_material(Color(0.62, 0.44, 0.32)))

	# Canopy blobs are decoration only, so pathing stays clean underneath.
	for i in 3:
		var blob_mesh := SphereMesh.new()
		var r: float = size * (0.95 - float(i) * 0.18)
		blob_mesh.radius = r
		blob_mesh.height = r * 1.7
		blob_mesh.radial_segments = 12
		blob_mesh.rings = 7
		_add_detail(trunk, blob_mesh, _make_material(color.lightened(float(i) * 0.08), 0.9),
			Vector3(sin(float(i) * 2.1) * size * 0.16,
				trunk_h * 0.5 + size * (0.55 + float(i) * 0.62),
				cos(float(i) * 2.1) * size * 0.16),
			DETAIL_RANGE * 2.5)


func _build_rock(base: Vector3, size: float, color: Color) -> void:
	var shape := SphereShape3D.new()
	shape.radius = size * 0.7
	var mesh := SphereMesh.new()
	mesh.radius = size * 0.7
	mesh.height = size * 1.1
	mesh.radial_segments = 7
	mesh.rings = 4
	var body := _add_body(nav_region, mesh, shape,
		Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)),
			base + Vector3(0, size * 0.42, 0)),
		_make_material(color, 1.0))
	body.get_child(0).scale = Vector3(1.0, 0.8, 1.15)


func _build_candy_cane(base: Vector3, size: float, color: Color) -> void:
	var height: float = size * 3.4
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = size * 0.13
	pole_mesh.bottom_radius = size * 0.13
	pole_mesh.height = height
	pole_mesh.radial_segments = 8
	var pole_shape := CylinderShape3D.new()
	pole_shape.radius = size * 0.22
	pole_shape.height = height
	var pole := _add_body(nav_region, pole_mesh, pole_shape,
		Transform3D(Basis(), base + Vector3(0, height * 0.5, 0)),
		_make_material(Color(0.99, 0.98, 1.0), 0.3))

	for i in 6:
		var stripe_mesh := CylinderMesh.new()
		stripe_mesh.top_radius = size * 0.145
		stripe_mesh.bottom_radius = size * 0.145
		stripe_mesh.height = height * 0.075
		stripe_mesh.radial_segments = 8
		var stripe := _add_detail(pole, stripe_mesh, _make_material(color, 0.3),
			Vector3(0, -height * 0.42 + float(i) * height * 0.16, 0))
		stripe.rotation.z = 0.35


func _build_sea() -> void:
	var water := MeshInstance3D.new()
	water.mesh = _disc(SEA_RADIUS, 0.5, 64)
	var mat := _make_material(Color(0.32, 0.6, 0.92), 0.08)
	mat.metallic = 0.4
	water.material_override = mat
	water.position.y = -0.35
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


## Flowers are one MultiMesh so a few hundred of them cost a single draw call.
func _scatter_flowers() -> void:
	var petal_colors := [
		Color(1.0, 0.35, 0.55), Color(1.0, 0.75, 0.2),
		Color(0.72, 0.45, 1.0), Color(1.0, 0.55, 0.75),
		Color(0.35, 0.62, 0.35), Color(0.98, 0.98, 1.0),
	]
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.16
	mesh.bottom_radius = 0.16
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

	var rng := RandomNumberGenerator.new()
	rng.seed = ISLAND_SEED + 7
	var count := 900
	multimesh.instance_count = count
	for i in count:
		var angle := rng.randf_range(0.0, TAU)
		var dist := sqrt(rng.randf()) * (ISLAND_RADIUS - 1.0)
		var s := rng.randf_range(0.6, 1.4)
		multimesh.set_instance_transform(i, Transform3D(
			Basis().scaled(Vector3(s, 1.0, s)),
			Vector3(cos(angle) * dist, 0.04, sin(angle) * dist)))
		multimesh.set_instance_color(i, petal_colors[rng.randi() % petal_colors.size()])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 60.0
	add_child(mmi)


func _build_clouds() -> void:
	var mat := _make_material(Color(1, 1, 1), 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = ISLAND_SEED + 99
	for i in 14:
		var cloud := Node3D.new()
		var angle := TAU * float(i) / 14.0 + rng.randf_range(-0.3, 0.3)
		var dist := rng.randf_range(90.0, 170.0)
		cloud.position = Vector3(cos(angle) * dist, rng.randf_range(38.0, 62.0), sin(angle) * dist)
		add_child(cloud)
		for j in 4:
			var puff_mesh := SphereMesh.new()
			var r := rng.randf_range(4.0, 8.0)
			puff_mesh.radius = r
			puff_mesh.height = r * 1.5
			puff_mesh.radial_segments = 10
			puff_mesh.rings = 6
			var puff := _add_detail(cloud, puff_mesh, mat, Vector3(
				rng.randf_range(-6.0, 6.0), rng.randf_range(-1.0, 1.0),
				rng.randf_range(-4.0, 4.0)), 400.0)
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A hundred and one squishies need a hundred and one places to land that are not
## on top of each other.
##
## This was rings to begin with, and rings are a trap: forty points on a circle
## of radius 42 sit six metres apart, so half the island opened every match
## already inside punching distance and three quarters of the cast were knocked
## out in the first thirty seconds. Scattering with a minimum gap gives everyone
## room to find a weapon before they find each other.
const SPAWN_GAP := 16.0
const SPAWN_COUNT := 130

func _compute_spawns() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = ISLAND_SEED + 3
	var attempts := 0
	while spawn_points.size() < SPAWN_COUNT and attempts < SPAWN_COUNT * 80:
		attempts += 1
		var angle := rng.randf_range(0.0, TAU)
		var dist := sqrt(rng.randf()) * (ISLAND_RADIUS - 6.0)
		var pos := Vector2(cos(angle) * dist, sin(angle) * dist)
		var clear := true
		for other in spawn_points:
			if Vector2(other.x, other.z).distance_to(pos) < SPAWN_GAP:
				clear = false
				break
		# _far_enough also keeps landings out of the props themselves.
		if clear and _far_enough(pos, 3.0):
			spawn_points.append(Vector3(pos.x, 1.2, pos.y))
	spawn_points.shuffle()


func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	# agent_radius has to be a whole number of cells or Recast rounds it up and
	# quietly fattens every bot: at cell 0.5 a 0.55 radius became 1.0, and bots
	# refused to walk through any gap narrower than two metres.
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.agent_radius = 0.5
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source_geometry, nav_region)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)
	nav_region.navigation_mesh = nav_mesh


## Nearest loot spot to a point, for bots deciding where to shop.
func nearest_loot_spot(from: Vector3, skip: Array = []) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for i in loot_spots.size():
		if skip.has(i):
			continue
		var d: float = from.distance_squared_to(loot_spots[i])
		if d < best_d:
			best_d = d
			best = loot_spots[i]
	return best
