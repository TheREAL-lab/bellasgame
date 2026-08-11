extends Node3D

## Everything lying on the ground: weapons, spinny hats and coins.
##
## Loot is deliberately *not* physics. A hundred and thirty Area3Ds testing
## themselves against a hundred and one bodies every frame is a lot of collision
## pairs for something a cheap distance check answers, so pickups are plain data
## with a mesh hanging off them and the server sweeps them a few times a second.
##
## The starting layout is seeded off the island, so it is identical on every peer
## without sending a single spawn packet; only *taking* something is replicated.

const PICKUP_RADIUS := 1.9
const SWEEP_INTERVAL := 0.2
const HAT_SHARE := 0.12          # roughly one spot in eight is a spinny hat
const COIN_SHARE := 0.22
const COINS_PER_PILE := 15
const BOB_SPEED := 2.2

var items: Array = []            # {kind, weapon_id, coins, pos, node, taken}

var _sweep_timer: float = 0.0
var _spin: float = 0.0


func _ready() -> void:
	add_to_group("loot")


## Called by the island once its loot spots are known. Same seed, same island,
## same loot -- learning where the good stuff spawns is half the game.
func build(spots: Array, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for spot in spots:
		var roll := rng.randf()
		if roll < HAT_SHARE:
			_add_item("hat", "", 0, spot)
		elif roll < HAT_SHARE + COIN_SHARE:
			_add_item("coins", "", COINS_PER_PILE + rng.randi_range(0, 10), spot)
		else:
			_add_item("weapon", Weapons.roll(rng).id, 0, spot)


func _add_item(kind: String, weapon_id: String, coins: int, pos: Vector3) -> int:
	var holder := Node3D.new()
	holder.position = pos
	add_child(holder)

	match kind:
		"weapon":
			var model := Weapons.build_model(Weapons.by_id(weapon_id))
			model.rotation.x = -PI * 0.25
			holder.add_child(model)
		"hat":
			holder.add_child(_build_hat_model())
		"coins":
			holder.add_child(_build_coin_model())

	items.append({
		"kind": kind, "weapon_id": weapon_id, "coins": coins,
		"pos": pos, "node": holder, "taken": false,
	})
	return items.size() - 1


## The spinny hat: a little cone with a propeller across the top. It is the same
## model that ends up on your head, so you always recognise one on the ground.
func _build_hat_model() -> Node3D:
	var root := Node3D.new()
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(1.0, 0.42, 0.5)
	cap_mat.roughness = 0.4

	var cap := MeshInstance3D.new()
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = 0.24
	cap_mesh.height = 0.26
	cap_mesh.is_hemisphere = true
	cap_mesh.radial_segments = 14
	cap.mesh = cap_mesh
	cap.material_override = cap_mat
	root.add_child(cap)

	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = 0.3
	brim_mesh.bottom_radius = 0.3
	brim_mesh.height = 0.03
	brim_mesh.radial_segments = 16
	brim.mesh = brim_mesh
	brim.material_override = cap_mat
	root.add_child(brim)

	var blade_mat := StandardMaterial3D.new()
	blade_mat.albedo_color = Color(0.45, 0.8, 1.0)
	blade_mat.roughness = 0.3
	var prop := Node3D.new()
	prop.name = "Propeller"
	prop.position.y = 0.3
	root.add_child(prop)
	for i in 2:
		var blade := MeshInstance3D.new()
		var blade_mesh := BoxMesh.new()
		blade_mesh.size = Vector3(0.42, 0.02, 0.09)
		blade.mesh = blade_mesh
		blade.material_override = blade_mat
		blade.rotation.y = PI * float(i) / 2.0
		prop.add_child(blade)
	return root


func _build_coin_model() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.82, 0.28)
	mat.roughness = 0.2
	mat.metallic = 0.6
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.75, 0.2)
	mat.emission_energy_multiplier = 0.4
	for i in 3:
		var coin := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.17
		mesh.bottom_radius = 0.17
		mesh.height = 0.045
		mesh.radial_segments = 14
		coin.mesh = mesh
		coin.material_override = mat
		coin.position = Vector3(0.0, float(i) * 0.05, 0.0)
		coin.rotation.z = 0.2 + float(i) * 0.1
		root.add_child(coin)
	return root


## Loot bobs and turns so it catches the eye across a field of flowers.
func _process(delta: float) -> void:
	_spin += delta * BOB_SPEED
	for item in items:
		if item.taken:
			continue
		var node: Node3D = item.node
		node.rotation.y = _spin
		node.position.y = item.pos.y + sin(_spin * 1.4 + item.pos.x) * 0.12

	if not multiplayer.is_server():
		return
	if MatchManager.state != MatchManager.State.PLAYING:
		return
	_sweep_timer -= delta
	if _sweep_timer > 0.0:
		return
	_sweep_timer = SWEEP_INTERVAL
	_sweep()


## One pass over living players against untaken loot. Cheap enough at these
## counts that a spatial index would be more code than it saves.
func _sweep() -> void:
	for id in MatchManager.alive.keys():
		var player = NetworkManager.players.get(id)
		if player == null or not is_instance_valid(player) or player.is_down:
			continue
		var index := nearest_index(player.global_position, PICKUP_RADIUS)
		if index < 0:
			continue
		if _wants(player, items[index]):
			take(index, id)


## Auto-pickup only takes what is plainly an improvement, so walking over a worse
## gun never robs you of the good one you are holding.
func _wants(player, item: Dictionary) -> bool:
	match item.kind:
		"coins":
			return true
		"hat":
			return not player.has_hat
		"weapon":
			return Weapons.is_upgrade(Weapons.by_id(item.weapon_id), player.weapon)
	return false


func nearest_index(from: Vector3, within: float) -> int:
	var best := -1
	var best_d := within * within
	for i in items.size():
		var item: Dictionary = items[i]
		if item.taken:
			continue
		var d: float = from.distance_squared_to(item.pos)
		if d < best_d:
			best_d = d
			best = i
	return best


## Server entry point. Everything that removes an item from the world goes
## through here so the index stays meaningful on every peer.
func take(index: int, player_id: int) -> void:
	if not multiplayer.is_server():
		return
	if index < 0 or index >= items.size() or items[index].taken:
		return
	_confirm_take.rpc(index, player_id)


@rpc("authority", "call_local", "reliable")
func _confirm_take(index: int, player_id: int) -> void:
	if index < 0 or index >= items.size():
		return
	var item: Dictionary = items[index]
	if item.taken:
		return
	item.taken = true
	item.node.visible = false

	var player = NetworkManager.players.get(player_id)
	if player == null or not is_instance_valid(player):
		return
	match item.kind:
		"weapon":
			player.equip(item.weapon_id)
		"hat":
			player.give_hat()
		"coins":
			player.collect_coins(int(item.coins))


## Dropping is replicated rather than seeded, because a death can happen
## anywhere. RPCs arrive in order, so every peer appends the same index.
@rpc("authority", "call_local", "reliable")
func drop(kind: String, weapon_id: String, coins: int, pos: Vector3) -> void:
	_add_item(kind, weapon_id, coins, pos)
