class_name Weapons
extends RefCounted

## Every weapon in the game, as one table. Add a row and it turns up in the loot
## rolls, on the island, and in bot hands -- there is nowhere else to edit.
## Models are built from primitives like everything else in this project.

enum Kind { MELEE, RANGED }

## Tier is both power and rarity: 0 is what you land holding, 3 is the stuff you
## hope is inside a crate. WEIGHTS below decides how often each tier drops.
const TABLE := [
	{
		"id": "bonker", "name": "Foam Bonker", "tier": 0, "kind": Kind.MELEE,
		"damage": 16.0, "cooldown": 0.55, "reach": 2.8, "pellets": 1, "spread": 0.0,
		"color": Color(1.0, 0.55, 0.78), "shape": "bonker",
	},
	{
		"id": "lolly", "name": "Lollipop Hammer", "tier": 1, "kind": Kind.MELEE,
		"damage": 30.0, "cooldown": 0.7, "reach": 3.1, "pellets": 1, "spread": 0.0,
		"color": Color(1.0, 0.4, 0.55), "shape": "hammer",
	},
	{
		"id": "bubble", "name": "Bubble Blaster", "tier": 1, "kind": Kind.RANGED,
		"damage": 9.0, "cooldown": 0.15, "reach": 26.0, "pellets": 1, "spread": 0.035,
		"color": Color(0.45, 0.8, 1.0), "shape": "blaster",
	},
	{
		"id": "popper", "name": "Popcorn Popper", "tier": 2, "kind": Kind.RANGED,
		"damage": 7.0, "cooldown": 0.85, "reach": 13.0, "pellets": 6, "spread": 0.11,
		"color": Color(1.0, 0.83, 0.35), "shape": "popper",
	},
	{
		"id": "sprinkler", "name": "Sprinkle Rifle", "tier": 2, "kind": Kind.RANGED,
		"damage": 24.0, "cooldown": 0.6, "reach": 45.0, "pellets": 1, "spread": 0.012,
		"color": Color(0.55, 0.9, 0.55), "shape": "rifle",
	},
	{
		"id": "zapper", "name": "Star Zapper", "tier": 3, "kind": Kind.RANGED,
		"damage": 8.0, "cooldown": 0.1, "reach": 30.0, "pellets": 1, "spread": 0.05,
		"color": Color(0.78, 0.6, 1.0), "shape": "zapper",
	},
	{
		"id": "rainbow", "name": "Rainbow Cannon", "tier": 3, "kind": Kind.RANGED,
		"damage": 46.0, "cooldown": 1.2, "reach": 40.0, "pellets": 1, "spread": 0.006,
		"color": Color(1.0, 0.66, 0.42), "shape": "cannon",
	},
]

## How likely each tier is to be what a ground spawn rolls. Tier 0 never drops --
## you already have one, finding another would be a disappointment.
const WEIGHTS := [0, 52, 33, 15]

const STARTING_ID := "bonker"


static func by_id(id: String) -> Dictionary:
	for def in TABLE:
		if def.id == id:
			return def
	return TABLE[0]


static func starting() -> Dictionary:
	return by_id(STARTING_ID)


## Rolls a tier off WEIGHTS, then picks evenly inside it, so adding a new weapon
## to a tier makes that tier more varied rather than more common.
static func roll(rng: RandomNumberGenerator) -> Dictionary:
	var total := 0
	for w in WEIGHTS:
		total += w
	var pick := rng.randi_range(1, total)
	var tier := 0
	for i in WEIGHTS.size():
		pick -= WEIGHTS[i]
		if pick <= 0:
			tier = i
			break

	var candidates: Array = TABLE.filter(func(d): return d.tier == tier)
	if candidates.is_empty():
		return starting()
	return candidates[rng.randi() % candidates.size()]


static func dps(def: Dictionary) -> float:
	return def.damage * float(def.pellets) / maxf(def.cooldown, 0.01)


## Bots and the walk-over pickup both need "is this an upgrade?", and tier alone
## is the answer a five-year-old would give. Ties break on damage per second.
static func is_upgrade(candidate: Dictionary, held: Dictionary) -> bool:
	if candidate.tier != held.tier:
		return candidate.tier > held.tier
	return dps(candidate) > dps(held)


static func _mat(color: Color, rough: float = 0.4) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


static func _part(parent: Node3D, mesh: Mesh, mat: StandardMaterial3D,
		pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	# Weapons are small and always near the character they hang off, so they are
	# the first thing worth dropping when a hundred squishies are on screen.
	mi.visibility_range_end = 45.0
	parent.add_child(mi)
	return mi


static func _cyl(radius: float, height: float, segments: int = 8) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segments
	return m


static func _ball(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 10
	m.rings = 6
	return m


static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


## Builds the held model. The barrel points down -Z so the holder can just aim
## its whole hand and have the muzzle follow.
static func build_model(def: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "WeaponModel"
	var body := _mat(def.color, 0.35)
	var grip := _mat(Color(0.36, 0.32, 0.42), 0.6)
	var trim := _mat(Color(0.99, 0.98, 1.0), 0.25)

	match def.shape:
		"bonker":
			_part(root, _cyl(0.035, 0.5), grip, Vector3(0, 0, 0.1), Vector3(PI * 0.5, 0, 0))
			_part(root, _ball(0.15), body, Vector3(0, 0, -0.22))
		"hammer":
			_part(root, _cyl(0.04, 0.62), grip, Vector3(0, 0, 0.14), Vector3(PI * 0.5, 0, 0))
			_part(root, _box(Vector3(0.3, 0.26, 0.26)), body, Vector3(0, 0, -0.26))
			_part(root, _ball(0.07), trim, Vector3(0, 0.15, -0.26))
		"blaster":
			_part(root, _box(Vector3(0.14, 0.2, 0.16)), body, Vector3(0, -0.04, 0.08))
			_part(root, _cyl(0.06, 0.34), body, Vector3(0, 0.04, -0.16), Vector3(PI * 0.5, 0, 0))
			_part(root, _ball(0.075), trim, Vector3(0, 0.04, -0.33))
		"popper":
			_part(root, _box(Vector3(0.16, 0.18, 0.2)), body, Vector3(0, -0.03, 0.1))
			_part(root, _cyl(0.11, 0.4, 10), body, Vector3(0, 0.03, -0.18), Vector3(PI * 0.5, 0, 0))
			_part(root, _cyl(0.13, 0.07, 10), trim, Vector3(0, 0.03, -0.37), Vector3(PI * 0.5, 0, 0))
		"rifle":
			_part(root, _box(Vector3(0.11, 0.16, 0.26)), grip, Vector3(0, -0.02, 0.16))
			_part(root, _cyl(0.045, 0.78), body, Vector3(0, 0.05, -0.24), Vector3(PI * 0.5, 0, 0))
			_part(root, _box(Vector3(0.06, 0.07, 0.14)), trim, Vector3(0, 0.13, -0.02))
		"zapper":
			_part(root, _box(Vector3(0.12, 0.17, 0.18)), grip, Vector3(0, -0.03, 0.09))
			_part(root, _cyl(0.035, 0.44, 6), body, Vector3(0, 0.05, -0.2), Vector3(PI * 0.5, 0, 0))
			var orb := _part(root, _ball(0.1), body, Vector3(0, 0.05, -0.42))
			var glow := _mat(def.color, 0.1)
			glow.emission_enabled = true
			glow.emission = def.color
			glow.emission_energy_multiplier = 2.0
			orb.material_override = glow
		"cannon":
			_part(root, _box(Vector3(0.16, 0.2, 0.24)), grip, Vector3(0, -0.03, 0.14))
			var barrel := CylinderMesh.new()
			barrel.top_radius = 0.19
			barrel.bottom_radius = 0.1
			barrel.height = 0.6
			barrel.radial_segments = 12
			_part(root, barrel, body, Vector3(0, 0.05, -0.26), Vector3(PI * 0.5, 0, 0))
			for i in 3:
				var ring_mat := _mat(Color.from_hsv(float(i) / 3.0, 0.7, 1.0), 0.3)
				_part(root, _cyl(0.14 + float(i) * 0.02, 0.05, 12), ring_mat,
					Vector3(0, 0.05, -0.34 - float(i) * 0.1), Vector3(PI * 0.5, 0, 0))
		_:
			_part(root, _ball(0.14), body, Vector3(0, 0, -0.16))
	return root
