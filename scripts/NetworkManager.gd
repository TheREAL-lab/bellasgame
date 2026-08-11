extends Node

## Hosting/joining plus player spawning. Spawning goes through the
## MultiplayerSpawner's custom spawn function so that identity -- id, name, bot
## flag, cosmetic slot, chosen squishy and perks -- is replicated to every peer,
## not just set locally on the server.

signal player_list_changed
signal connection_failed
signal connected_to_server

const PORT := 8910
const MAX_HUMAN_PLAYERS := 8
const BOT_COUNT := 100
const AI_ID_BASE := -1

## Enough names that a hundred bots rarely repeat, and when they do they get a
## number, because "Jellybean 2" is funnier than two Jellybeans.
const BOT_NAMES := [
	"Marshmallow", "Bubblegum", "Jellybean", "Pudding", "Waffles", "Noodle",
	"Pickle", "Muffin", "Pancake", "Sprinkle", "Doughnut", "Custard",
	"Biscuit", "Truffle", "Toffee", "Popcorn", "Gumdrop", "Nugget",
	"Cupcake", "Peaches", "Pumpkin", "Butterbean", "Crumpet", "Sherbet",
	"Macaroon", "Brownie", "Fudge", "Cookie", "Tapioca", "Wafer",
	"Blueberry", "Cinnamon", "Nutmeg", "Parsnip", "Radish", "Turnip",
	"Squash", "Beetroot", "Cabbage", "Sausage",
]

var player_names: Dictionary = {}    # id -> String (server truth, mirrored to clients)
var player_slots: Dictionary = {}    # id -> cosmetic slot (server truth; rides along with each spawn)
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


## Returns false if the port is already taken -- usually a second copy of the
## game already running. The caller must not show the lobby in that case.
func host_game(player_name: String) -> bool:
	local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_HUMAN_PLAYERS)
	if err != OK:
		push_error("Failed to host game: %s" % err)
		connection_failed.emit()
		return false
	multiplayer.multiplayer_peer = peer
	is_hosting = true
	player_names[1] = player_name
	_spawn_player(1, player_name, false, SaveData.chosen_species, SaveData.chosen_color,
		SaveData.owned_perks)
	_spawn_ai_bots()
	player_list_changed.emit()
	return true


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


func human_count() -> int:
	var count := 0
	for id in player_names.keys():
		if id > 0:
			count += 1
	return count


func _on_connected_to_server() -> void:
	# Your wallet lives on your own machine, so the host has to be told what you
	# picked and what you own; it cannot look it up.
	_submit_profile.rpc_id(1, local_player_name, SaveData.chosen_species,
		SaveData.chosen_color, SaveData.owned_perks)
	connected_to_server.emit()


@rpc("any_peer", "call_local", "reliable")
func _submit_profile(pname: String, species: int, color: int, perks: Array) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	player_names[sender_id] = pname
	_spawn_player(sender_id, pname, false, species, color, perks)
	_sync_roster.rpc(player_names)


@rpc("authority", "call_local", "reliable")
func _sync_roster(roster: Dictionary) -> void:
	player_names = roster
	player_list_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass    # Spawning waits until the peer submits its profile.


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var node = players.get(id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	players.erase(id)
	player_names.erase(id)
	player_slots.erase(id)
	MatchManager.on_player_removed(id)
	_sync_roster.rpc(player_names)


func _on_connection_failed() -> void:
	connection_failed.emit()


func _on_server_disconnected() -> void:
	connection_failed.emit()


func _spawn_player(id: int, pname: String, is_bot: bool, species: int = -1,
		color: int = -1, perks: Array = []) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		return
	var spawner := get_tree().get_first_node_in_group("player_spawner") as MultiplayerSpawner
	if spawner == null:
		push_error("NetworkManager: no MultiplayerSpawner found in scene tree")
		return
	spawner.spawn({
		"id": id, "name": pname, "bot": is_bot, "slot": _claim_slot(id),
		"species": species, "color": color, "perks": perks,
	})
	MatchManager.on_player_added(id, is_bot)


## Which squishy you get when you haven't chosen one. The server hands these out
## instead of letting each player derive one from its own peer id -- joining
## peers get arbitrary ids, so two of them could otherwise turn up as the same
## species in the same colour. Slots freed by a leaver are reused.
func _claim_slot(id: int) -> int:
	if player_slots.has(id):
		return player_slots[id]
	var taken: Array = player_slots.values()
	var slot := 0
	while taken.has(slot):
		slot += 1
	player_slots[id] = slot
	return slot


func _spawn_ai_bots() -> void:
	for i in range(BOT_COUNT):
		var bot_id := AI_ID_BASE - i
		var bot_name: String = BOT_NAMES[i % BOT_NAMES.size()]
		var wrap := i / BOT_NAMES.size()
		if wrap > 0:
			bot_name = "%s %d" % [bot_name, wrap + 1]
		player_names[bot_id] = bot_name
		_spawn_player(bot_id, bot_name, true)
