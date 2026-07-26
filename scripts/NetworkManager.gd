extends Node

## Handles hosting/joining and spawning players (human + AI) across the network.

signal player_list_changed
signal connection_failed
signal connected_to_server

const PORT := 8910
const MAX_HUMAN_PLAYERS := 2
const AI_BOT_COUNT := 3
const AI_ID_BASE := -1

var player_names: Dictionary = {} # id (int) -> String
var players: Dictionary = {} # id (int) -> Node3D, populated server-side
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


func _on_peer_connected(_id: int) -> void:
	pass # Spawning happens once the peer submits its name via _submit_name.


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		var node = players[id]
		if is_instance_valid(node):
			node.queue_free()
		players.erase(id)
	player_names.erase(id)
	GameManager.on_player_removed(id)
	player_list_changed.emit()


func _on_connection_failed() -> void:
	connection_failed.emit()


func _on_server_disconnected() -> void:
	connection_failed.emit()


func _spawn_player(id: int, pname: String, is_bot: bool) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		return
	var container := get_tree().get_first_node_in_group("players_container")
	if container == null:
		push_error("NetworkManager: no players_container found in scene tree")
		return
	var scene: PackedScene = preload("res://scenes/Player.tscn")
	var instance := scene.instantiate()
	instance.name = str(id)
	instance.player_id = id
	instance.player_name = pname
	instance.is_bot = is_bot
	instance.set_multiplayer_authority(1 if is_bot else id)
	container.add_child(instance, true)
	players[id] = instance
	GameManager.on_player_added(id, is_bot)
	player_list_changed.emit()


func _spawn_ai_bots() -> void:
	for i in range(AI_BOT_COUNT):
		var bot_id := AI_ID_BASE - i
		var bot_name := "Squishbot %d" % (i + 1)
		player_names[bot_id] = bot_name
		_spawn_player(bot_id, bot_name, true)
