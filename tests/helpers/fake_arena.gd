extends Node3D

## Stand-in for Arena.gd that publishes the three things the rest of the game
## reads off it, without building 500 lines of procedural playground.

var hunter_spawn: Vector3 = Vector3(0, 1.2, 0)
var hider_spawns: Array[Vector3] = [
	Vector3(10.5, 1.2, 0.0),
	Vector3(0.0, 1.2, 10.5),
	Vector3(-10.5, 1.2, 0.0),
	Vector3(0.0, 1.2, -10.5),
]
var hiding_spots: Array[Vector3] = [
	Vector3(5.5, 1.0, 5.0),
	Vector3(-6.0, 1.0, 4.0),
	Vector3(1.5, 1.0, -7.5),
]


func _ready() -> void:
	add_to_group("arena_root")
