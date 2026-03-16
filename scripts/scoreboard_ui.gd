extends RefCounted
class_name ScoreboardUI
## Manages scoreboard UI state and rendering.
## Extracted from GameHUD to keep game_hud.gd focused on layout/event routing.
## Holds entry arrays, expanded state, and all build/update logic.

var _gm: Node

# Style constants (mirrors GameHUD neon bar theme)
const COLOR_NEON_CYAN := Color(0.0, 0.9, 1.0)
const COLOR_TEXT_DIM := Color(0.50, 0.40, 0.62)
const SHADOW_COLOR := Color(0, 0, 0, 0.88)
const CORNER_RADIUS := 4

# Node references (owned by GameHUD, passed in at construction)
var full_panel: PanelContainer
var container: VBoxContainer
var compact_panel: Control
var compact_vbox: VBoxContainer

# State
var _entries: Array[Dictionary] = []
var _compact_entries: Array[Dictionary] = []
var _expanded: bool = false


func _init(gm: Node, full_panel_: PanelContainer, container_: VBoxContainer,
		compact_panel_: Control, compact_vbox_: VBoxContainer) -> void:
	_gm = gm
	full_panel = full_panel_
	container = container_
	compact_panel = compact_panel_
	compact_vbox = compact_vbox_


# --- Style helpers (local copies so ScoreboardUI has no dependency on GameHUD) ---

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


func _set_mouse_passthrough(ctrl: Control) -> void:
	ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _short_name(slot: int) -> String:
	if slot < 0 or slot >= _gm.player_names.size():
		return "Player %d" % (slot + 1)
	var full: String = _gm.player_names[slot]
	var paren := full.rfind(" (")
	if paren > 0:
		return full.substr(0, paren)
	return full


# --- Public API ---

func build() -> void:
	if container == null:
		return
	for child in container.get_children():
		child.queue_free()
	_entries.clear()

	for slot_idx in _gm.PLAYER_COUNT:
		var has_ball: bool = slot_idx < _gm.balls.size() and _gm.balls[slot_idx] != null
		if not has_ball:
			continue

		var panel := PanelContainer.new()
		_set_mouse_passthrough(panel)
		panel.custom_minimum_size = Vector2(150, 0)
		var style := _make_stylebox(Color(0, 0, 0, 0.4), Color.TRANSPARENT, 4, 0)
		style.content_margin_left = 6
		style.content_margin_right = 4
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		panel.add_theme_stylebox_override("panel", style)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 4)
		panel.add_child(hbox)

		var label := Label.new()
		_set_mouse_passthrough(label)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_shadow_color", SHADOW_COLOR)
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		hbox.add_child(label)

		var badge_style := _make_stylebox(Color(0, 0, 0, 0), Color.TRANSPARENT, 3, 0)
		badge_style.content_margin_left = 3
		badge_style.content_margin_right = 3
		badge_style.content_margin_top = 1
		badge_style.content_margin_bottom = 1
		var badge_panel := PanelContainer.new()
		_set_mouse_passthrough(badge_panel)
		badge_panel.custom_minimum_size = Vector2(32, 0)
		badge_panel.add_theme_stylebox_override("panel", badge_style)
		badge_panel.visible = false
		hbox.add_child(badge_panel)

		var badge_label := Label.new()
		_set_mouse_passthrough(badge_label)
		badge_label.add_theme_font_size_override("font_size", 11)
		badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge_panel.add_child(badge_label)

		container.add_child(panel)
		_entries.append({
			"panel": panel, "label": label, "slot": slot_idx, "style": style,
			"badge_panel": badge_panel, "badge_label": badge_label, "badge_style": badge_style,
		})

	build_compact()
	update()


func update() -> void:
	for entry in _entries:
		var slot_idx: int = entry["slot"]
		var label: Label = entry["label"]
		var style: StyleBoxFlat = entry["style"]
		var badge_panel: PanelContainer = entry["badge_panel"]
		var badge_label: Label = entry["badge_label"]
		var badge_style: StyleBoxFlat = entry["badge_style"]
		var color: Color = _gm.player_colors[slot_idx] if slot_idx < _gm.player_colors.size() else Color.WHITE
		var short_name := _short_name(slot_idx)
		var is_me := slot_idx == NetworkManager.my_slot
		var alive: bool = slot_idx in _gm.alive_players

		var wins: int = NetworkManager.room_scores.get(slot_idx, 0)
		var wins_str: String = ""
		if wins > 0:
			wins_str = " x%d" % wins

		if alive:
			var dot := ">" if is_me else " "
			label.text = "%s %s%s" % [dot, short_name, wins_str]
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

			var ball: PoolBall = _gm.balls[slot_idx] if slot_idx < _gm.balls.size() else null
			var pu_type: int = ball.held_powerup if ball else Powerup.Type.NONE
			if pu_type != Powerup.Type.NONE:
				var pu_color: Color = Powerup.get_color(pu_type)
				var armed: bool = ball != null and ball.powerup_armed
				var remaining := -1.0
				if ball != null:
					if pu_type == Powerup.Type.FREEZE and ball.powerup_armed:
						remaining = ball.freeze_timer
					elif ball.armed_timer > 0.0:
						remaining = ball.armed_timer
				var expiring := armed and remaining > 0.0 and remaining <= GameConfig.powerup_expiring_threshold
				badge_label.text = Powerup.get_symbol(pu_type)
				if expiring:
					var pulse := 0.65 + 0.35 * absf(sin(Time.get_ticks_msec() / 100.0))
					badge_style.bg_color = Color(0.45, 0.2, 0.05, 0.85 * pulse)
					badge_style.border_color = Color(1.0, 0.55, 0.2, pulse)
					badge_style.border_width_left = 1
					badge_style.border_width_right = 1
					badge_style.border_width_top = 1
					badge_style.border_width_bottom = 1
					badge_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3, pulse))
				elif armed:
					badge_style.bg_color = Color(pu_color.r * 0.25, pu_color.g * 0.25, pu_color.b * 0.25, 0.9)
					badge_style.border_color = pu_color
					badge_style.border_width_left = 1
					badge_style.border_width_right = 1
					badge_style.border_width_top = 1
					badge_style.border_width_bottom = 1
					badge_label.add_theme_color_override("font_color", pu_color)
				else:
					badge_style.bg_color = Color(0, 0, 0, 0)
					badge_style.border_width_left = 0
					badge_style.border_width_right = 0
					badge_style.border_width_top = 0
					badge_style.border_width_bottom = 0
					badge_label.add_theme_color_override("font_color",
						Color(pu_color.r * 0.55, pu_color.g * 0.55, pu_color.b * 0.55, 0.7))
				badge_panel.visible = true
			else:
				badge_panel.visible = false
		else:
			label.text = "  %s%s  [X]" % [short_name, wins_str]
			label.add_theme_color_override("font_color", Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 0.6))
			style.bg_color = Color(0, 0, 0, 0.25)
			style.border_width_left = 0
			style.border_width_right = 0
			style.border_width_top = 0
			style.border_width_bottom = 0
			badge_panel.visible = false

	update_compact()


func set_expanded(expanded: bool) -> void:
	_expanded = expanded
	full_panel.visible = expanded
	if compact_panel != null:
		compact_panel.visible = not expanded


func build_compact() -> void:
	if compact_vbox == null:
		return
	for child in compact_vbox.get_children():
		child.queue_free()
	_compact_entries.clear()

	for slot_idx in _gm.PLAYER_COUNT:
		var has_ball: bool = slot_idx < _gm.balls.size() and _gm.balls[slot_idx] != null
		if not has_ball:
			continue

		var row := HBoxContainer.new()
		_set_mouse_passthrough(row)
		row.add_theme_constant_override("separation", 4)
		row.set_alignment(BoxContainer.ALIGNMENT_CENTER)

		if slot_idx == NetworkManager.my_slot:
			var me_lbl := _make_label("\u25b6", 8, COLOR_NEON_CYAN, false)
			_set_mouse_passthrough(me_lbl)
			row.add_child(me_lbl)

		var dot_style := StyleBoxFlat.new()
		dot_style.bg_color = Color.WHITE
		dot_style.corner_radius_top_left = 3
		dot_style.corner_radius_top_right = 3
		dot_style.corner_radius_bottom_left = 3
		dot_style.corner_radius_bottom_right = 3
		var dot := PanelContainer.new()
		dot.custom_minimum_size = Vector2(10, 10)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", dot_style)
		row.add_child(dot)

		var pu_lbl := _make_label("", 11, Color.WHITE, false)
		_set_mouse_passthrough(pu_lbl)
		pu_lbl.visible = false
		row.add_child(pu_lbl)

		var wins_lbl := _make_label("", 11, COLOR_TEXT_DIM, false)
		_set_mouse_passthrough(wins_lbl)
		wins_lbl.visible = false
		row.add_child(wins_lbl)

		compact_vbox.add_child(row)
		_compact_entries.append({"slot": slot_idx, "dot": dot, "dot_style": dot_style,
			"pu_lbl": pu_lbl, "wins_lbl": wins_lbl})


func update_compact() -> void:
	for entry in _compact_entries:
		var slot_idx: int = entry["slot"]
		var dot: PanelContainer = entry["dot"]
		var dot_style: StyleBoxFlat = entry["dot_style"]
		var pu_lbl: Label = entry["pu_lbl"]
		var wins_lbl: Label = entry["wins_lbl"]
		var color: Color = _gm.player_colors[slot_idx] if slot_idx < _gm.player_colors.size() else Color.WHITE
		var alive: bool = slot_idx in _gm.alive_players

		if alive:
			dot_style.bg_color = color
			dot.modulate.a = 1.0
		else:
			dot_style.bg_color = Color(color.r * 0.35, color.g * 0.35, color.b * 0.35)
			dot.modulate.a = 0.5

		var wins: int = NetworkManager.room_scores.get(slot_idx, 0)
		if wins > 0:
			wins_lbl.text = str(wins)
			wins_lbl.visible = true
		else:
			wins_lbl.visible = false

		var ball: PoolBall = _gm.balls[slot_idx] if slot_idx < _gm.balls.size() else null
		var pu_type: int = ball.held_powerup if ball else Powerup.Type.NONE
		if alive and pu_type != Powerup.Type.NONE:
			var pu_color: Color = Powerup.get_color(pu_type)
			var armed: bool = ball != null and ball.powerup_armed
			var remaining := -1.0
			if ball != null:
				if pu_type == Powerup.Type.FREEZE and ball.powerup_armed:
					remaining = ball.freeze_timer
				elif ball.armed_timer > 0.0:
					remaining = ball.armed_timer
			var expiring := armed and remaining > 0.0 and remaining <= GameConfig.powerup_expiring_threshold
			pu_lbl.text = Powerup.get_symbol(pu_type)
			if expiring:
				var pulse := 0.65 + 0.35 * absf(sin(Time.get_ticks_msec() / 100.0))
				pu_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3, pulse))
			elif armed:
				pu_lbl.add_theme_color_override("font_color", pu_color)
			else:
				pu_lbl.add_theme_color_override("font_color",
					Color(pu_color.r * 0.55, pu_color.g * 0.55, pu_color.b * 0.55, 0.7))
			pu_lbl.visible = true
		else:
			pu_lbl.visible = false
