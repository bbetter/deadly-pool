extends RefCounted
class_name GameHUD
## Manages all HUD/UI elements: info label, power bar, scoreboard, kill feed,
## countdown overlay, win screen, music controls.
## Instantiated by GameManager; gm reference for accessing game state.

var gm: Node  # GameManager reference

# Core HUD elements
var info_label: Label
var power_bar_bg: ColorRect
var power_bar_fill: ColorRect
var power_label: Label
var win_label: Label
var restart_button: Button

# Kill feed
var kill_feed: VBoxContainer

# Scoreboard
var scoreboard_container: VBoxContainer
var _scoreboard_entries: Array[Dictionary] = []

# Music controls
var _music_mute_btn: Button
var _music_vol_label: Label
var _music_vol_down_btn: Button
var _music_vol_up_btn: Button

# Countdown
var countdown_overlay: ColorRect
var countdown_number: Label
var countdown_active: bool = true
var countdown_value: int = 3
var countdown_elapsed: float = 0.0


func _init(game_manager: Node) -> void:
	gm = game_manager


# --- Main HUD creation ---

func create(parent: CanvasLayer) -> void:
	info_label = Label.new()
	info_label.position = Vector2(20, 20)
	info_label.add_theme_font_size_override("font_size", 22)
	info_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	info_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	info_label.add_theme_constant_override("shadow_offset_x", 2)
	info_label.add_theme_constant_override("shadow_offset_y", 2)

	var my_slot := NetworkManager.my_slot
	if my_slot >= 0 and my_slot < gm.player_names.size():
		info_label.text = "You are %s - Click YOUR ball to launch!" % gm.player_names[my_slot]
		info_label.add_theme_color_override("font_color", gm.player_colors[my_slot])
	else:
		info_label.text = "Spectating..."
	parent.add_child(info_label)

	power_bar_bg = ColorRect.new()
	power_bar_bg.size = Vector2(300, 30)
	power_bar_bg.color = Color(0.1, 0.1, 0.1, 0.8)
	power_bar_bg.visible = false
	parent.add_child(power_bar_bg)

	power_bar_fill = ColorRect.new()
	power_bar_fill.size = Vector2(0, 26)
	power_bar_fill.color = Color(0.2, 0.8, 0.2)
	power_bar_fill.visible = false
	parent.add_child(power_bar_fill)

	power_label = Label.new()
	power_label.text = "POWER"
	power_label.add_theme_font_size_override("font_size", 14)
	power_label.add_theme_color_override("font_color", Color.WHITE)
	power_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	power_label.add_theme_constant_override("shadow_offset_x", 1)
	power_label.add_theme_constant_override("shadow_offset_y", 1)
	power_label.visible = false
	parent.add_child(power_label)

	win_label = Label.new()
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	win_label.add_theme_font_size_override("font_size", 48)
	win_label.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	win_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	win_label.add_theme_constant_override("shadow_offset_x", 3)
	win_label.add_theme_constant_override("shadow_offset_y", 3)
	win_label.visible = false
	parent.add_child(win_label)

	restart_button = Button.new()
	restart_button.text = "BACK TO MENU"
	restart_button.add_theme_font_size_override("font_size", 24)
	restart_button.visible = false
	restart_button.pressed.connect(_on_back_to_menu)
	parent.add_child(restart_button)

	# Kill feed (top-right corner)
	kill_feed = VBoxContainer.new()
	kill_feed.anchor_left = 1.0
	kill_feed.anchor_top = 0.0
	kill_feed.anchor_right = 1.0
	kill_feed.anchor_bottom = 0.0
	kill_feed.offset_left = -280
	kill_feed.offset_top = 20
	kill_feed.offset_right = -20
	kill_feed.offset_bottom = 320
	kill_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	kill_feed.add_theme_constant_override("separation", 6)
	parent.add_child(kill_feed)

	# Scoreboard (top-left, below info)
	scoreboard_container = VBoxContainer.new()
	scoreboard_container.position = Vector2(20, 90)
	scoreboard_container.add_theme_constant_override("separation", 4)
	parent.add_child(scoreboard_container)

	# Music controls (bottom-left)
	var music_row := HBoxContainer.new()
	music_row.anchor_left = 0.0
	music_row.anchor_top = 1.0
	music_row.anchor_right = 0.0
	music_row.anchor_bottom = 1.0
	music_row.offset_left = 12
	music_row.offset_top = -44
	music_row.offset_right = 250
	music_row.offset_bottom = -8
	music_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	music_row.add_theme_constant_override("separation", 4)
	parent.add_child(music_row)

	_music_mute_btn = Button.new()
	_music_mute_btn.custom_minimum_size = Vector2(36, 32)
	_music_mute_btn.add_theme_font_size_override("font_size", 16)
	_music_mute_btn.pressed.connect(_on_music_mute_pressed)
	music_row.add_child(_music_mute_btn)

	_music_vol_down_btn = Button.new()
	_music_vol_down_btn.text = "-"
	_music_vol_down_btn.custom_minimum_size = Vector2(32, 32)
	_music_vol_down_btn.add_theme_font_size_override("font_size", 16)
	_music_vol_down_btn.pressed.connect(_on_music_vol_down)
	music_row.add_child(_music_vol_down_btn)

	_music_vol_label = Label.new()
	_music_vol_label.custom_minimum_size = Vector2(40, 0)
	_music_vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_music_vol_label.add_theme_font_size_override("font_size", 14)
	_music_vol_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	music_row.add_child(_music_vol_label)

	_music_vol_up_btn = Button.new()
	_music_vol_up_btn.text = "+"
	_music_vol_up_btn.custom_minimum_size = Vector2(32, 32)
	_music_vol_up_btn.add_theme_font_size_override("font_size", 16)
	_music_vol_up_btn.pressed.connect(_on_music_vol_up)
	music_row.add_child(_music_vol_up_btn)

	_update_music_ui()


# --- Countdown ---

func create_countdown_overlay(parent: CanvasLayer) -> void:
	countdown_active = true
	countdown_value = 3
	countdown_elapsed = 0.0
	countdown_overlay = ColorRect.new()
	countdown_overlay.color = Color(0, 0, 0, 0.6)
	countdown_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(countdown_overlay)

	countdown_number = Label.new()
	countdown_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_number.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_number.text = "3"
	countdown_number.add_theme_font_size_override("font_size", 120)
	countdown_number.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	countdown_number.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	countdown_number.add_theme_constant_override("shadow_offset_x", 4)
	countdown_number.add_theme_constant_override("shadow_offset_y", 4)
	parent.add_child(countdown_number)


func update_countdown(delta: float) -> void:
	countdown_elapsed += delta
	if countdown_elapsed >= 1.0:
		countdown_elapsed -= 1.0
		countdown_value -= 1

		if countdown_value > 0:
			if countdown_number:
				countdown_number.text = str(countdown_value)
		elif countdown_value == 0:
			if countdown_number:
				countdown_number.text = "GO!"
				countdown_number.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		else:
			countdown_active = false
			if countdown_overlay:
				countdown_overlay.queue_free()
				countdown_overlay = null
			if countdown_number:
				countdown_number.queue_free()
				countdown_number = null


# --- Info label helpers ---

func set_info_default() -> void:
	if info_label == null:
		return
	var my_slot := NetworkManager.my_slot
	if my_slot >= 0 and my_slot < gm.player_names.size():
		info_label.text = "You are %s - Click YOUR ball to launch!" % gm.player_names[my_slot]
		info_label.add_theme_color_override("font_color", gm.player_colors[my_slot])


func set_info_text(text: String, color: Color) -> void:
	if info_label:
		info_label.text = text
		info_label.add_theme_color_override("font_color", color)


# --- Power bar ---

func show_power_bar() -> void:
	if power_bar_bg:
		power_bar_bg.visible = true
		power_bar_fill.visible = true
		power_label.visible = true
	position_power_bar()


func hide_power_bar() -> void:
	if power_bar_bg:
		power_bar_bg.visible = false
		power_bar_fill.visible = false
		power_label.visible = false


func update_power_bar(power_ratio: float) -> void:
	if power_bar_fill:
		power_bar_fill.size.x = 296.0 * power_ratio
		if power_ratio < 0.5:
			power_bar_fill.color = Color(power_ratio * 2.0, 0.8, 0.2)
		else:
			power_bar_fill.color = Color(0.9, 0.8 * (1.0 - power_ratio), 0.1)


func position_power_bar() -> void:
	var vp := gm.get_viewport().get_visible_rect().size
	if power_bar_bg:
		power_bar_bg.position = Vector2(vp.x / 2.0 - 150.0, vp.y - 60.0)
	if power_bar_fill:
		power_bar_fill.position = Vector2(vp.x / 2.0 - 148.0, vp.y - 58.0)
	if power_label:
		power_label.position = Vector2(vp.x / 2.0 - 30.0, vp.y - 85.0)


# --- Win UI ---

func show_game_over(winner_slot: int) -> void:
	hide_power_bar()

	if kill_feed and winner_slot >= 0:
		add_kill_feed_win_entry(winner_slot)

	if win_label:
		if winner_slot >= 0:
			var is_me := winner_slot == NetworkManager.my_slot
			if is_me:
				win_label.text = "YOU WIN!"
			else:
				win_label.text = "%s WINS!" % gm.player_names[winner_slot]
			win_label.add_theme_color_override("font_color", gm.player_colors[winner_slot])
		else:
			win_label.text = "DRAW!"
		win_label.visible = true
		_position_win_ui()

	if restart_button:
		restart_button.visible = true


func hide_game_over() -> void:
	if win_label:
		win_label.visible = false
		win_label.text = ""
	if restart_button:
		restart_button.visible = false
	# Clear old kill feed entries
	if kill_feed:
		for child in kill_feed.get_children():
			child.queue_free()


func _position_win_ui() -> void:
	var vp := gm.get_viewport().get_visible_rect().size
	if win_label:
		win_label.position = Vector2(0, vp.y / 2.0 - 60.0)
		win_label.size = Vector2(vp.x, 80.0)
	if restart_button:
		restart_button.position = Vector2(vp.x / 2.0 - 80.0, vp.y / 2.0 + 40.0)
		restart_button.size = Vector2(160, 50)


# --- Kill feed ---

func add_kill_feed_entry(slot: int) -> void:
	if kill_feed == null:
		return
	var color: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
	var pname: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	_add_feed_entry("[X] %s eliminated" % pname, color, Color(0, 0, 0, 0.6))


func add_disconnect_feed_entry(slot: int) -> void:
	if kill_feed == null:
		return
	var color: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
	var dim_color := Color(color.r * 0.7, color.g * 0.7, color.b * 0.7)
	var pname: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	_add_feed_entry("[!] %s disconnected" % pname, dim_color, Color(0.15, 0.1, 0.0, 0.6))


func add_kill_feed_win_entry(slot: int) -> void:
	if kill_feed == null:
		return
	var pname: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	_add_feed_entry_styled("* %s wins! *" % pname, Color(1, 0.85, 0.2), 18,
		Color(0.15, 0.12, 0.0, 0.8), Color(1, 0.85, 0.2, 0.6), false)


func _add_feed_entry(text: String, text_color: Color, bg_color: Color) -> void:
	_add_feed_entry_styled(text, text_color, 16, bg_color, Color.TRANSPARENT, true)


func _add_feed_entry_styled(text: String, text_color: Color, font_size: int,
		bg_color: Color, border_color: Color, auto_fade: bool) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	if border_color.a > 0.01:
		style.border_color = border_color
		style.border_width_left = 2
		style.border_width_right = 2
		style.border_width_top = 2
		style.border_width_bottom = 2
	panel.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", text_color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	panel.add_child(label)

	kill_feed.add_child(panel)

	if auto_fade:
		var tween := gm.create_tween()
		tween.tween_interval(5.0)
		tween.tween_property(panel, "modulate:a", 0.0, 1.0)
		tween.tween_callback(panel.queue_free)


# --- Scoreboard ---

func build_scoreboard() -> void:
	if scoreboard_container == null:
		return

	for child in scoreboard_container.get_children():
		child.queue_free()
	_scoreboard_entries.clear()

	for slot_idx in gm.PLAYER_COUNT:
		var has_ball: bool = slot_idx < gm.balls.size() and gm.balls[slot_idx] != null
		if not has_ball:
			continue

		var panel := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.5)
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_left = 4
		style.corner_radius_bottom_right = 4
		style.content_margin_left = 10
		style.content_margin_right = 14
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		panel.add_theme_stylebox_override("panel", style)

		var label := Label.new()
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		panel.add_child(label)

		scoreboard_container.add_child(panel)
		_scoreboard_entries.append({"panel": panel, "label": label, "slot": slot_idx, "style": style})

	update_scoreboard()


func update_scoreboard() -> void:
	for entry: Dictionary in _scoreboard_entries:
		var slot_idx: int = entry["slot"]
		var label: Label = entry["label"]
		var style: StyleBoxFlat = entry["style"]
		var color: Color = gm.player_colors[slot_idx] if slot_idx < gm.player_colors.size() else Color.WHITE
		var short_name := _short_name(slot_idx)
		var is_me := slot_idx == NetworkManager.my_slot
		var alive: bool = slot_idx in gm.alive_players

		var wins: int = NetworkManager.room_scores.get(slot_idx, 0)
		var wins_str := "  %dW" % wins if wins > 0 else ""

		if alive:
			var marker := "> " if is_me else "  "
			var pu_suffix := ""
			var pu_sym: String = gm.powerup_system.get_powerup_symbol(slot_idx)
			if pu_sym != "":
				pu_suffix = "  [%s]" % pu_sym
			label.text = "%s%s%s%s" % [marker, short_name, wins_str, pu_suffix]
			label.add_theme_color_override("font_color", color)
			style.bg_color = Color(color.r * 0.15, color.g * 0.15, color.b * 0.15, 0.6)
			if is_me:
				style.border_color = Color(color.r, color.g, color.b, 0.5)
				style.border_width_left = 2
				style.border_width_right = 0
				style.border_width_top = 0
				style.border_width_bottom = 0
			else:
				style.border_width_left = 0
				style.border_width_right = 0
				style.border_width_top = 0
				style.border_width_bottom = 0
		else:
			label.text = "  %s%s  [X]" % [short_name, wins_str]
			label.add_theme_color_override("font_color", Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 0.6))
			style.bg_color = Color(0, 0, 0, 0.3)
			style.border_width_left = 0
			style.border_width_right = 0
			style.border_width_top = 0
			style.border_width_bottom = 0


func _short_name(slot: int) -> String:
	if slot < 0 or slot >= gm.player_names.size():
		return "Player %d" % (slot + 1)
	var full: String = gm.player_names[slot]
	var paren := full.rfind(" (")
	if paren > 0:
		return full.substr(0, paren)
	return full


# --- Music controls ---

func _on_music_mute_pressed() -> void:
	MusicManager.toggle_mute()
	_update_music_ui()


func _on_music_vol_down() -> void:
	MusicManager.volume_down()
	_update_music_ui()


func _on_music_vol_up() -> void:
	MusicManager.volume_up()
	_update_music_ui()


func _update_music_ui() -> void:
	if _music_mute_btn == null:
		return
	_music_mute_btn.text = "M" if MusicManager.is_muted() else "♪"
	_music_vol_label.text = "%d%%" % MusicManager.get_volume_percent()
	var muted := MusicManager.is_muted()
	_music_vol_down_btn.disabled = muted
	_music_vol_up_btn.disabled = muted


func _on_back_to_menu() -> void:
	NetworkManager.disconnect_from_server()
	gm.get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
