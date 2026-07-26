extends Node3D

## Menu / lobby / HUD flow, plus the round-over scoreboard.

const DANGER_COLOR := Color(1.0, 0.35, 0.3)

@onready var menu_panel: Control = $UI/MenuPanel
@onready var lobby_panel: Control = $UI/LobbyPanel
@onready var hud: Control = $UI/HUD
@onready var round_over_panel: Control = $UI/RoundOverPanel

@onready var name_edit: LineEdit = $UI/MenuPanel/Center/VBox/NameEdit
@onready var host_button: Button = $UI/MenuPanel/Center/VBox/HostButton
@onready var ip_edit: LineEdit = $UI/MenuPanel/Center/VBox/JoinRow/IPEdit
@onready var join_button: Button = $UI/MenuPanel/Center/VBox/JoinRow/JoinButton
@onready var status_label: Label = $UI/MenuPanel/Center/VBox/StatusLabel

@onready var ip_label: Label = $UI/LobbyPanel/Center/VBox/IPLabel
@onready var players_label: Label = $UI/LobbyPanel/Center/VBox/PlayersLabel
@onready var start_button: Button = $UI/LobbyPanel/Center/VBox/StartButton

@onready var role_label: Label = $UI/HUD/TopBar/RoleLabel
@onready var timer_label: Label = $UI/HUD/TopBar/TimerLabel
@onready var remaining_label: Label = $UI/HUD/TopBar/RemainingLabel
@onready var big_message: Label = $UI/HUD/BigMessage
@onready var name_status_footer: Label = $UI/HUD/StatusFooter
@onready var danger_vignette: ColorRect = $UI/HUD/DangerVignette

@onready var result_label: Label = $UI/RoundOverPanel/Center/VBox/ResultLabel
@onready var score_label: Label = $UI/RoundOverPanel/Center/VBox/ScoreLabel
@onready var play_again_button: Button = $UI/RoundOverPanel/Center/VBox/PlayAgainButton
@onready var back_button: Button = $UI/RoundOverPanel/Center/VBox/BackToMenuButton


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	play_again_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(func(): get_tree().quit())

	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.player_list_changed.connect(_refresh_player_list)
	GameManager.state_changed.connect(_on_game_state_changed)
	GameManager.round_finished.connect(_on_round_finished)
	GameManager.player_tagged.connect(_on_player_tagged)

	_show_only(menu_panel)

	if OS.get_cmdline_user_args().has("autotest"):
		_run_smoke_test()


## Dev helper: `godot --headless -- autotest` hosts a game against the bots and
## plays a round unattended, so the whole loop can be checked without a human.
func _run_smoke_test() -> void:
	await get_tree().process_frame
	NetworkManager.host_game("SmokeTester")
	print("[test] players spawned: ", NetworkManager.players.size())
	GameManager.start_round()
	await get_tree().create_timer(2.0).timeout
	print("[test] state=", GameManager.state, " hunter=", GameManager.hunter_id,
		" hiders=", GameManager.hider_ids)
	await get_tree().create_timer(3.0).timeout
	print("[test] bots moving: ", _bots_moving(), "/3")
	await _shoot("hiding")
	await get_tree().create_timer(14.0).timeout
	print("[test] seeking. remaining=", GameManager.hiders_remaining(),
		" positions ok=", _all_positions_valid())
	await _shoot("seeking")
	await get_tree().create_timer(20.0).timeout
	print("[test] later. remaining=", GameManager.hiders_remaining(),
		" tagged=", GameManager.tagged.size(), " state=", GameManager.state)
	get_tree().quit()


## Counts bots that are actually walking. A navmesh or authority regression
## shows up here as 0, which is exactly the bug that once froze every bot.
func _bots_moving() -> int:
	var moving := 0
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if is_instance_valid(p) and p.is_bot \
				and Vector2(p.velocity.x, p.velocity.z).length() > 0.5:
			moving += 1
	return moving


func _shoot(label: String) -> void:
	var dir := OS.get_environment("SHOT_DIR")
	if dir.is_empty():
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, label])


func _all_positions_valid() -> bool:
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if not is_instance_valid(p):
			return false
		var pos: Vector3 = p.global_position
		if pos.y < -5.0 or absf(pos.x) > 20.0 or absf(pos.z) > 20.0:
			print("[test] player %s out of bounds at %s" % [id, pos])
			return false
	return true


func _process(delta: float) -> void:
	if not hud.visible:
		return

	var seconds: int = int(ceil(GameManager.time_left))
	timer_label.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	remaining_label.text = "Still hiding: %d" % GameManager.hiders_remaining()

	# Last ten seconds of the hide phase count down big on screen.
	if GameManager.state == GameManager.State.HIDING and seconds <= 10:
		big_message.text = str(maxi(seconds, 1))
		big_message.modulate.a = lerp(big_message.modulate.a, 1.0, delta * 12.0)
	elif big_message.modulate.a > 0.01:
		big_message.modulate.a = lerp(big_message.modulate.a, 0.0, delta * 6.0)

	# Screen edges blush red as the Hunter closes in on you.
	var danger := GameManager.local_player_danger()
	danger_vignette.modulate.a = lerp(danger_vignette.modulate.a, danger * 0.55, delta * 5.0)


func _on_host_pressed() -> void:
	NetworkManager.host_game(_chosen_name())
	ip_label.text = "Others join with this address:\n%s" % NetworkManager.get_local_ip()
	ip_label.visible = true
	start_button.visible = true
	_show_only(lobby_panel)
	_refresh_player_list()


func _on_join_pressed() -> void:
	var address := ip_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	status_label.text = "Connecting..."
	NetworkManager.join_game(address, _chosen_name())


func _chosen_name() -> String:
	var pname := name_edit.text.strip_edges()
	return pname if not pname.is_empty() else "Player"


func _on_connected_to_server() -> void:
	ip_label.visible = false
	start_button.visible = false
	_show_only(lobby_panel)


func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect. Check the address and try again."
	_show_only(menu_panel)


func _refresh_player_list() -> void:
	var lines: Array = []
	for id in NetworkManager.player_names.keys():
		var tag := "  (computer)" if id < 0 else ""
		lines.append("%s%s" % [NetworkManager.player_names[id], tag])
	players_label.text = "\n".join(lines)


func _on_start_pressed() -> void:
	GameManager.start_round()


func _on_game_state_changed(new_state: int) -> void:
	match new_state:
		GameManager.State.HIDING:
			name_status_footer.text = ""
			danger_vignette.modulate.a = 0.0
			_show_only(hud)
			if GameManager.my_role == GameManager.Role.HUNTER:
				role_label.text = "You're IT! Cover your eyes..."
			else:
				role_label.text = "Run and hide!"
		GameManager.State.SEEKING:
			_show_only(hud)
			_flash_big("GO!")
			if GameManager.my_role == GameManager.Role.HUNTER:
				role_label.text = "Go find everyone!"
			else:
				role_label.text = "Stay hidden!"


func _flash_big(text: String) -> void:
	big_message.text = text
	big_message.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(0.9)
	tween.tween_property(big_message, "modulate:a", 0.0, 0.5)


func _on_player_tagged(id: int) -> void:
	var pname: String = NetworkManager.player_names.get(id, "Someone")
	if id == multiplayer.get_unique_id():
		name_status_footer.text = "You got caught! Cheer for the others!"
		_flash_big("Caught!")
	else:
		name_status_footer.text = "%s got caught!" % pname


func _on_round_finished(hunter_won: bool) -> void:
	var hunter_name: String = NetworkManager.player_names.get(GameManager.hunter_id, "The Hunter")
	result_label.text = ("%s found everyone!" % hunter_name) if hunter_won else "The hiders win!"
	score_label.text = _score_text()
	play_again_button.visible = NetworkManager.is_hosting
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_only(round_over_panel)


func _score_text() -> String:
	var entries: Array = []
	for id in GameManager.scores.keys():
		entries.append({"name": NetworkManager.player_names.get(id, "?"), "score": GameManager.scores[id]})
	entries.sort_custom(func(a, b): return a.score > b.score)
	var lines: Array = []
	for e in entries:
		lines.append("%s  —  %d" % [e.name, e.score])
	return "\n".join(lines)


func _show_only(panel: Control) -> void:
	menu_panel.visible = panel == menu_panel
	lobby_panel.visible = panel == lobby_panel
	hud.visible = panel == hud
	round_over_panel.visible = panel == round_over_panel
	if panel == hud:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
