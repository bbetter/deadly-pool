extends RefCounted
class_name GameHUD
## Manages all HUD/UI elements: info label, power bar, scoreboard, kill feed,
## countdown overlay, win screen, music controls, toast notifications.
## Instantiated by GameManager; gm reference for accessing game state.

var gm: Node  # GameManager reference

# Style constants — neon bar theme
const COLOR_GOLD := Color(1, 0.85, 0.2)
const COLOR_GOLD_DIM := Color(1, 0.85, 0.2, 0.5)
const COLOR_NEON_CYAN := Color(0.0, 0.9, 1.0)        # Matches 3D cyan neon tubes
const COLOR_NEON_PINK := Color(1.0, 0.15, 0.65)       # Matches 3D pink neon tubes
const COLOR_BG_DARK := Color(0.06, 0.03, 0.10, 0.82)  # Deep purple-dark
const COLOR_BG_PANEL := Color(0.08, 0.04, 0.14, 0.78)
const COLOR_BORDER_SUBTLE := Color(0.5, 0.2, 0.8, 0.22) # Subtle purple glow border
const COLOR_TEXT_DIM := Color(0.50, 0.40, 0.62)       # Purple-gray
const COLOR_TEXT_MAIN := Color(0.88, 0.92, 1.0)        # Slightly cyan-white
const CORNER_RADIUS := 4
const SHADOW_COLOR := Color(0, 0, 0, 0.88)

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
var _scoreboard: ScoreboardUI

# Sound controls (music + sfx)
var _music_panel: PanelContainer
var _music_mute_btn: Button
var _music_vol_down_btn: Button
var _music_vol_up_btn: Button
var _sfx_mute_btn: Button
var _sfx_vol_down_btn: Button
var _sfx_vol_up_btn: Button

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

# Debug overlay (perf/sync tracking — delegated to DebugHUDOverlay)
var _debug_overlay: DebugHUDOverlay

# Spectator overlay
var _spectator_panel: Control = null
var _join_round_btn: Button = null

# Skip-round overlay (shown when human is out and only bots remain)
var _skip_round_panel: Control = null
var _skip_round_btn: Button = null

# Info pill badge
var _info_panel: PanelContainer = null
var _info_style: StyleBoxFlat = null

# Power bar style (for border pulse at max power)
var _power_bar_style: StyleBoxFlat = null

# Status panel (replaces "You are X" info pill for active players)
var _status_panel: PanelContainer = null
var _status_label: Label = null
var _pu_name_label: Label = null
var _pu_desc_label: Label = null

# Pickup labels — powerup name floated above 3D item, projected to 2D
var _pickup_labels: Dictionary = {}  # powerup_id → {"label": Label, "pos3d": Vector3}
var _hud_layer: CanvasLayer = null
var _camera: Camera3D = null

# Touch on-screen buttons (only created on touchscreen devices)
signal powerup_button_pressed
signal emote_button_pressed(index: int)
signal scoreboard_button_pressed
var _touch_ui: Control = null
var _sb_expanded: bool = false


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
	var normal := _make_stylebox(Color(0.10, 0.05, 0.18, 0.82), COLOR_BORDER_SUBTLE, 4, 1)
	var hover := _make_stylebox(Color(0.04, 0.12, 0.20, 0.92), Color(0.0, 0.9, 1.0, 0.55), 4, 1)
	var pressed := _make_stylebox(Color(0.02, 0.07, 0.13, 0.92), Color(0.0, 0.9, 1.0, 0.55), 4, 1)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color", COLOR_TEXT_MAIN)
	btn.add_theme_color_override("font_hover_color", COLOR_NEON_CYAN)


func _set_mouse_passthrough(ctrl: Control) -> void:
	ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE


# --- Main HUD creation ---

func create(parent: CanvasLayer) -> void:
	_hud_layer = parent
	_camera = gm.get_node_or_null("CameraRig/Camera3D")
	_create_info_panel(parent)
	_create_status_panel(parent)
	_create_scoreboards(parent)
	_create_power_bar(parent)
	_create_win_screen(parent)
	_create_kill_feed(parent)
	_create_toast(parent)
	_create_music_panel(parent)
	_create_debug_label(parent)
	_create_skip_round_panel(parent)
	_create_spectator_overlay(parent)
	_create_touch_buttons(parent)


func _create_touch_buttons(parent: CanvasLayer) -> void:
	if not DisplayServer.is_touchscreen_available():
		return

	_touch_ui = Control.new()
	_touch_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_touch_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_touch_ui)

	# Scoreboard toggle — top-right
	var sb_btn := Button.new()
	sb_btn.text = "≡"
	sb_btn.anchor_left = 1.0; sb_btn.anchor_right = 1.0
	sb_btn.anchor_top = 0.0; sb_btn.anchor_bottom = 0.0
	sb_btn.offset_left = -64; sb_btn.offset_top = 10
	sb_btn.offset_right = -10; sb_btn.offset_bottom = 64
	_style_button(sb_btn, 20)
	sb_btn.pressed.connect(func() -> void: scoreboard_button_pressed.emit())
	_touch_ui.add_child(sb_btn)

	# Powerup button — bottom-right
	var pu_btn := Button.new()
	pu_btn.text = "⚡"
	pu_btn.anchor_left = 1.0; pu_btn.anchor_right = 1.0
	pu_btn.anchor_top = 1.0; pu_btn.anchor_bottom = 1.0
	pu_btn.offset_left = -80; pu_btn.offset_top = -80
	pu_btn.offset_right = -10; pu_btn.offset_bottom = -10
	_style_button(pu_btn, 22)
	pu_btn.pressed.connect(func() -> void: powerup_button_pressed.emit())
	_touch_ui.add_child(pu_btn)

	# Emote buttons — stacked above powerup
	var emote_texts := ["HA!", "GG", "???"]
	for i in 3:
		var emote_btn := Button.new()
		emote_btn.text = emote_texts[i]
		emote_btn.anchor_left = 1.0; emote_btn.anchor_right = 1.0
		emote_btn.anchor_top = 1.0; emote_btn.anchor_bottom = 1.0
		var y_off: int = -90 - i * 54
		emote_btn.offset_left = -160; emote_btn.offset_top = y_off
		emote_btn.offset_right = -90; emote_btn.offset_bottom = y_off + 48
		_style_button(emote_btn, 13)
		emote_btn.pressed.connect(emote_button_pressed.emit.bind(i))
		_touch_ui.add_child(emote_btn)


func _create_info_panel(parent: CanvasLayer) -> void:
	_info_style = _make_stylebox(Color(0.06, 0.03, 0.10, 0.68), Color.WHITE, 6, 0)
	_info_style.content_margin_left = 8
	_info_style.content_margin_right = 8
	_info_style.content_margin_top = 3
	_info_style.content_margin_bottom = 3
	_info_style.border_width_left = 3
	_info_panel = PanelContainer.new()
	_set_mouse_passthrough(_info_panel)
	_info_panel.position = Vector2(14, 10)
	_info_panel.add_theme_stylebox_override("panel", _info_style)
	parent.add_child(_info_panel)
	info_label = _make_label("", 15, COLOR_TEXT_MAIN)
	_set_mouse_passthrough(info_label)
	_info_panel.add_child(info_label)
	if NetworkManager.my_slot >= 0:
		_info_panel.visible = false  # status panel handles player state
	else:
		info_label.text = "Spectating"


func _create_status_panel(parent: CanvasLayer) -> void:
	var status_bg := _make_stylebox(Color(0.06, 0.03, 0.10, 0.75), COLOR_BORDER_SUBTLE, CORNER_RADIUS, 1)
	status_bg.content_margin_left = 8
	status_bg.content_margin_right = 10
	status_bg.content_margin_top = 4
	status_bg.content_margin_bottom = 4
	_status_panel = PanelContainer.new()
	_set_mouse_passthrough(_status_panel)
	_status_panel.position = Vector2(14, 10)
	_status_panel.add_theme_stylebox_override("panel", status_bg)
	_status_panel.visible = false
	parent.add_child(_status_panel)
	var status_vbox := VBoxContainer.new()
	_set_mouse_passthrough(status_vbox)
	status_vbox.add_theme_constant_override("separation", 2)
	_status_panel.add_child(status_vbox)
	_status_label = _make_label("", 12, COLOR_NEON_CYAN)
	_set_mouse_passthrough(_status_label)
	_status_label.visible = false
	status_vbox.add_child(_status_label)
	_pu_name_label = _make_label("", 12, Color.WHITE)
	_set_mouse_passthrough(_pu_name_label)
	_pu_name_label.visible = false
	status_vbox.add_child(_pu_name_label)
	_pu_desc_label = _make_label("", 10, COLOR_TEXT_DIM)
	_set_mouse_passthrough(_pu_desc_label)
	_pu_desc_label.visible = false
	status_vbox.add_child(_pu_desc_label)


func _create_scoreboards(parent: CanvasLayer) -> void:
	# Expanded scoreboard (Tab to reveal)
	scoreboard_panel = PanelContainer.new()
	_set_mouse_passthrough(scoreboard_panel)
	scoreboard_panel.position = Vector2(14, 44)
	scoreboard_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, CORNER_RADIUS, 1))
	parent.add_child(scoreboard_panel)
	var sb_vbox := VBoxContainer.new()
	_set_mouse_passthrough(sb_vbox)
	sb_vbox.add_theme_constant_override("separation", 2)
	scoreboard_panel.add_child(sb_vbox)
	scoreboard_header = _make_label("SCOREBOARD", 11, COLOR_NEON_CYAN, false)
	_set_mouse_passthrough(scoreboard_header)
	scoreboard_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sb_vbox.add_child(scoreboard_header)
	scoreboard_container = VBoxContainer.new()
	_set_mouse_passthrough(scoreboard_container)
	scoreboard_container.add_theme_constant_override("separation", 2)
	sb_vbox.add_child(scoreboard_container)
	scoreboard_panel.visible = false
	# Compact scoreboard (always visible)
	var compact_sb_panel := PanelContainer.new()
	_set_mouse_passthrough(compact_sb_panel)
	compact_sb_panel.position = Vector2(14, 44)
	compact_sb_panel.add_theme_stylebox_override("panel",
		_make_stylebox(Color(0.06, 0.03, 0.10, 0.5), Color.TRANSPARENT, CORNER_RADIUS, 0))
	parent.add_child(compact_sb_panel)
	var compact_sb_vbox := VBoxContainer.new()
	_set_mouse_passthrough(compact_sb_vbox)
	compact_sb_vbox.add_theme_constant_override("separation", 3)
	compact_sb_panel.add_child(compact_sb_vbox)
	_scoreboard = ScoreboardUI.new(gm, scoreboard_panel, scoreboard_container, compact_sb_panel, compact_sb_vbox)


func _create_power_bar(parent: CanvasLayer) -> void:
	power_bar_bg = PanelContainer.new()
	_set_mouse_passthrough(power_bar_bg)
	power_bar_bg.custom_minimum_size = Vector2(300, 10)
	_power_bar_style = _make_stylebox(Color(0.05, 0.03, 0.10, 0.90), COLOR_BORDER_SUBTLE, 8, 1)
	_power_bar_style.content_margin_left = 0
	_power_bar_style.content_margin_right = 0
	_power_bar_style.content_margin_top = 0
	_power_bar_style.content_margin_bottom = 0
	power_bar_bg.add_theme_stylebox_override("panel", _power_bar_style)
	power_bar_bg.visible = false
	parent.add_child(power_bar_bg)
	power_bar_fill = ColorRect.new()
	_set_mouse_passthrough(power_bar_fill)
	power_bar_fill.size = Vector2(0, 6)
	power_bar_fill.color = Color(0.2, 0.8, 0.2)
	power_bar_fill.visible = false
	parent.add_child(power_bar_fill)
	power_pct_label = _make_label("", 11, COLOR_NEON_CYAN)
	_set_mouse_passthrough(power_pct_label)
	power_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	power_pct_label.visible = false
	parent.add_child(power_pct_label)


func _create_win_screen(parent: CanvasLayer) -> void:
	win_panel = PanelContainer.new()
	_set_mouse_passthrough(win_panel)
	win_panel.custom_minimum_size = Vector2(500, 160)
	win_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_GOLD_DIM, 10, 2))
	win_panel.visible = false
	parent.add_child(win_panel)
	var win_vbox := VBoxContainer.new()
	_set_mouse_passthrough(win_vbox)
	win_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	win_vbox.add_theme_constant_override("separation", 8)
	win_panel.add_child(win_vbox)
	win_label = _make_label("", 48, COLOR_GOLD)
	_set_mouse_passthrough(win_label)
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_vbox.add_child(win_label)
	win_subtitle = _make_label("Next round in 5s...", 18, COLOR_TEXT_DIM)
	_set_mouse_passthrough(win_subtitle)
	win_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_vbox.add_child(win_subtitle)
	restart_button = Button.new()
	restart_button.text = "BACK TO MENU"
	restart_button.custom_minimum_size = Vector2(180, 44)
	_style_button(restart_button, 18)
	restart_button.visible = false
	restart_button.pressed.connect(_on_back_to_menu)
	parent.add_child(restart_button)


func _create_kill_feed(parent: CanvasLayer) -> void:
	kill_feed = VBoxContainer.new()
	_set_mouse_passthrough(kill_feed)
	kill_feed.anchor_left = 1.0
	kill_feed.anchor_top = 0.0
	kill_feed.anchor_right = 1.0
	kill_feed.anchor_bottom = 0.0
	kill_feed.offset_left = -300
	var kf_top := 74 if DisplayServer.is_touchscreen_available() else 20
	kill_feed.offset_top = kf_top
	kill_feed.offset_right = -16
	kill_feed.offset_bottom = kf_top + 330
	kill_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	kill_feed.add_theme_constant_override("separation", 4)
	parent.add_child(kill_feed)


func _create_toast(parent: CanvasLayer) -> void:
	_toast_label = _make_label("", 18, Color.WHITE)
	_set_mouse_passthrough(_toast_label)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.modulate.a = 0.0
	parent.add_child(_toast_label)


func _create_music_panel(parent: CanvasLayer) -> void:
	if DisplayServer.is_touchscreen_available():
		return  # Touch players mute via main menu; in-game buttons are too small to tap
	_music_panel = PanelContainer.new()
	_music_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_music_panel.anchor_left = 0.0
	_music_panel.anchor_top = 1.0
	_music_panel.anchor_right = 0.0
	_music_panel.anchor_bottom = 1.0
	_music_panel.offset_left = 12
	_music_panel.offset_top = -72
	_music_panel.offset_right = 130
	_music_panel.offset_bottom = -8
	_music_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var music_style := _make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, 4, 1)
	music_style.content_margin_left = 6
	music_style.content_margin_right = 6
	music_style.content_margin_top = 4
	music_style.content_margin_bottom = 4
	_music_panel.add_theme_stylebox_override("panel", music_style)
	parent.add_child(_music_panel)
	var sound_vbox := VBoxContainer.new()
	sound_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	sound_vbox.add_theme_constant_override("separation", 3)
	_music_panel.add_child(sound_vbox)
	# Music row
	var music_row := HBoxContainer.new()
	music_row.mouse_filter = Control.MOUSE_FILTER_PASS
	music_row.add_theme_constant_override("separation", 2)
	sound_vbox.add_child(music_row)
	var music_label := _make_label("\u266a", 12, COLOR_TEXT_DIM, false)
	music_label.custom_minimum_size = Vector2(14, 0)
	_set_mouse_passthrough(music_label)
	music_row.add_child(music_label)
	_music_mute_btn = Button.new()
	_music_mute_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_music_mute_btn, 13)
	_music_mute_btn.pressed.connect(_on_music_mute_pressed)
	music_row.add_child(_music_mute_btn)
	_music_vol_down_btn = Button.new()
	_music_vol_down_btn.text = "-"
	_music_vol_down_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_music_vol_down_btn, 13)
	_music_vol_down_btn.pressed.connect(_on_music_vol_down)
	music_row.add_child(_music_vol_down_btn)
	_music_vol_up_btn = Button.new()
	_music_vol_up_btn.text = "+"
	_music_vol_up_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_music_vol_up_btn, 13)
	_music_vol_up_btn.pressed.connect(_on_music_vol_up)
	music_row.add_child(_music_vol_up_btn)
	# SFX row
	var sfx_row := HBoxContainer.new()
	sfx_row.mouse_filter = Control.MOUSE_FILTER_PASS
	sfx_row.add_theme_constant_override("separation", 2)
	sound_vbox.add_child(sfx_row)
	var sfx_label := _make_label("fx", 11, COLOR_TEXT_DIM, false)
	sfx_label.custom_minimum_size = Vector2(14, 0)
	_set_mouse_passthrough(sfx_label)
	sfx_row.add_child(sfx_label)
	_sfx_mute_btn = Button.new()
	_sfx_mute_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_sfx_mute_btn, 13)
	_sfx_mute_btn.pressed.connect(_on_sfx_mute_pressed)
	sfx_row.add_child(_sfx_mute_btn)
	_sfx_vol_down_btn = Button.new()
	_sfx_vol_down_btn.text = "-"
	_sfx_vol_down_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_sfx_vol_down_btn, 13)
	_sfx_vol_down_btn.pressed.connect(_on_sfx_vol_down)
	sfx_row.add_child(_sfx_vol_down_btn)
	_sfx_vol_up_btn = Button.new()
	_sfx_vol_up_btn.text = "+"
	_sfx_vol_up_btn.custom_minimum_size = Vector2(26, 26)
	_style_button(_sfx_vol_up_btn, 13)
	_sfx_vol_up_btn.pressed.connect(_on_sfx_vol_up)
	sfx_row.add_child(_sfx_vol_up_btn)
	_update_music_ui()


func _create_debug_label(parent: CanvasLayer) -> void:
	_debug_overlay = DebugHUDOverlay.new(gm, parent)


func _create_skip_round_panel(parent: CanvasLayer) -> void:
	_skip_round_panel = PanelContainer.new()
	_skip_round_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_skip_round_panel.anchor_left = 0.5
	_skip_round_panel.anchor_top = 1.0
	_skip_round_panel.anchor_right = 0.5
	_skip_round_panel.anchor_bottom = 1.0
	_skip_round_panel.offset_left = -120
	_skip_round_panel.offset_top = -54
	_skip_round_panel.offset_right = 120
	_skip_round_panel.offset_bottom = -12
	_skip_round_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_skip_round_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_skip_round_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, CORNER_RADIUS, 1))
	_skip_round_panel.visible = false
	parent.add_child(_skip_round_panel)
	_skip_round_btn = Button.new()
	_skip_round_btn.text = "Skip round →"
	_skip_round_btn.custom_minimum_size = Vector2(220, 36)
	_style_button(_skip_round_btn, 15)
	_skip_round_btn.pressed.connect(_on_skip_round_pressed)
	_skip_round_panel.add_child(_skip_round_btn)


# --- Skip-round button ---

func show_skip_round_btn() -> void:
	if _skip_round_panel != null:
		_skip_round_panel.visible = true


func hide_skip_round_btn() -> void:
	if _skip_round_panel != null:
		_skip_round_panel.visible = false


func _on_skip_round_pressed() -> void:
	hide_skip_round_btn()
	gm.skip_round()


# --- Spectator overlay ---

func _create_spectator_overlay(parent: CanvasLayer) -> void:
	if NetworkManager.my_slot >= 0:
		return  # Active player, not a spectator

	_spectator_panel = PanelContainer.new()
	_spectator_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_spectator_panel.anchor_left = 0.5
	_spectator_panel.anchor_top = 1.0
	_spectator_panel.anchor_right = 0.5
	_spectator_panel.anchor_bottom = 1.0
	_spectator_panel.offset_left = -180
	_spectator_panel.offset_top = -90
	_spectator_panel.offset_right = 180
	_spectator_panel.offset_bottom = -12
	_spectator_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_spectator_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_spectator_panel.add_theme_stylebox_override("panel",
		_make_stylebox(COLOR_BG_DARK, COLOR_BORDER_SUBTLE, CORNER_RADIUS, 1))
	parent.add_child(_spectator_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_spectator_panel.add_child(vbox)

	var lbl := _make_label("Spectating – game in progress", 15, COLOR_TEXT_DIM)
	_set_mouse_passthrough(lbl)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	_join_round_btn = Button.new()
	_join_round_btn.text = "Join next round"
	_join_round_btn.custom_minimum_size = Vector2(220, 36)
	_style_button(_join_round_btn, 15)
	_join_round_btn.pressed.connect(_on_join_round_pressed)
	vbox.add_child(_join_round_btn)


func _on_join_round_pressed() -> void:
	if _join_round_btn == null:
		return
	if NetworkManager.current_room.is_empty():
		return
	_join_round_btn.disabled = true
	_join_round_btn.text = "Queued for next round ✓"
	NetworkManager._rpc_game_request_join_round.rpc_id(1, NetworkManager.current_room)


func set_queued_for_round() -> void:
	if _join_round_btn != null and is_instance_valid(_join_round_btn):
		_join_round_btn.disabled = true
		_join_round_btn.text = "Queued for next round ✓"


# --- Countdown ---

func _clear_countdown_visuals() -> void:
	if _countdown_tween and _countdown_tween.is_valid():
		_countdown_tween.kill()
	countdown_active = false
	countdown_value = 0
	if countdown_overlay and is_instance_valid(countdown_overlay):
		countdown_overlay.queue_free()
	countdown_overlay = null
	if countdown_number and is_instance_valid(countdown_number):
		countdown_number.queue_free()
	countdown_number = null


func create_countdown_overlay(parent: CanvasLayer) -> void:
	# Defensive cleanup: restart RPCs or stale previous rounds must not stack overlays.
	_clear_countdown_visuals()
	countdown_active = true
	countdown_value = 3
	_countdown_start_msec = Time.get_ticks_msec()

	countdown_overlay = ColorRect.new()
	countdown_overlay.color = Color(0.02, 0.0, 0.06, 0.80)
	countdown_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(countdown_overlay)

	countdown_number = Label.new()
	countdown_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_number.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_number.text = "3"
	countdown_number.add_theme_font_size_override("font_size", 120)
	countdown_number.add_theme_color_override("font_color", COLOR_NEON_CYAN)
	countdown_number.add_theme_color_override("font_shadow_color", Color(0.0, 0.15, 0.25, 0.95))
	countdown_number.add_theme_constant_override("shadow_offset_x", 4)
	countdown_number.add_theme_constant_override("shadow_offset_y", 4)
	countdown_number.pivot_offset = _get_tree().get_root().get_visible_rect().size / 2.0
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
		_clear_countdown_visuals()


# --- Info label helpers ---

func set_info_default() -> void:
	if info_label == null:
		return
	var my_slot := NetworkManager.my_slot
	if my_slot >= 0:
		# Active player: status panel handles all state display
		if _info_panel != null:
			_info_panel.visible = false
		# If we just became a player (were spectating before), hide spectator overlay
		if _spectator_panel != null and is_instance_valid(_spectator_panel):
			_spectator_panel.queue_free()
			_spectator_panel = null
			_join_round_btn = null
	else:
		info_label.text = "Spectating"
		info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		if _info_style != null:
			_info_style.border_color = Color(0.6, 0.6, 0.6, 0.5)
		if _info_panel != null:
			_info_panel.visible = true


func set_info_text(text: String, color: Color) -> void:
	if info_label:
		info_label.text = text
		info_label.add_theme_color_override("font_color", color)
		if _info_style != null:
			_info_style.border_color = color


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
		power_bar_fill.size.x = 296.0 * power_ratio
		# Green → Yellow → Red gradient
		if power_ratio < 0.5:
			power_bar_fill.color = Color(power_ratio * 2.0, 0.8, 0.2)
		else:
			power_bar_fill.color = Color(0.9, 0.8 * (1.0 - power_ratio), 0.1)
	if power_pct_label:
		power_pct_label.text = "%d%%" % int(power_ratio * 100)
	# Pulse border glow at max power
	if _power_bar_style != null:
		if power_ratio >= 0.99:
			var pulse := 0.5 + 0.5 * absf(sin(Time.get_ticks_msec() / 120.0))
			_power_bar_style.border_color = Color(0.95, 0.4, 0.1, pulse)
			_power_bar_style.border_width_left = 2
			_power_bar_style.border_width_right = 2
			_power_bar_style.border_width_top = 2
			_power_bar_style.border_width_bottom = 2
		else:
			_power_bar_style.border_color = COLOR_BORDER_SUBTLE
			_power_bar_style.border_width_left = 1
			_power_bar_style.border_width_right = 1
			_power_bar_style.border_width_top = 1
			_power_bar_style.border_width_bottom = 1


func position_power_bar() -> void:
	var vp := gm.get_viewport().get_visible_rect().size
	if power_bar_bg:
		power_bar_bg.position = Vector2(vp.x / 2.0 - 150.0, vp.y - 40.0)
		power_bar_bg.size = Vector2(300, 10)
	if power_bar_fill:
		power_bar_fill.position = Vector2(vp.x / 2.0 - 148.0, vp.y - 38.0)
		power_bar_fill.size.y = 6
	if power_pct_label:
		power_pct_label.position = Vector2(vp.x / 2.0 - 150.0, vp.y - 56.0)
		power_pct_label.size = Vector2(300, 14)


# --- Win UI ---

func show_game_over(winner_slot: int) -> void:
	hide_skip_round_btn()
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
		# Entrance animation: scale up from 85% + fade in
		win_panel.pivot_offset = Vector2(250, 80)
		win_panel.scale = Vector2(0.85, 0.85)
		win_panel.modulate.a = 0.0
		var anim := gm.create_tween()
		anim.set_parallel(true)
		anim.tween_property(win_panel, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		anim.tween_property(win_panel, "modulate:a", 1.0, 0.2).set_ease(Tween.EASE_OUT)

	if restart_button:
		restart_button.visible = true
		_position_win_ui()


func hide_game_over() -> void:
	hide_skip_round_btn()
	if win_panel:
		win_panel.visible = false
	if restart_button:
		restart_button.visible = false
	# Ensure stale countdown overlays from previous rounds are removed.
	_clear_countdown_visuals()
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

func add_kill_feed_entry(slot: int, killer_slot: int = -1) -> void:
	if kill_feed == null:
		return
	var victim_color: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
	var victim_name: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	if killer_slot >= 0 and killer_slot != slot and killer_slot < gm.player_names.size():
		var killer_color: Color = gm.player_colors[killer_slot] if killer_slot < gm.player_colors.size() else Color.WHITE
		var killer_name: String = gm.player_names[killer_slot]
		_add_feed_entry("%s  \u2192  %s" % [killer_name, victim_name], killer_color, Color(0, 0, 0, 0.6))
	else:
		_add_feed_entry("%s eliminated" % victim_name, victim_color, Color(0, 0, 0, 0.6))


func add_disconnect_feed_entry(slot: int) -> void:
	if kill_feed == null:
		return
	var color: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
	var dim_color := Color(color.r * 0.7, color.g * 0.7, color.b * 0.7)
	var pname: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	_add_feed_entry("%s disconnected" % pname, dim_color, Color(0.15, 0.1, 0.0, 0.6))


func add_kill_feed_win_entry(slot: int) -> void:
	if kill_feed == null:
		return
	var pname: String = gm.player_names[slot] if slot < gm.player_names.size() else "Player %d" % (slot + 1)
	_add_feed_entry_styled("* %s wins! *" % pname, Color(1, 0.85, 0.2), 18,
		Color(0.15, 0.12, 0.0, 0.8), COLOR_GOLD_DIM, false)


func add_streak_entry(killer_slot: int, streak: int) -> void:
	if kill_feed == null:
		return
	var pname: String = gm.player_names[killer_slot] if killer_slot < gm.player_names.size() else "Player %d" % (killer_slot + 1)
	var pcolor: Color = gm.player_colors[killer_slot] if killer_slot < gm.player_colors.size() else Color.WHITE
	var streak_text: String
	match streak:
		2: streak_text = "DOUBLE KILL!"
		3: streak_text = "TRIPLE KILL!"
		4: streak_text = "QUAD KILL!"
		_: streak_text = "%dx KILL STREAK!" % streak
	_add_feed_entry_styled("%s  %s" % [pname, streak_text], pcolor, 17,
		Color(0.12, 0.08, 0.0, 0.85), Color(1.0, 0.82, 0.1, 0.5), true)


func _add_feed_entry(text: String, text_color: Color, _bg_color: Color) -> void:
	var panel := PanelContainer.new()
	_set_mouse_passthrough(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_color = text_color
	style.border_width_left = 2
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	panel.add_theme_stylebox_override("panel", style)

	var label := _make_label(text, 14, text_color)
	_set_mouse_passthrough(label)
	panel.add_child(label)

	panel.modulate.a = 0.0
	kill_feed.add_child(panel)

	var slide_tween := panel.create_tween()
	slide_tween.tween_property(panel, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)

	var fade_tween := panel.create_tween()
	fade_tween.tween_interval(5.0)
	fade_tween.tween_property(panel, "modulate:a", 0.0, 1.0)
	fade_tween.tween_callback(panel.queue_free)


func _add_feed_entry_styled(text: String, text_color: Color, font_size: int,
		bg_color: Color, border_color: Color, auto_fade: bool) -> void:
	var panel := PanelContainer.new()
	_set_mouse_passthrough(panel)
	var bw := 1 if border_color.a > 0.01 else 0
	panel.add_theme_stylebox_override("panel",
		_make_stylebox(bg_color, border_color, 4, bw))

	var label := _make_label(text, font_size, text_color)
	_set_mouse_passthrough(label)
	panel.add_child(label)

	# Start off-screen right, slide in
	panel.modulate.a = 0.0
	kill_feed.add_child(panel)

	var slide_tween := panel.create_tween()
	slide_tween.tween_property(panel, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)

	if auto_fade:
		# Tween owned by panel → auto-killed when panel.queue_free() is called
		# (e.g. by hide_game_over on round restart), so no lambda capture warning.
		var fade_tween := panel.create_tween()
		fade_tween.tween_interval(5.0)
		fade_tween.tween_property(panel, "modulate:a", 0.0, 1.0)
		fade_tween.tween_callback(panel.queue_free)


# --- Scoreboard (delegated to ScoreboardUI) ---

func build_scoreboard() -> void:        _scoreboard.build()
func update_scoreboard() -> void:       _scoreboard.update()
func set_scoreboard_expanded(v: bool) -> void: _scoreboard.set_expanded(v)

func toggle_scoreboard() -> void:
	_sb_expanded = not _sb_expanded
	set_scoreboard_expanded(_sb_expanded)
func build_compact_entries() -> void:   _scoreboard.build_compact()
func update_compact_scoreboard() -> void: _scoreboard.update_compact()


# --- Music controls ---

func _on_music_mute_pressed() -> void:
	MusicManager.toggle_mute()
	_update_music_ui()


func _on_music_vol_down() -> void:
	MusicManager.volume_down()
	_update_music_ui()
	_show_toast("\u266a  %d%%" % MusicManager.get_volume_percent(), COLOR_TEXT_DIM)


func _on_music_vol_up() -> void:
	MusicManager.volume_up()
	_update_music_ui()
	_show_toast("\u266a  %d%%" % MusicManager.get_volume_percent(), COLOR_TEXT_DIM)


func _update_music_ui() -> void:
	if _music_mute_btn == null:
		return
	_music_mute_btn.text = "\u2715" if MusicManager.is_muted() else "\u266a"
	var muted := MusicManager.is_muted()
	_music_vol_down_btn.disabled = muted
	_music_vol_up_btn.disabled = muted
	if _sfx_mute_btn == null:
		return
	_sfx_mute_btn.text = "\u2715" if MusicManager.is_sfx_muted() else "fx"
	var sfx_muted := MusicManager.is_sfx_muted()
	_sfx_vol_down_btn.disabled = sfx_muted
	_sfx_vol_up_btn.disabled = sfx_muted


func _on_sfx_mute_pressed() -> void:
	MusicManager.toggle_sfx_mute()
	_update_music_ui()


func _on_sfx_vol_down() -> void:
	MusicManager.sfx_volume_down()
	_update_music_ui()
	_show_toast("fx  %d%%" % MusicManager.get_sfx_volume_percent(), COLOR_TEXT_DIM)


func _on_sfx_vol_up() -> void:
	MusicManager.sfx_volume_up()
	_update_music_ui()
	_show_toast("fx  %d%%" % MusicManager.get_sfx_volume_percent(), COLOR_TEXT_DIM)


func _on_back_to_menu() -> void:
	NetworkManager.disconnect_from_server()
	gm.get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# --- Debug overlay (delegated to DebugHUDOverlay) ---

func on_sync_received() -> void:
	if _debug_overlay != null:
		_debug_overlay.on_sync_received()


func update_debug(delta: float) -> void:
	if _debug_overlay != null:
		_debug_overlay.update(delta)


# --- Status panel (READY / WAIT / powerup hint) ---

func update_status(is_dragging: bool, is_alive: bool, ball_stopped: bool) -> void:
	if _status_label == null:
		return
	if not is_alive or NetworkManager.my_slot < 0 or is_dragging or countdown_active:
		_status_label.visible = false
	elif ball_stopped:
		var pulse := 0.75 + 0.25 * absf(sin(Time.get_ticks_msec() / 600.0))
		_status_label.text = "\u25cf READY"
		_status_label.add_theme_color_override("font_color",
			Color(COLOR_NEON_CYAN.r, COLOR_NEON_CYAN.g, COLOR_NEON_CYAN.b, pulse))
		_status_label.visible = true
	else:
		_status_label.text = "\u25cf WAIT..."
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.1))
		_status_label.visible = true
	_update_status_panel_visibility()


func update_powerup_hint(pu_type: int, armed: bool, armed_timer: float) -> void:
	if _pu_name_label == null or _pu_desc_label == null:
		return
	if pu_type == Powerup.Type.NONE:
		_pu_name_label.visible = false
		_pu_desc_label.visible = false
		_update_status_panel_visibility()
		return
	var symbol := Powerup.get_symbol(pu_type)
	var name_str := Powerup.get_powerup_name(pu_type)
	var pu_color := Powerup.get_color(pu_type)
	var expiring := armed and armed_timer > 0.0 and armed_timer <= GameConfig.powerup_expiring_threshold
	if armed:
		var pulse_a := 0.65 + 0.35 * absf(sin(Time.get_ticks_msec() / 100.0)) if expiring else 1.0
		var key_hint := "tap ⚡" if DisplayServer.is_touchscreen_available() else "— SPACE"
		_pu_name_label.text = "%s %s  %s" % [symbol, name_str.to_upper(), key_hint]
		_pu_name_label.add_theme_color_override("font_color",
			Color(pu_color.r, pu_color.g, pu_color.b, pulse_a))
		_pu_name_label.visible = true
		_pu_desc_label.visible = false
	else:
		_pu_name_label.text = "%s %s" % [symbol, name_str]
		_pu_name_label.add_theme_color_override("font_color",
			Color(pu_color.r * 0.75, pu_color.g * 0.75, pu_color.b * 0.75))
		_pu_name_label.visible = true
		_pu_desc_label.text = Powerup.get_desc(pu_type)
		_pu_desc_label.visible = true
	_update_status_panel_visibility()


func _update_status_panel_visibility() -> void:
	if _status_panel == null:
		return
	var any_visible := (
		(_status_label != null and _status_label.visible) or
		(_pu_name_label != null and _pu_name_label.visible)
	)
	_status_panel.visible = any_visible


# --- Pickup labels (powerup name floating above 3D pickup, projected to 2D) ---

func show_pickup_label(id: int, type: int, pos3d: Vector3) -> void:
	if _hud_layer == null or _pickup_labels.has(id):
		return
	var lbl := Label.new()
	lbl.text = Powerup.get_powerup_name(type)
	var pu_color := Powerup.get_color(type)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", pu_color)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.92))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(lbl)
	_pickup_labels[id] = {"label": lbl, "pos3d": pos3d}


func hide_pickup_label(id: int) -> void:
	if not _pickup_labels.has(id):
		return
	var entry = _pickup_labels[id]
	var lbl: Label = entry["label"]
	if is_instance_valid(lbl):
		lbl.queue_free()
	_pickup_labels.erase(id)


func clear_pickup_labels() -> void:
	for id in _pickup_labels:
		var entry = _pickup_labels[id]
		var lbl: Label = entry["label"]
		if is_instance_valid(lbl):
			lbl.queue_free()
	_pickup_labels.clear()


func update_pickup_labels() -> void:
	if _pickup_labels.is_empty() or _camera == null:
		return
	for id in _pickup_labels:
		var entry = _pickup_labels[id]
		var lbl: Label = entry["label"]
		if not is_instance_valid(lbl):
			continue
		var pos3d: Vector3 = entry["pos3d"]
		var screen_pos := _camera.unproject_position(pos3d + Vector3(0, 1.2, 0))
		lbl.position = screen_pos - Vector2(lbl.size.x * 0.5, lbl.size.y)
