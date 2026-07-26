extends Node3D

## The hide-and-seek level: bakes AI navigation at runtime from the static
## obstacle geometry, and exposes a few good hiding-spot positions to bots.

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D

var hiding_spots: Array[Vector3] = [
	Vector3(4.5, 1.0, 4.5),
	Vector3(-5.5, 1.0, 3.0),
	Vector3(0.0, 1.0, -6.5),
	Vector3(7.0, 1.0, -3.5),
	Vector3(-7.5, 1.0, -5.5),
	Vector3(3.0, 1.0, 7.5),
	Vector3(-3.5, 1.0, -1.5),
]


func _ready() -> void:
	add_to_group("arena_root")
	$Players.add_to_group("players_container")
	_bake_navigation()


func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = 0.4
	nav_mesh.agent_height = 1.8
	nav_mesh.agent_max_climb = 0.4
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.filter_walkable_low_height_spans = false
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source_geometry, nav_region)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)
	nav_region.navigation_mesh = nav_mesh
