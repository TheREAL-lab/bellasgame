extends Node3D

## Menu, shop, lobby, battle HUD and the results screen, plus the headless smoke
## test. All node references are full paths into Main.tscn, so renaming a UI node
## in the scene breaks this file -- change both together.

const HURT_FLASH := Color(1.0, 0.3, 0.3)
const STORM_FLASH := Color(0.78, 0.42, 1.0)

## Performance guard. If frames stay this expensive for this long, the game
## starts turning its own sparkle down rather than letting a laptop grind.
## Nothing here can damage a machine -- the worst a slow frame rate does is make
## the fans loud -- but a game that has become a slideshow is no fun either, and
## a five-year-old should not have to know what a graphics setting is.
const GUARD_BAD_MS := 40.0        # 25 fps
const GUARD_SAMPLE := 3.0
const GUARD_STAGES := 3

@onready var menu_panel: Control = $UI/MenuPanel
@onready var shop_panel: Control = $UI/ShopPanel
@onready var lobby_panel: Control = $UI/LobbyPanel
@onready var hud: Control = $UI/HUD
@onready var result_panel: Control = $UI/ResultPanel

@onready var name_edit: LineEdit = $UI/MenuPanel/Center/VBox/NameEdit
@onready var host_button: Button = $UI/MenuPanel/Center/VBox/HostButton
@onready var ip_edit: LineEdit = $UI/MenuPanel/Center/VBox/JoinRow/IPEdit
@onready var join_button: Button = $UI/MenuPanel/Center/VBox/JoinRow/JoinButton
@onready var shop_button: Button = $UI/MenuPanel/Center/VBox/ShopButton
@onready var bots_button: Button = $UI/MenuPanel/Center/VBox/BotsButton
@onready var status_label: Label = $UI/MenuPanel/Center/VBox/StatusLabel

@onready var shop_coins: Label = $UI/ShopPanel/Center/VBox/CoinsLabel
@onready var species_row: HBoxContainer = $UI/ShopPanel/Center/VBox/SpeciesRow
@onready var color_row: HBoxContainer = $UI/ShopPanel/Center/VBox/ColorRow
@onready var perk_list: VBoxContainer = $UI/ShopPanel/Center/VBox/PerkList
@onready var shop_status: Label = $UI/ShopPanel/Center/VBox/ShopStatus
@onready var shop_back_button: Button = $UI/ShopPanel/Center/VBox/ShopBackButton

@onready var ip_label: Label = $UI/LobbyPanel/Center/VBox/IPLabel
@onready var players_label: Label = $UI/LobbyPanel/Center/VBox/PlayersLabel
@onready var start_button: Button = $UI/LobbyPanel/Center/VBox/StartButton

@onready var alive_label: Label = $UI/HUD/TopBar/AliveLabel
@onready var storm_label: Label = $UI/HUD/TopBar/StormLabel
@onready var coins_label: Label = $UI/HUD/TopBar/CoinsLabel
@onready var weapon_label: Label = $UI/HUD/BottomBar/WeaponLabel
@onready var health_bar: ProgressBar = $UI/HUD/BottomBar/HealthBar
@onready var hover_bar: ProgressBar = $UI/HUD/BottomBar/HoverBar
@onready var big_message: Label = $UI/HUD/BigMessage
@onready var status_footer: Label = $UI/HUD/StatusFooter
@onready var vignette: ColorRect = $UI/HUD/DangerVignette

@onready var result_label: Label = $UI/ResultPanel/Center/VBox/ResultLabel
@onready var stats_label: Label = $UI/ResultPanel/Center/VBox/StatsLabel
@onready var payout_label: Label = $UI/ResultPanel/Center/VBox/PayoutLabel
@onready var play_again_button: Button = $UI/ResultPanel/Center/VBox/PlayAgainButton
@onready var back_button: Button = $UI/ResultPanel/Center/VBox/BackToMenuButton

var _last_health: float = 0.0
## Set only by the screenshot tour, which drives the panels itself and must not
## have the results screen thrown in front of the camera mid-shot.
var _touring: bool = false
var _hurt_flash: float = 0.0
var _smoothed_ms: float = 16.0
var _guard_timer: float = 0.0
var _guard_stage: int = 0


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	shop_button.pressed.connect(_open_shop)
	bots_button.pressed.connect(_on_bots_pressed)
	shop_back_button.pressed.connect(func(): _show_only(menu_panel))
	start_button.pressed.connect(_on_start_pressed)
	play_again_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(func(): get_tree().quit())

	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.player_list_changed.connect(_refresh_player_list)
	MatchManager.state_changed.connect(_on_match_state_changed)
	MatchManager.player_eliminated.connect(_on_player_eliminated)
	MatchManager.match_finished.connect(_on_match_finished)

	_refresh_bots_button()
	_show_only(menu_panel)

	if OS.get_cmdline_user_args().has("autotest"):
		_run_smoke_test()
	elif OS.get_cmdline_user_args().has("shots"):
		_run_screenshot_tour()


# --- smoke test ------------------------------------------------------------

## Dev helper: `godot --headless -- autotest` hosts a match against the full
## hundred bots and plays it out unattended, so the whole loop can be checked
## without a human. Prints the numbers that have historically gone wrong.
func _run_smoke_test() -> void:
	await get_tree().process_frame
	_check_ui()
	# The test always runs the heaviest case, whatever the menu is set to.
	SaveData.bot_count = 100
	var start := Time.get_ticks_msec()
	if not NetworkManager.host_game("SmokeTester"):
		print("[test] FAILED to host -- is the port already in use?")
		get_tree().quit()
		return
	print("[test] players spawned: ", NetworkManager.players.size(),
		" in ", Time.get_ticks_msec() - start, " ms")

	MatchManager.start_match()
	await get_tree().create_timer(3.0).timeout
	print("[test] state=", MatchManager.state, " alive=", MatchManager.alive_count())
	print("[test] bots moving: ", _bots_moving(), "/", SaveData.bot_count)
	print("[test] armed bots: ", _bots_armed(), " hatted: ", _bots_hatted())

	await _sample_frames(3.0)
	await get_tree().create_timer(25.0).timeout
	print("[test] 30s in. alive=", MatchManager.alive_count(),
		" storm r=", roundf(MatchManager.storm_radius),
		" positions ok=", _all_positions_valid())

	await get_tree().create_timer(45.0).timeout
	print("[test] 75s in. alive=", MatchManager.alive_count(),
		" storm r=", roundf(MatchManager.storm_radius),
		" armed=", _bots_armed(), " hatted=", _bots_hatted())
	await _sample_frames(3.0)

	await get_tree().create_timer(60.0).timeout
	print("[test] 135s in. alive=", MatchManager.alive_count(),
		" storm r=", roundf(MatchManager.storm_radius),
		" positions ok=", _all_positions_valid(),
		" state=", MatchManager.state)

	# Play it out. A match that never resolves -- two bots that cannot find each
	# other in the last circle -- is a real failure mode, so the test waits for a
	# winner rather than assuming one turns up.
	var waited := 0.0
	while MatchManager.state != MatchManager.State.MATCH_OVER and waited < 180.0:
		await get_tree().create_timer(5.0).timeout
		waited += 5.0
	if MatchManager.state == MatchManager.State.MATCH_OVER:
		print("[test] finished after %.0fs. winner=%s (%s) alive=%d" % [
			135.0 + waited, MatchManager.winner_id,
			NetworkManager.player_names.get(MatchManager.winner_id, "?"),
			MatchManager.alive_count()])
		print("[test] my placement=", MatchManager.placement_of(1),
			" of ", MatchManager.total_players,
			" kos=", MatchManager.knockouts_of(1),
			" coins=", SaveData.coins)
	else:
		print("[test] FAILED: no winner after %.0fs, %d still alive"
			% [135.0 + waited, MatchManager.alive_count()])
	get_tree().quit()


## Every panel gets shown and the shop gets built, because all of this file's
## node references are hard paths into Main.tscn -- renaming one node in the
## editor breaks this script, and it is the kind of break that otherwise only
## turns up when somebody clicks the button.
func _check_ui() -> void:
	_build_shop()
	print("[test] shop buttons: species=", species_row.get_child_count(),
		" colours=", color_row.get_child_count(),
		" perks=", perk_list.get_child_count())
	for panel in [menu_panel, shop_panel, lobby_panel, hud, result_panel]:
		_show_only(panel)
	_show_only(menu_panel)
	print("[test] panels ok")


## Counts bots that are actually walking. A navmesh or authority regression shows
## up here as 0, which is exactly the bug that once froze every bot.
func _bots_moving() -> int:
	var moving := 0
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if is_instance_valid(p) and p.is_bot and not p.is_down \
				and Vector2(p.velocity.x, p.velocity.z).length() > 0.5:
			moving += 1
	return moving


## Bots picking things up is the whole loot loop; if this stays at zero the
## pickup sweep or the loot table has broken.
func _bots_armed() -> int:
	var armed := 0
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if is_instance_valid(p) and p.is_bot and p.weapon.tier > 0:
			armed += 1
	return armed


func _bots_hatted() -> int:
	var hatted := 0
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if is_instance_valid(p) and p.is_bot and p.has_hat:
			hatted += 1
	return hatted


## Frame cost with a hundred bots thinking is the thing most likely to make this
## unplayable, so the test measures it rather than hoping.
func _sample_frames(seconds: float) -> void:
	var frames := 0
	var worst := 0.0
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		elapsed += dt
		frames += 1
		worst = maxf(worst, dt)
	print("[test] frame avg %.1f ms, worst %.1f ms (%d frames, %d alive)"
		% [elapsed / maxf(frames, 1) * 1000.0, worst * 1000.0, frames,
			MatchManager.alive_count()])


func _all_positions_valid() -> bool:
	var island = get_tree().get_first_node_in_group("arena_root")
	var limit: float = (island.ISLAND_RADIUS + island.BEACH_WIDTH + 4.0) if island else 120.0
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		if not is_instance_valid(p):
			return false
		var pos: Vector3 = p.global_position
		if pos.y < -5.0 or Vector2(pos.x, pos.z).length() > limit:
			print("[test] player %s out of bounds at %s" % [id, pos])
			return false
	return true


# --- screenshots -----------------------------------------------------------

## `SHOT_DIR=/some/folder godot --path . -- shots` plays a match and photographs
## it from a free camera, so the game can be looked at without anybody having to
## sit and play it. Needs a real renderer -- on a headless box that means
## `xvfb-run ... --rendering-method gl_compatibility`.
func _run_screenshot_tour() -> void:
	var dir := OS.get_environment("SHOT_DIR")
	if dir.is_empty():
		print("[shots] set SHOT_DIR to a folder first")
		get_tree().quit()
		return

	_touring = true
	await get_tree().process_frame
	name_edit.text = "Bella"
	await _shoot(dir, "1-menu")

	_build_shop()
	_show_only(shop_panel)
	await _shoot(dir, "2-shop")

	_show_only(menu_panel)
	NetworkManager.host_game("Bella")
	_show_only(lobby_panel)
	ip_label.text = "Others join with this address:\n192.168.1.42"
	_refresh_player_list()
	await _shoot(dir, "3-lobby")

	MatchManager.start_match()
	var island = get_tree().get_first_node_in_group("arena_root")
	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	camera.current = true

	await get_tree().create_timer(6.0).timeout
	_park(camera, Vector3(0, 150, 205), Vector3.ZERO)
	await _shoot(dir, "4-island")

	_park(camera, Vector3(38, 13, 44), Vector3(0, 2, 0))
	await _shoot(dir, "5-drop")

	# Down among them, where the props and the squishies read properly.
	var crowd := _busiest_spot()
	_park(camera, crowd + Vector3(7, 4.5, 7), crowd + Vector3.UP)
	await _shoot(dir, "6-groundlevel")

	await get_tree().create_timer(24.0).timeout
	var camp: Vector3 = island.landmarks[0] if not island.landmarks.is_empty() else Vector3.ZERO
	_park(camera, camp + Vector3(11, 6, 11), camp + Vector3.UP)
	await _shoot(dir, "7-camp")

	# Back to the player's own eyes so the HUD is shown doing its job.
	var me = NetworkManager.local_player
	if me != null and is_instance_valid(me):
		camera.current = false
		var player_cam := me.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
		if player_cam != null:
			player_cam.current = true
	_show_only(hud)
	await _shoot(dir, "8-hud")

	# Late enough that the wall is closing and the safe patch is on the ground.
	camera.current = true
	_show_only(hud)
	while MatchManager.storm_radius > 90.0 and MatchManager.state == MatchManager.State.PLAYING:
		await get_tree().create_timer(2.0).timeout
	var centre := MatchManager.storm_center
	_park(camera, centre + Vector3(0, 95, 150), centre)
	await _shoot(dir, "9-storm")

	_park(camera, centre + Vector3(30, 9, 30), centre + Vector3.UP * 2.0)
	await _shoot(dir, "10-stormwall")

	_show_only(result_panel)
	result_label.text = "You came #7 of 101"
	stats_label.text = "3 knocked out · 45 coins found on the island"
	payout_label.text = "+169 coins  (you now have 169)"
	await _shoot(dir, "11-results")

	print("[shots] done")
	get_tree().quit()


func _park(camera: Camera3D, at: Vector3, looking_at: Vector3) -> void:
	camera.global_position = at
	camera.look_at(looking_at, Vector3.UP)


## Where the most squishies are standing, so a ground-level shot has somebody in
## it rather than an empty meadow.
func _busiest_spot() -> Vector3:
	var best := Vector3.ZERO
	var best_count := -1
	for id in MatchManager.alive.keys():
		var node = NetworkManager.players.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var here: Vector3 = node.global_position
		var count := 0
		for other_id in MatchManager.alive.keys():
			var other = NetworkManager.players.get(other_id)
			if other != null and is_instance_valid(other) \
					and here.distance_to(other.global_position) < 16.0:
				count += 1
		if count > best_count:
			best_count = count
			best = here
	return best


func _shoot(dir: String, label: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [dir, label])
	print("[shots] ", label)


# --- menu and shop ---------------------------------------------------------

func _chosen_name() -> String:
	var pname := name_edit.text.strip_edges()
	return pname if not pname.is_empty() else "Player"


func _on_host_pressed() -> void:
	if not NetworkManager.host_game(_chosen_name()):
		status_label.text = "Couldn't start a game. Is Squishy Island already open in another window?"
		return
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


func _on_connected_to_server() -> void:
	ip_label.visible = false
	start_button.visible = false
	_show_only(lobby_panel)


func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect. Check the address and try again."
	_show_only(menu_panel)


func _refresh_player_list() -> void:
	var humans := NetworkManager.human_count()
	players_label.text = "%d of you, %d computer squishies waiting." % [
		humans, NetworkManager.players.size() - humans]


func _on_start_pressed() -> void:
	MatchManager.start_match()


func _on_bots_pressed() -> void:
	SaveData.cycle_bot_count()
	_refresh_bots_button()


func _refresh_bots_button() -> void:
	bots_button.text = "Computer squishies: %d" % SaveData.bot_count
	status_label.text = ("A hundred is the real thing. Start lower if the fans get loud."
		if SaveData.bot_count == 100 else "")


func _open_shop() -> void:
	_build_shop()
	_show_only(shop_panel)


## The shop is generated rather than laid out by hand, so adding a perk to
## SaveData.PERKS or a colour to the palette makes a button appear on its own.
func _build_shop() -> void:
	shop_coins.text = "%d coins" % SaveData.coins
	for row in [species_row, color_row, perk_list]:
		for child in row.get_children():
			child.queue_free()

	for i in Squishy.SPECIES_NAMES.size():
		var owned := SaveData.has_species(i)
		var button := Button.new()
		button.text = Squishy.SPECIES_NAMES[i] if owned else "%s\n%d" % [
			Squishy.SPECIES_NAMES[i], SaveData.SPECIES_COST]
		button.toggle_mode = false
		button.disabled = not owned and SaveData.coins < SaveData.SPECIES_COST
		if owned and SaveData.chosen_species == i:
			button.text = "> %s <" % Squishy.SPECIES_NAMES[i]
		button.pressed.connect(_on_species_pressed.bind(i))
		species_row.add_child(button)

	for i in Player.PALETTE.size():
		var owned := SaveData.has_color(i)
		var button := Button.new()
		button.custom_minimum_size = Vector2(56, 44)
		button.text = "*" if (owned and SaveData.chosen_color == i) else (
			"" if owned else str(SaveData.COLOR_COST))
		var style := StyleBoxFlat.new()
		style.bg_color = Player.PALETTE[i] if owned else Player.PALETTE[i].darkened(0.6)
		style.set_corner_radius_all(6)
		button.add_theme_stylebox_override("normal", style)
		button.disabled = not owned and SaveData.coins < SaveData.COLOR_COST
		button.pressed.connect(_on_color_pressed.bind(i))
		color_row.add_child(button)

	for perk in SaveData.PERKS:
		var owned := SaveData.has_perk(perk.id)
		var button := Button.new()
		button.text = "%s — %s%s" % [perk.name, perk.blurb,
			"  (owned)" if owned else "   [%d coins]" % perk.cost]
		button.disabled = owned or SaveData.coins < perk.cost
		button.pressed.connect(_on_perk_pressed.bind(perk.id))
		perk_list.add_child(button)


func _on_species_pressed(index: int) -> void:
	if SaveData.has_species(index):
		SaveData.choose_species(index)
		shop_status.text = "You'll drop in as a %s." % Squishy.SPECIES_NAMES[index]
	elif SaveData.buy("species", index):
		SaveData.choose_species(index)
		shop_status.text = "Unlocked the %s!" % Squishy.SPECIES_NAMES[index]
	else:
		shop_status.text = "Not enough coins yet."
	_build_shop()


func _on_color_pressed(index: int) -> void:
	if SaveData.has_color(index):
		SaveData.choose_color(index)
		shop_status.text = "Colour picked."
	elif SaveData.buy("color", index):
		SaveData.choose_color(index)
		shop_status.text = "New colour unlocked!"
	else:
		shop_status.text = "Not enough coins yet."
	_build_shop()


func _on_perk_pressed(id: String) -> void:
	shop_status.text = ("Bought it!" if SaveData.buy("perk", id) else "Not enough coins yet.")
	_build_shop()


# --- match ------------------------------------------------------------------

func _on_match_state_changed(new_state: int) -> void:
	if new_state != MatchManager.State.PLAYING:
		return
	status_footer.text = ""
	vignette.color.a = 0.0
	_last_health = 0.0
	_show_only(hud)
	_flash_big("DROP!")


func _on_player_eliminated(id: int, by_id: int) -> void:
	var me := multiplayer.get_unique_id()
	if id == me:
		_flash_big("Knocked out!")
		_show_results(false)
		return
	if by_id == me:
		status_footer.text = "You knocked out %s! (%d alive)" % [
			NetworkManager.player_names.get(id, "somebody"), MatchManager.alive_count()]


func _on_match_finished(winner: int) -> void:
	if winner == multiplayer.get_unique_id():
		_flash_big("You win!")
	_show_results(winner == multiplayer.get_unique_id())


## Coins are banked here, once, whether you won or came ninety-first. Anything
## you picked up on the island is added to what your placement earned.
func _show_results(won: bool) -> void:
	if _touring:
		return
	var me := multiplayer.get_unique_id()
	var placement := MatchManager.placement_of(me)
	var kos := MatchManager.knockouts_of(me)
	var found := 0
	var my_player = NetworkManager.local_player
	if my_player != null and is_instance_valid(my_player):
		found = my_player.coins_found

	var earned := SaveData.payout_for(kos, placement, MatchManager.total_players) + found
	SaveData.add_coins(earned)

	result_label.text = ("You won! Last squishy bouncing." if won
		else "You came #%d of %d" % [placement, MatchManager.total_players])
	stats_label.text = "%d knocked out · %d coins found on the island" % [kos, found]
	payout_label.text = "+%d coins  (you now have %d)" % [earned, SaveData.coins]
	if _guard_stage > 0:
		var at := SaveData.BOT_COUNT_CHOICES.find(SaveData.bot_count)
		var lower: int = SaveData.BOT_COUNT_CHOICES[maxi(0, at - 1)]
		payout_label.text += "\n(That was hard work for this machine — try %d squishies.)" % lower
	play_again_button.visible = NetworkManager.is_hosting
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_only(result_panel)


func _flash_big(text: String) -> void:
	big_message.text = text
	big_message.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(0.9)
	tween.tween_property(big_message, "modulate:a", 0.0, 0.5)


func _process(delta: float) -> void:
	if not hud.visible:
		return

	alive_label.text = "Alive: %d" % MatchManager.alive_count()
	storm_label.text = _storm_text()

	var me = NetworkManager.local_player
	if me == null or not is_instance_valid(me):
		return

	health_bar.max_value = me.max_health
	health_bar.value = me.health
	weapon_label.text = str(me.weapon.get("name", "Empty"))
	coins_label.text = "%d coins" % me.coins_found
	hover_bar.visible = me.has_hat
	hover_bar.value = me.hover_left / me.hover_capacity() * 100.0

	# Screen edges blush when you get hit, and glow purple when you are stood in
	# the storm losing health for it.
	if me.health < _last_health:
		_hurt_flash = 1.0
	_last_health = me.health
	_hurt_flash = maxf(0.0, _hurt_flash - delta * 2.2)

	# Set the tint and the alpha in one assignment. Writing `vignette.color =
	# HURT_FLASH` first and fading afterwards looks equivalent and is not: the
	# constants carry alpha 1.0, so the fade restarted from fully opaque every
	# frame and the whole game sat behind a pink sheet.
	var outside := MatchManager.distance_outside(me.global_position) > 0.0
	var target_alpha: float = 0.32 if outside else _hurt_flash * 0.4
	var tint: Color = STORM_FLASH if outside and _hurt_flash <= 0.0 else HURT_FLASH
	var faded := lerpf(vignette.color.a, target_alpha, clampf(delta * 6.0, 0.0, 1.0))
	vignette.color = Color(tint.r, tint.g, tint.b, faded)

	_tend_performance(delta)

	if outside and status_footer.text.is_empty():
		status_footer.text = "Get back inside the circle!"
	elif not outside and status_footer.text == "Get back inside the circle!":
		status_footer.text = ""


## Watches the frame rate and sheds load in stages if it stays bad. Each stage is
## reversible only by restarting, which is fine -- it never fires unless the
## machine is already struggling, and the alternative is a slideshow.
func _tend_performance(delta: float) -> void:
	_smoothed_ms = lerpf(_smoothed_ms, delta * 1000.0, 0.05)
	if _guard_stage >= GUARD_STAGES:
		return

	if _smoothed_ms < GUARD_BAD_MS:
		_guard_timer = maxf(0.0, _guard_timer - delta)
		return
	_guard_timer += delta
	if _guard_timer < GUARD_SAMPLE:
		return

	_guard_timer = 0.0
	_guard_stage += 1
	match _guard_stage:
		1:
			# Shadows first: the most expensive thing on screen that the game
			# plays exactly the same without.
			var sun := get_node_or_null("Island/SunLight")
			if sun != null:
				sun.shadow_enabled = false
			MatchManager.detail_scale = 0.6
			status_footer.text = "Turning the sparkle down a bit..."
		2:
			get_viewport().scaling_3d_scale = 0.75
			MatchManager.detail_scale = 0.4
			status_footer.text = "Still busy -- turning it down further..."
		3:
			get_viewport().scaling_3d_scale = 0.6
			MatchManager.detail_scale = 0.25
			status_footer.text = "Try fewer computer squishies from the menu next time."


func _storm_text() -> String:
	if MatchManager.phase_index < 0:
		return "Storm in %ds" % ceili(MatchManager.phase_time_left)
	if MatchManager.closing:
		return "Storm closing! %ds" % ceili(MatchManager.phase_time_left)
	if MatchManager.phase_time_left > 9000.0:
		return "Final circle"
	return "Next storm in %ds" % ceili(MatchManager.phase_time_left)


func _show_only(panel: Control) -> void:
	menu_panel.visible = panel == menu_panel
	shop_panel.visible = panel == shop_panel
	lobby_panel.visible = panel == lobby_panel
	hud.visible = panel == hud
	result_panel.visible = panel == result_panel
	if panel == hud:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
