extends Node

## Hosting/joining plus player spawning. Spawning goes through the
## MultiplayerSpawner's custom spawn function so that identity (id, name, bot
## flag) is replicated to every peer, not just set locally on the server.

signal player_list_changed
signal connection_failed
signal connected_to_server

const PORT := 8910
const MAX_HUMAN_PLAYERS := 8
const AI_BOT_COUNT := 3
const AI_ID_BASE := -1

var player_names: Dictionary = {}    # id -> String (server truth, mirrored to clients)
var players: Dictionary = {}         # id -> Player node, maintained on every peer
var local_player: Node3D = null
var local_player_name: String = "Player"
var is_hosting: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host_game(player_name: String) -> void:
	local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_HUMAN_PLAYERS)
	if err != OK:
		push_error("Failed to host game: %s" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	is_hosting = true
	player_names[1] = player_name
	_spawn_player(1, player_name, false)
	_spawn_ai_bots()
	player_list_changed.emit()


func join_game(address: String, player_name: String) -> void:
	local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		push_error("Failed to join game: %s" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer


func get_local_ip() -> String:
	for ip in IP.get_local_addresses():
		if ip.begins_with("192.") or ip.begins_with("10.") or ip.begins_with("172."):
			return ip
	return "127.0.0.1"


## Called by each Player as it enters the tree, on every peer.
func register_player(node: Node3D) -> void:
	players[node.player_id] = node
	if not node.is_bot and node.player_id == multiplayer.get_unique_id():
		local_player = node
	player_list_changed.emit()


func unregister_player(node: Node3D) -> void:
	if players.get(node.player_id) == node:
		players.erase(node.player_id)
	if local_player == node:
		local_player = null
	player_list_changed.emit()


func _on_connected_to_server() -> void:
	_submit_name.rpc_id(1, local_player_name)
	connected_to_server.emit()


@rpc("any_peer", "call_local", "reliable")
func _submit_name(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	player_names[sender_id] = pname
	_spawn_player(sender_id, pname, false)
	_sync_roster.rpc(player_names)


@rpc("authority", "call_local", "reliable")
func _sync_roster(roster: Dictionary) -> void:
	player_names = roster
	player_list_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass    # Spawning waits until the peer submits its name via _submit_name.


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var node = players.get(id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	players.erase(id)
	player_names.erase(id)
	GameManager.on_player_removed(id)
	_sync_roster.rpc(player_names)


func _on_connection_failed() -> void:
	connection_failed.emit()


func _on_server_disconnected() -> void:
	connection_failed.emit()


func _spawn_player(id: int, pname: String, is_bot: bool) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		return
	var spawner := get_tree().get_first_node_in_group("player_spawner") as MultiplayerSpawner
	if spawner == null:
		push_error("NetworkManager: no MultiplayerSpawner found in scene tree")
		return
	spawner.spawn({"id": id, "name": pname, "bot": is_bot})
	GameManager.on_player_added(id, is_bot)


func _spawn_ai_bots() -> void:
	var bot_names := ["Marshmallow", "Bubblegum", "Jellybean"]
	for i in range(AI_BOT_COUNT):
		var bot_id := AI_ID_BASE - i
		var bot_name: String = bot_names[i % bot_names.size()]
		player_names[bot_id] = bot_name
		_spawn_player(bot_id, bot_name, true)
