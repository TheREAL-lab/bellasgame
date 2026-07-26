extends Node3D

@onready var menu_panel: Control = $UI/MenuPanel
@onready var lobby_panel: Control = $UI/LobbyPanel
@onready var hud: Control = $UI/HUD
@onready var round_over_panel: Control = $UI/RoundOverPanel

@onready var name_edit: LineEdit = $UI/MenuPanel/VBox/NameEdit
@onready var host_button: Button = $UI/MenuPanel/VBox/HostButton
@onready var ip_edit: LineEdit = $UI/MenuPanel/VBox/JoinRow/IPEdit
@onready var join_button: Button = $UI/MenuPanel/VBox/JoinRow/JoinButton
@onready var status_label: Label = $UI/MenuPanel/VBox/StatusLabel

@onready var ip_label: Label = $UI/LobbyPanel/VBox/IPLabel
@onready var players_label: Label = $UI/LobbyPanel/VBox/PlayersLabel
@onready var start_button: Button = $UI/LobbyPanel/VBox/StartButton

@onready var role_label: Label = $UI/HUD/RoleLabel
@onready var timer_label: Label = $UI/HUD/TimerLabel
@onready var status_footer: Label = $UI/HUD/StatusFooter

@onready var result_label: Label = $UI/RoundOverPanel/VBox/ResultLabel
@onready var play_again_button: Button = $UI/RoundOverPanel/VBox/PlayAgainButton
@onready var back_button: Button = $UI/RoundOverPanel/VBox/BackToMenuButton


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	play_again_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(_on_back_pressed)

	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.player_list_changed.connect(_refresh_player_list)
	GameManager.state_changed.connect(_on_game_state_changed)
	GameManager.round_finished.connect(_on_round_finished)
	GameManager.player_tagged.connect(_on_player_tagged)

	_show_only(menu_panel)


func _process(_delta: float) -> void:
	if hud.visible:
		timer_label.text = "%d" % ceil(GameManager.time_left)


func _on_host_pressed() -> void:
	var pname := name_edit.text.strip_edges()
	if pname.is_empty():
		pname = "Player"
	NetworkManager.host_game(pname)
	ip_label.text = "Share this IP so others can join: %s" % NetworkManager.get_local_ip()
	ip_label.visible = true
	start_button.visible = true
	_show_only(lobby_panel)
	_refresh_player_list()


func _on_join_pressed() -> void:
	var pname := name_edit.text.strip_edges()
	if pname.is_empty():
		pname = "Player"
	var address := ip_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	status_label.text = "Connecting..."
	NetworkManager.join_game(address, pname)


func _on_connected_to_server() -> void:
	ip_label.visible = false
	start_button.visible = false
	_show_only(lobby_panel)


func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect. Check the IP and try again."
	_show_only(menu_panel)


func _refresh_player_list() -> void:
	var lines: Array = []
	for id in NetworkManager.player_names.keys():
		lines.append(NetworkManager.player_names[id])
	players_label.text = "\n".join(lines)


func _on_start_pressed() -> void:
	GameManager.start_round()


func _on_back_pressed() -> void:
	get_tree().quit()


func _on_game_state_changed(new_state: int) -> void:
	if new_state == GameManager.State.HIDING or new_state == GameManager.State.SEEKING:
		status_footer.text = ""
		_show_only(hud)
	_update_role_label(new_state)


func _update_role_label(new_state: int) -> void:
	if new_state == GameManager.State.HIDING:
		if GameManager.my_role == GameManager.Role.HUNTER:
			role_label.text = "You're the Hunter! Count while everyone hides..."
		else:
			role_label.text = "You're a Hider! Go find a squishy hiding spot!"
	elif new_state == GameManager.State.SEEKING:
		if GameManager.my_role == GameManager.Role.HUNTER:
			role_label.text = "Go find everyone!"
		else:
			role_label.text = "Stay hidden!"


func _on_player_tagged(id: int) -> void:
	if id == multiplayer.get_unique_id():
		status_footer.text = "You've been tagged!"


func _on_round_finished(hunter_won: bool) -> void:
	result_label.text = "The Hunter wins!" if hunter_won else "The Hiders win!"
	play_again_button.visible = NetworkManager.is_hosting
	_show_only(round_over_panel)


func _show_only(panel: Control) -> void:
	menu_panel.visible = panel == menu_panel
	lobby_panel.visible = panel == lobby_panel
	hud.visible = panel == hud
	round_over_panel.visible = panel == round_over_panel
