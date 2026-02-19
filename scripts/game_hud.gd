extends RefCounted
class_name GameHUD
## Manages all HUD/UI elements: info label, power bar, scoreboard, kill feed,
## countdown overlay, win screen, music controls, toast notifications.
## Instantiated by GameManager; gm reference for accessing game state.

var gm: Node  # GameManager reference

# Style constants
const COLOR_GOLD := Color(1, 0.85, 0.2)
const COLOR_GOLD_DIM := Color(1, 0.85, 0.2, 0.5)
const COLOR_BG_DARK := Color(0.06, 0.06, 0.12, 0.75)
const COLOR_BG_PANEL := Color(0.08, 0.08, 0.15, 0.7)
const COLOR_BORDER_SUBTLE := Color(1, 1, 1, 0.12)
const COLOR_TEXT_DIM := Color(0.55, 0.55, 0.6)
const CORNER_RADIUS := 6
const SHADOW_COLOR := Color(0, 0, 0, 0.7)

# Helper to get tree (avoids parse error in Godot 4.6)
func _get_tree() -> SceneTree:
	return Engine.get_main_loop()

# Core HUD elements
var info_label: Label
var power_bar_bg: PanelContainer
var power_bar_fill: ColorRect
var power_pct_label: Label
var win_panel: PanelContainer
var win_label: Label
var win_subtitle: Label
var restart_button: Button

# Kill feed
var kill_feed: VBoxContainer

# Scoreboard
var scoreboard_panel: PanelContainer
var scoreboard_header: Label
var scoreboard_container: VBoxContainer
var _scoreboard_entries: Array[Dictionary] = []

# Music controls
var _music_panel: PanelContainer
var _music_mute_btn: Button
var _music_vol_label: Label
var _music_vol_down_btn: Button
var _music_vol_up_btn: Button

# Toast notification (center-bottom)
var _toast_label: Label
var _toast_tween: Tween

# Countdown
var countdown_overlay: ColorRect
var countdown_number: Label
var countdown_active: bool = true
var countdown_value: int = 3
var _countdown_start_msec: int = 0  # Wall-clock start time — robust against browser throttling
var _countdown_tween: Tween

# Debug / perf tracking
var _debug_label: Label
var _debug_timer: float = 0.0
var _sync_count: int = 0
var _perf_report_timer: float = 0.0
var _perf_ping_timer: float = 0.0
var _perf_fps_sum: float = 0.0
var _perf_fps_min: float = 9999.0
var _perf_sync_sum: float = 0.0
var _perf_ping_sum: float = 0.0
var _perf_sample_count: int = 0
var _perf_renderer: String = ""
var _last_sync_time: float = 0.0
var _sync_gaps: int = 0  # count of gaps > 100ms (missed packets)

# Memory & allocation tracking
var _prev_mem_mb: float = 0.0
var _mem_delta_mb: float = 0.0
var _prev_obj_count: int = 0
var _obj_delta: int = 0
var _alloc_spike_count: int = 0  # Count of frames with high allocation


func _init(game_manager: Node) -> void:
	gm = game_manager


# --- Style helpers ---

func _make_stylebox(bg_color: Color, border_color: Color = Color.TRANSPARENT,
		corner: int = CORNER_RADIUS, border_width: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = corner
	style.corner_radius_top_right = corner
	style.corner_radius_bottom_left = corner
	style.corner_radius_bottom_right = corner
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	if border_color.a > 0.01 and border_width > 0:
		style.border_color = border_color
		style.border_width_left = border_width
		style.border_width_right = border_width
		style.border_width_top = border_width
		style.border_width_bottom = border_width
	return style


func _make_label(text: String, font_size: int, color: Color, shadow: bool = true) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if shadow:
		label.add_theme_color_override("font_shadow_color", SHADOW_COLOR)
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
	return label


func _style_button(btn: Button, font_size: int = 14) -> void:
	btn.add_theme_font_size_override("font_size", font_size)
	var normal := _make_stylebox(Color(0.12, 0.12, 0.2, 0.8), COLOR_BORDER_SUBTLE, 4, 1)
	var hover := _make_stylebox(Color(0.18, 0.18, 0.28, 0.9), COLOR_GOLD_DIM, 4, 1)
	var pressed := _make_stylebox(Color(0.08, 0.08, 0.14, 0.9), COLOR_GOLD_DIM, 4, 1)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	btn.add_theme_color_override("font_hover_color", COLOR_GOLD)


# --- Main HUD creation ---

func create(parent: CanvasLayer) -> void:
	# --- Info label (top-left) ---
	info_label = _make_label("", 18, Color(0.9, 0.9, 0.9))
	info_label.position = Vector2(20, 16)
	var my_slot := NetworkManager.my_slot
	if my_slot >= 0 and my_slot < gm.player_names.size():
		info_label.text = "You are %s" % gm.player_names[my_slot]
		info_label.add_theme_color_override("font_color", gm.player_colors[my_slot])
	else:
		info_label.text = "Spectating"
	parent.add_child(info_label)

	# --- Scoreboard (top-left, below info) ---
	scoreboard_panel = PanelContainer.new()
	scoreboard_panel.position = Vector2(14, 44)
	scoreboard_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, CORNER_RADIUS, 1))
	parent.add_child(scoreboard_panel)

	var sb_vbox := VBoxContainer.new()
	sb_vbox.add_theme_constant_override("separation", 2)
	scoreboard_panel.add_child(sb_vbox)

	scoreboard_header = _make_label("SCOREBOARD", 11, COLOR_GOLD_DIM, false)
	scoreboard_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sb_vbox.add_child(scoreboard_header)

	scoreboard_container = VBoxContainer.new()
	scoreboard_container.add_theme_constant_override("separation", 2)
	sb_vbox.add_child(scoreboard_container)

	# --- Power bar (bottom-center) ---
	power_bar_bg = PanelContainer.new()
	power_bar_bg.custom_minimum_size = Vector2(350, 16)
	var pb_style := _make_stylebox(Color(0.05, 0.05, 0.1, 0.85), COLOR_BORDER_SUBTLE, 8, 1)
	pb_style.content_margin_left = 0
	pb_style.content_margin_right = 0
	pb_style.content_margin_top = 0
	pb_style.content_margin_bottom = 0
	power_bar_bg.add_theme_stylebox_override("panel", pb_style)
	power_bar_bg.visible = false
	parent.add_child(power_bar_bg)

	power_bar_fill = ColorRect.new()
	power_bar_fill.size = Vector2(0, 12)
	power_bar_fill.color = Color(0.2, 0.8, 0.2)
	power_bar_fill.visible = false
	parent.add_child(power_bar_fill)

	power_pct_label = _make_label("", 11, Color.WHITE)
	power_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	power_pct_label.visible = false
	parent.add_child(power_pct_label)

	# --- Win screen ---
	win_panel = PanelContainer.new()
	win_panel.custom_minimum_size = Vector2(500, 160)
	win_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_GOLD_DIM, 10, 2))
	win_panel.visible = false
	parent.add_child(win_panel)

	var win_vbox := VBoxContainer.new()
	win_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	win_vbox.add_theme_constant_override("separation", 8)
	win_panel.add_child(win_vbox)

	win_label = _make_label("", 48, COLOR_GOLD)
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_vbox.add_child(win_label)

	win_subtitle = _make_label("Next round in 5s...", 18, COLOR_TEXT_DIM)
	win_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_vbox.add_child(win_subtitle)

	restart_button = Button.new()
	restart_button.text = "BACK TO MENU"
	restart_button.custom_minimum_size = Vector2(180, 44)
	_style_button(restart_button, 18)
	restart_button.visible = false
	restart_button.pressed.connect(_on_back_to_menu)
	parent.add_child(restart_button)

	# --- Kill feed (top-right) ---
	kill_feed = VBoxContainer.new()
	kill_feed.anchor_left = 1.0
	kill_feed.anchor_top = 0.0
	kill_feed.anchor_right = 1.0
	kill_feed.anchor_bottom = 0.0
	kill_feed.offset_left = -300
	kill_feed.offset_top = 20
	kill_feed.offset_right = -16
	kill_feed.offset_bottom = 350
	kill_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	kill_feed.add_theme_constant_override("separation", 4)
	parent.add_child(kill_feed)

	# --- Toast label (center-bottom) ---
	_toast_label = _make_label("", 18, Color.WHITE)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.modulate.a = 0.0
	parent.add_child(_toast_label)

	# --- Music controls (bottom-left) ---
	_music_panel = PanelContainer.new()
	_music_panel.anchor_left = 0.0
	_music_panel.anchor_top = 1.0
	_music_panel.anchor_right = 0.0
	_music_panel.anchor_bottom = 1.0
	_music_panel.offset_left = 12
	_music_panel.offset_top = -48
	_music_panel.offset_right = 200
	_music_panel.offset_bottom = -8
	_music_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var music_style := _make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, 4, 1)
	music_style.content_margin_left = 6
	music_style.content_margin_right = 6
	music_style.content_margin_top = 3
	music_style.content_margin_bottom = 3
	_music_panel.add_theme_stylebox_override("panel", music_style)
	parent.add_child(_music_panel)

	var music_row := HBoxContainer.new()
	music_row.add_theme_constant_override("separation", 3)
	_music_panel.add_child(music_row)

	_music_mute_btn = Button.new()
	_music_mute_btn.custom_minimum_size = Vector2(28, 28)
	_style_button(_music_mute_btn, 14)
	_music_mute_btn.pressed.connect(_on_music_mute_pressed)
	music_row.add_child(_music_mute_btn)

	_music_vol_down_btn = Button.new()
	_music_vol_down_btn.text = "-"
	_music_vol_down_btn.custom_minimum_size = Vector2(28, 28)
	_style_button(_music_vol_down_btn, 14)
	_music_vol_down_btn.pressed.connect(_on_music_vol_down)
	music_row.add_child(_music_vol_down_btn)

	_music_vol_label = _make_label("", 13, COLOR_TEXT_DIM, false)
	_music_vol_label.custom_minimum_size = Vector2(38, 0)
	_music_vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	music_row.add_child(_music_vol_label)

	_music_vol_up_btn = Button.new()
	_music_vol_up_btn.text = "+"
	_music_vol_up_btn.custom_minimum_size = Vector2(28, 28)
	_style_button(_music_vol_up_btn, 14)
	_music_vol_up_btn.pressed.connect(_on_music_vol_up)
	music_row.add_child(_music_vol_up_btn)

	_update_music_ui()

	# --- Debug overlay (top-center) ---
	_debug_label = _make_label("", 15, Color(1, 1, 1, 0.85))
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_debug_label.position = Vector2(0, 6)
	_debug_label.size = Vector2(1280, 24)
	parent.add_child(_debug_label)


# --- Countdown ---

func create_countdown_overlay(parent: CanvasLayer) -> void:
	countdown_active = true
	countdown_value = 3
	_countdown_start_msec = Time.get_ticks_msec()

	countdown_overlay = ColorRect.new()
	countdown_overlay.color = Color(0, 0, 0, 0.7)
	countdown_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(countdown_overlay)

	countdown_number = Label.new()
	countdown_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_number.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_number.text = "3"
	countdown_number.add_theme_font_size_override("font_size", 120)
	countdown_number.add_theme_color_override("font_color", COLOR_GOLD)
	countdown_number.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	countdown_number.add_theme_constant_override("shadow_offset_x", 4)
	countdown_number.add_theme_constant_override("shadow_offset_y", 4)
	countdown_number.pivot_offset = Vector2(640, 360)  # Center of 1280x720
	parent.add_child(countdown_number)

	# Initial pulse
	_pulse_countdown_number()


func _pulse_countdown_number() -> void:
	if countdown_number == null:
		return
	if _countdown_tween and _countdown_tween.is_valid():
		_countdown_tween.kill()
	countdown_number.scale = Vector2(1.4, 1.4)
	_countdown_tween = gm.create_tween()
	_countdown_tween.tween_property(countdown_number, "scale", Vector2(1.0, 1.0), 0.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func update_countdown(_delta: float) -> void:
	# Use wall-clock time so browser tab throttling can't stall the countdown.
	# Time.get_ticks_msec() advances even when requestAnimationFrame is paused.
	var real_elapsed := (Time.get_ticks_msec() - _countdown_start_msec) / 1000.0
	var new_value := 3 - int(real_elapsed)  # 3→2→1→0(GO!)→negative(dismiss)

	if new_value >= countdown_value:
		return  # Nothing changed yet

	# Jump directly to new_value — handles multiple elapsed seconds in one frame.
	countdown_value = new_value

	if countdown_value > 0:
		if countdown_number:
			countdown_number.text = str(countdown_value)
			_pulse_countdown_number()
	elif countdown_value == 0:
		if countdown_number:
			countdown_number.text = "GO!"
			countdown_number.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			# Zoom-in effect for GO!
			countdown_number.scale = Vector2(0.5, 0.5)
			if _countdown_tween and _countdown_tween.is_valid():
				_countdown_tween.kill()
			_countdown_tween = gm.create_tween()
			_countdown_tween.tween_property(countdown_number, "scale", Vector2(1.1, 1.1), 0.15).set_ease(Tween.EASE_OUT)
			_countdown_tween.tween_property(countdown_number, "scale", Vector2(1.0, 1.0), 0.1)
	else:
		# new_value < 0: elapsed > 4s, dismiss immediately (catches long-tab-switch case)
		countdown_active = false
		if _countdown_tween and _countdown_tween.is_valid():
			_countdown_tween.kill()
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
		info_label.text = "You are %s" % gm.player_names[my_slot]
		info_label.add_theme_color_override("font_color", gm.player_colors[my_slot])


func set_info_text(text: String, color: Color) -> void:
	if info_label:
		info_label.text = text
		info_label.add_theme_color_override("font_color", color)


func _show_toast(text: String, color: Color) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	# Position center-bottom
	var vp := gm.get_viewport().get_visible_rect().size
	_toast_label.position = Vector2(0, vp.y - 120)
	_toast_label.size = Vector2(vp.x, 30)

	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_label.modulate.a = 1.0
	_toast_tween = gm.create_tween()
	_toast_tween.tween_interval(2.0)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)


# --- Power bar ---

func show_power_bar() -> void:
	if power_bar_bg:
		power_bar_bg.visible = true
		power_bar_fill.visible = true
		power_pct_label.visible = true
	position_power_bar()


func hide_power_bar() -> void:
	if power_bar_bg:
		power_bar_bg.visible = false
		power_bar_fill.visible = false
		power_pct_label.visible = false


func update_power_bar(power_ratio: float) -> void:
	if power_bar_fill:
		power_bar_fill.size.x = 346.0 * power_ratio
		# Green → Yellow → Red gradient
		if power_ratio < 0.5:
			power_bar_fill.color = Color(power_ratio * 2.0, 0.8, 0.2)
		else:
			power_bar_fill.color = Color(0.9, 0.8 * (1.0 - power_ratio), 0.1)
	if power_pct_label:
		power_pct_label.text = "%d%%" % int(power_ratio * 100)


func position_power_bar() -> void:
	var vp := gm.get_viewport().get_visible_rect().size
	if power_bar_bg:
		power_bar_bg.position = Vector2(vp.x / 2.0 - 175.0, vp.y - 50.0)
		power_bar_bg.size = Vector2(350, 16)
	if power_bar_fill:
		power_bar_fill.position = Vector2(vp.x / 2.0 - 173.0, vp.y - 48.0)
		power_bar_fill.size.y = 12
	if power_pct_label:
		power_pct_label.position = Vector2(vp.x / 2.0 - 175.0, vp.y - 70.0)
		power_pct_label.size = Vector2(350, 20)


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
			win_label.add_theme_color_override("font_color", COLOR_GOLD)

	if win_subtitle:
		if NetworkManager.is_single_player:
			win_subtitle.text = "Next round in 5s..."
		else:
			win_subtitle.text = "Next round starting soon..."

	if win_panel:
		win_panel.visible = true
		_position_win_ui()

	if restart_button:
		restart_button.visible = true
		_position_win_ui()


func hide_game_over() -> void:
	if win_panel:
		win_panel.visible = false
	if restart_button:
		restart_button.visible = false
	if kill_feed:
		for child in kill_feed.get_children():
			child.queue_free()


func _position_win_ui() -> void:
	var vp := gm.get_viewport().get_visible_rect().size
	if win_panel:
		win_panel.position = Vector2(vp.x / 2.0 - 250, vp.y / 2.0 - 100)
		win_panel.size = Vector2(500, 160)
	if restart_button:
		restart_button.position = Vector2(vp.x / 2.0 - 90, vp.y / 2.0 + 80)
		restart_button.size = Vector2(180, 44)


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
		Color(0.15, 0.12, 0.0, 0.8), COLOR_GOLD_DIM, false)


func _add_feed_entry(text: String, text_color: Color, bg_color: Color) -> void:
	_add_feed_entry_styled(text, text_color, 15, bg_color, Color.TRANSPARENT, true)


func _add_feed_entry_styled(text: String, text_color: Color, font_size: int,
		bg_color: Color, border_color: Color, auto_fade: bool) -> void:
	var panel := PanelContainer.new()
	var bw := 1 if border_color.a > 0.01 else 0
	panel.add_theme_stylebox_override("panel",
		_make_stylebox(bg_color, border_color, 4, bw))

	var label := _make_label(text, font_size, text_color)
	panel.add_child(label)

	# Start off-screen right, slide in
	panel.modulate.a = 0.0
	kill_feed.add_child(panel)

	var slide_tween := gm.create_tween()
	slide_tween.tween_property(panel, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)

	if auto_fade:
		_get_tree().create_timer(5.0).timeout.connect(func() -> void:
			if not is_instance_valid(panel):
				return
			var fade := gm.create_tween()
			fade.tween_property(panel, "modulate:a", 0.0, 1.0)
			fade.tween_callback(panel.queue_free)
		)


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
		panel.custom_minimum_size = Vector2(170, 0)
		var style := _make_stylebox(Color(0, 0, 0, 0.4), Color.TRANSPARENT, 4, 0)
		style.content_margin_left = 8
		style.content_margin_right = 10
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		panel.add_theme_stylebox_override("panel", style)

		var label := Label.new()
		label.add_theme_font_size_override("font_size", 15)
		label.add_theme_color_override("font_shadow_color", SHADOW_COLOR)
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
		var wins_str: String = ""
		if wins > 0:
			wins_str = " x%d" % wins

		if alive:
			var dot := ">" if is_me else " "
			var pu_suffix := ""
			var pu_sym: String = gm.powerup_system.get_powerup_symbol(slot_idx)
			if pu_sym != "":
				pu_suffix = "  [%s]" % pu_sym
			label.text = "%s %s%s%s" % [dot, short_name, wins_str, pu_suffix]
			label.add_theme_color_override("font_color", color)
			style.bg_color = Color(color.r * 0.12, color.g * 0.12, color.b * 0.12, 0.5)
			if is_me:
				style.border_color = Color(color.r, color.g, color.b, 0.4)
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
			style.bg_color = Color(0, 0, 0, 0.25)
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
	_music_mute_btn.text = "M" if MusicManager.is_muted() else "~"
	_music_vol_label.text = "%d%%" % MusicManager.get_volume_percent()
	var muted := MusicManager.is_muted()
	_music_vol_down_btn.disabled = muted
	_music_vol_up_btn.disabled = muted


func _on_back_to_menu() -> void:
	NetworkManager.disconnect_from_server()
	gm.get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# --- Debug overlay ---

func on_sync_received() -> void:
	_sync_count += 1
	var now := Time.get_ticks_msec() / 1000.0
	if _last_sync_time > 0.0:
		var gap := now - _last_sync_time
		if gap > 0.1:  # >100ms gap = likely dropped packet(s)
			_sync_gaps += 1
	_last_sync_time = now


func update_debug(delta: float) -> void:
	_debug_timer += delta

	# Send ping every 3 seconds
	if not NetworkManager.is_single_player:
		_perf_ping_timer += delta
		if _perf_ping_timer >= 3.0:
			_perf_ping_timer = 0.0
			NetworkManager.send_ping()

	if _debug_timer < 1.0:
		return
	var fps: float = float(Engine.get_frames_per_second())
	var sync_rate: float = float(_sync_count) / _debug_timer
	var gaps: int = _sync_gaps
	_sync_count = 0
	_sync_gaps = 0
	_debug_timer = 0.0
	if _perf_renderer.is_empty():
		_perf_renderer = RenderingServer.get_video_adapter_name()

	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var mem_mb: float = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var ping_ms: float = NetworkManager.client_ping_ms
	
	# Memory delta (allocation rate)
	_mem_delta_mb = mem_mb - _prev_mem_mb
	_prev_mem_mb = mem_mb

	# Object count & delta (node allocations)
	var tree := _get_tree()
	var obj_count := tree.get_node_count() if tree else 0
	_obj_delta = obj_count - _prev_obj_count
	_prev_obj_count = obj_count
	
	# Track allocation spikes (frames with high node creation)
	if _obj_delta > 5:
		_alloc_spike_count += 1
	
	# Count active effects (bursts, powerup visuals)
	var active_bursts := 0
	if tree and tree.has_group("bursts"):
		active_bursts = tree.get_node_count_in_group("bursts")

	var debug_line: String = "%d FPS | sync %.0f/s" % [int(fps), sync_rate]
	if gaps > 0:
		debug_line += " | gaps %d!" % gaps
	if ping_ms >= 0.0:
		debug_line += " | ping %.0fms" % ping_ms
	debug_line += " | draw %d | mem %.0fMB" % [draw_calls, mem_mb]
	
	# Add memory delta (positive = allocating, negative = GC freeing)
	if _mem_delta_mb > 0.1:
		debug_line += " (+%.2f)" % _mem_delta_mb
	elif _mem_delta_mb < -0.1:
		debug_line += " (-%.2f)" % -_mem_delta_mb
	
	# Add object count delta (allocations per second)
	if _obj_delta > 0:
		debug_line += " | obj +%d" % _obj_delta
	elif _obj_delta < 0:
		debug_line += " | obj %d" % _obj_delta
	
	# Add active effects count
	if active_bursts > 0:
		debug_line += " | bursts %d" % active_bursts
	
	# Add frame timing (from game_manager)
	var frame_time: float = gm._last_frame_time if gm.has_method("_process") else 0.0
	if frame_time > 0:
		debug_line += " | frame %.1fms" % frame_time
		if frame_time > 16:
			debug_line += "!"
		if frame_time > 50:
			debug_line += "!!"
	
	# Add allocation spike warning
	if _alloc_spike_count > 0:
		debug_line += " | spikes %d!" % _alloc_spike_count

	if _debug_label != null:
		_debug_label.text = debug_line

		# Color code: green=good, yellow=warning, red=bad
		if fps < 30 or (ping_ms > 150 and ping_ms >= 0.0) or gaps > 2 or _alloc_spike_count > 3:
			_debug_label.add_theme_color_override("font_color", Color(1, 0.4, 0.3, 0.9))
		elif fps < 50 or (ping_ms > 80 and ping_ms >= 0.0) or gaps > 0 or _alloc_spike_count > 0:
			_debug_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 0.9))
		else:
			_debug_label.add_theme_color_override("font_color", Color(0.7, 1, 0.7, 0.9))

	# Print to console every 5 seconds (not every 1s to avoid spam)
	_perf_sample_count += 1
	if _perf_sample_count % 5 == 0:
		print("[PERF] %s | %s" % [debug_line, _perf_renderer])
	
	# Log allocation spikes for debugging
	if _obj_delta > 10:
		print("[PERF] ALLOC SPIKE: +%d nodes, +%.2f MB memory" % [_obj_delta, _mem_delta_mb])

	# Accumulate for server report
	_perf_fps_sum += fps
	_perf_sync_sum += sync_rate
	if ping_ms >= 0.0:
		_perf_ping_sum += ping_ms
	if fps < _perf_fps_min:
		_perf_fps_min = fps

	# Reset allocation spike counter every 10 seconds
	_perf_sample_count += 1
	if _perf_sample_count % 10 == 0:
		_alloc_spike_count = 0
	
	# Send summary to server every 30s
	if not NetworkManager.is_single_player:
		_perf_report_timer += 1.0
		if _perf_report_timer >= 30.0 and _perf_sample_count > 0:
			_perf_report_timer = 0.0
			_send_perf_report()


func _send_perf_report() -> void:
	var count: float = maxf(float(_perf_sample_count), 1.0)
	var avg_ping: float = _perf_ping_sum / count
	var fps_avg: float = _perf_fps_sum / count
	var sync_avg: float = _perf_sync_sum / count
	var report := "%s|%.0f|%.0f|%.0f|%.0f" % [
		_perf_renderer, fps_avg, _perf_fps_min, sync_avg, avg_ping]
	print("[PERF] Sending report to server: fps_avg=%.0f fps_min=%.0f sync=%.0f/s ping=%.0fms" % [
		fps_avg, _perf_fps_min, sync_avg, avg_ping])
	_perf_fps_sum = 0.0
	_perf_fps_min = 9999.0
	_perf_sync_sum = 0.0
	_perf_ping_sum = 0.0
	_perf_sample_count = 0
	NetworkManager._rpc_client_perf_report.rpc_id(1, report)
