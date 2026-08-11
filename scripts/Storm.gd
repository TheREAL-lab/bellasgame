extends Node3D

## The shrinking edge of the world, drawn. All the timing and damage lives in
## MatchManager -- this only reads it, so there is one source of truth about
## where the wall is and it is the same on every peer.
##
## Two pieces: a wall you see from the inside, and a soft patch on the ground
## showing where it is closing to. The patch matters most; "run to the blue bit"
## is a rule a five-year-old can hold in their head while being shot at.

const WALL_HEIGHT := 70.0
const WALL_COLOR := Color(0.78, 0.42, 1.0)
const SAFE_COLOR := Color(0.45, 0.9, 1.0)

var _wall: MeshInstance3D
var _target: MeshInstance3D


func _ready() -> void:
	var wall_mesh := CylinderMesh.new()
	wall_mesh.top_radius = 1.0
	wall_mesh.bottom_radius = 1.0
	wall_mesh.height = 1.0
	wall_mesh.radial_segments = 48
	wall_mesh.cap_top = false
	wall_mesh.cap_bottom = false

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(WALL_COLOR.r, WALL_COLOR.g, WALL_COLOR.b, 0.24)
	wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# We stand inside this cylinder, so the faces we need are the ones that would
	# normally be culled.
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wall_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wall_mat.emission_enabled = true
	wall_mat.emission = WALL_COLOR
	wall_mat.emission_energy_multiplier = 1.4

	_wall = MeshInstance3D.new()
	_wall.mesh = wall_mesh
	_wall.material_override = wall_mat
	_wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wall)

	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.05
	disc.radial_segments = 48

	var safe_mat := StandardMaterial3D.new()
	safe_mat.albedo_color = Color(SAFE_COLOR.r, SAFE_COLOR.g, SAFE_COLOR.b, 0.16)
	safe_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	safe_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_target = MeshInstance3D.new()
	_target.mesh = disc
	_target.material_override = safe_mat
	_target.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_target)

	visible = false


func _process(_delta: float) -> void:
	if MatchManager.state != MatchManager.State.PLAYING:
		visible = false
		return

	var island = get_parent()
	var island_radius: float = island.ISLAND_RADIUS if island != null else 100.0
	# Before the first circle the wall sits off the edge of the island; drawing it
	# then just puts a purple ring around the sea.
	if MatchManager.storm_radius >= island_radius:
		visible = false
		return

	visible = true
	var r: float = maxf(MatchManager.storm_radius, 0.5)
	_wall.position = Vector3(MatchManager.storm_center.x, WALL_HEIGHT * 0.5,
		MatchManager.storm_center.z)
	_wall.scale = Vector3(r, WALL_HEIGHT, r)

	if MatchManager.closing:
		_target.visible = true
		var to := MatchManager.next_center()
		_target.position = Vector3(to.x, 0.07, to.z)
		var tr: float = maxf(MatchManager.next_radius(), 0.5)
		_target.scale = Vector3(tr, 1.0, tr)
	else:
		_target.visible = false
