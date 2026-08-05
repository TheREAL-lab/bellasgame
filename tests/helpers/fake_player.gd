extends CharacterBody3D

## Stand-in for a Player node. Carries just the surface GameManager and
## AIController actually touch (player_id, is_tagged, global_position, visual)
## without dragging in the camera, the squishy rig, or NetworkManager
## registration.
##
## Collision matches the real Player.tscn -- layer 2, mask 1, capsule of the
## same size -- so line-of-sight tests see what the game sees.

var player_id: int = 0
var player_name: String = "Fake"
var is_bot: bool = false
var is_tagged: bool = false

## AIController reads facing off `parent.visual`, exactly as the real Player does.
var visual: Node3D


static func make(id: int, position: Vector3, solid: bool = false) -> CharacterBody3D:
	var node: CharacterBody3D = load("res://tests/helpers/fake_player.gd").new()
	node.player_id = id
	node.name = "FakePlayer%d" % id
	node.collision_layer = 2
	node.collision_mask = 1
	node.position = position

	var body_visual := Node3D.new()
	body_visual.name = "Visual"
	node.add_child(body_visual)
	node.visual = body_visual

	if solid:
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.42
		capsule.height = 1.3
		shape.shape = capsule
		shape.position = Vector3(0, 0.65, 0)
		node.add_child(shape)

	return node


## Point the character's facing at a spot on the ground, the way `_move` does.
func face_towards(target: Vector3) -> void:
	var offset := target - global_position
	visual.rotation.y = atan2(offset.x, offset.z) + PI
