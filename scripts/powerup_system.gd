extends RefCounted
class_name PowerupSystem
## Manages all powerup logic: spawning, pickups, activation, effects, HUD.
## Instantiated by GameManager; RPCs route through NetworkManager.

var gm: Node  # GameManager reference

# Powerup items on table
var items: Array = []  # PowerupItem on clients, Dictionary on headless
var id_counter: int = 0
var spawn_timer: float = 10.0  # First spawn after 10s

# Per-player powerup tracking
var player_powerups: Dictionary = {}  # slot -> { "type": int, "armed": bool }

# Portal trap state (server-side authoritative, client mirrors for visuals)
# slot -> { "blue": Vector3, "orange": Vector3, "timer": float, "reentry": Dictionary }
# blue/orange = INF vector means not yet placed; timer = -1 means not yet active
var portal_states: Dictionary = {}
var _portal_visual_nodes: Dictionary = {}  # slot -> { "blue": Node3D, "orange": Node3D, "blue_arrow": Node3D, "orange_arrow": Node3D }
var _portal_ring: MeshInstance3D = null    # Placement-radius ring shown for local player
var gravity_wells: Dictionary = {}  # slot -> { "pos": Vector3, "timer": float }
var _gravity_well_visual_nodes: Dictionary = {}  # slot -> Node3D
var _swap_highlight_rings: Dictionary = {}   # enemy_slot -> MeshInstance3D (faint rings when holding SWAP)
var _swap_target_ring: MeshInstance3D = null # Bright ring on currently targeted ball
var _portal_preview_root: Node3D = null
var _portal_preview_ring: MeshInstance3D = null
var _portal_preview_arrow: MeshInstance3D = null
var _portal_preview_yaw: float = 0.0
var _portal_hint_shown: bool = false

# HUD elements
var hud_panel: PanelContainer
var hud_label: RichTextLabel


func _init(game_manager: Node) -> void:
	gm = game_manager


func reset() -> void:
	# Free any visual powerup items on the table
	for item in items:
		if item is Node and is_instance_valid(item):
			item.queue_free()
	items.clear()
	player_powerups.clear()
	portal_states.clear()
	gravity_wells.clear()
	for slot in _portal_visual_nodes:
		_remove_portal_visual_nodes(slot)
	_portal_visual_nodes.clear()
	for slot in _gravity_well_visual_nodes:
		var gw_node: Node3D = _gravity_well_visual_nodes[slot]
		if gw_node != null and is_instance_valid(gw_node):
			gw_node.queue_free()
	_gravity_well_visual_nodes.clear()
	if _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
	_portal_ring = null
	if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
		_portal_preview_root.queue_free()
	_portal_preview_root = null
	_portal_preview_ring = null
	_portal_preview_arrow = null
	_portal_preview_yaw = 0.0
	_portal_hint_shown = false
	_clear_swap_rings()
	spawn_timer = 10.0
	update_hud()


func _log(msg: String) -> void:
	gm._log(msg)


func rotate_portal_preview(step_deg: float) -> void:
	_portal_preview_yaw = wrapf(_portal_preview_yaw + deg_to_rad(step_deg), -PI, PI)


func get_portal_preview_yaw() -> float:
	return _portal_preview_yaw


func _is_valid_cursor_pos(cursor_world_pos: Vector3) -> bool:
	return is_finite(cursor_world_pos.x) and is_finite(cursor_world_pos.z) and abs(cursor_world_pos.x) < 10000.0


func _build_portal_arrow_node(color: Color, alpha: float = 0.95) -> Node3D:
	var root := Node3D.new()

	var shaft := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.5, 0.03, 0.09)
	shaft.mesh = shaft_mesh
	shaft.position = Vector3(0.22, 0.14, 0.0)
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	shaft_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shaft_mat.emission_enabled = true
	shaft_mat.emission = color
	shaft_mat.emission_energy_multiplier = 2.0
	shaft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shaft.material_override = shaft_mat
	root.add_child(shaft)

	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.09
	tip_mesh.height = 0.14
	tip.mesh = tip_mesh
	tip.position = Vector3(0.52, 0.14, 0.0)
	tip.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	var tip_mat := shaft_mat.duplicate()
	tip.material_override = tip_mat
	root.add_child(tip)

	return root


func _ensure_portal_preview_nodes() -> void:
	if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
		return
	_portal_preview_root = Node3D.new()
	_portal_preview_root.name = "PortalPreview"
	gm.add_child(_portal_preview_root)

	_portal_preview_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	var det_r: float = GameConfig.portal_trap_detection_radius
	torus.inner_radius = det_r - 0.12
	torus.outer_radius = det_r
	_portal_preview_ring.mesh = torus
	_portal_preview_ring.rotation_degrees.x = 90.0
	var ring_mat := StandardMaterial3D.new()
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.emission_enabled = true
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_portal_preview_ring.material_override = ring_mat
	_portal_preview_root.add_child(_portal_preview_ring)

	_portal_preview_arrow = _build_portal_arrow_node(Color.WHITE, 0.75)
	_portal_preview_root.add_child(_portal_preview_arrow)

# --- HUD ---

func create_hud(parent: CanvasLayer) -> void:
	hud_panel = PanelContainer.new()
	hud_panel.anchor_left = 0.5
	hud_panel.anchor_top = 1.0
	hud_panel.anchor_right = 0.5
	hud_panel.anchor_bottom = 1.0
	hud_panel.offset_left = -130
	hud_panel.offset_top = -90
	hud_panel.offset_right = 130
	hud_panel.offset_bottom = -55
	hud_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hud_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.12, 0.8)
	style.border_color = Color(1, 0.85, 0.2, 0.4)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	hud_panel.add_theme_stylebox_override("panel", style)
	hud_panel.visible = false

	hud_label = RichTextLabel.new()
	hud_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_label.bbcode_enabled = true
	hud_label.fit_content = true
	hud_label.add_theme_font_size_override("normal_font_size", 17)
	hud_panel.add_child(hud_label)
	parent.add_child(hud_panel)


func update_hud() -> void:
	if hud_panel == null:
		return

	var my_slot := NetworkManager.my_slot
	if my_slot in player_powerups:
		var pw: Dictionary = player_powerups[my_slot]
		var ptype: int = pw.get("type", Powerup.Type.NONE)
		if ptype != Powerup.Type.NONE:
			var color := Powerup.get_color(ptype)
			var armed: bool = pw.get("armed", false)
			if armed:
				hud_label.text = "[color=#%s]%s %s[/color]  [color=#ffcc44]ARMED[/color]" % [
					color.to_html(false), Powerup.get_symbol(ptype), Powerup.get_powerup_name(ptype)]
				# Pulse border when armed
				var style: StyleBoxFlat = hud_panel.get_theme_stylebox("panel")
				style.border_color = Color(1, 0.85, 0.2, 0.8)
				style.border_width_left = 2
				style.border_width_right = 2
				style.border_width_top = 2
				style.border_width_bottom = 2
			else:
				hud_label.text = "[color=#%s]%s %s[/color]  [color=#999999]SPACE[/color]" % [
					color.to_html(false), Powerup.get_symbol(ptype), Powerup.get_powerup_name(ptype)]
				var style: StyleBoxFlat = hud_panel.get_theme_stylebox("panel")
				style.border_color = Color(1, 0.85, 0.2, 0.4)
				style.border_width_left = 1
				style.border_width_right = 1
				style.border_width_top = 1
				style.border_width_bottom = 1
			hud_panel.visible = true
		else:
			hud_panel.visible = false
	else:
		hud_panel.visible = false


func hide_hud() -> void:
	if hud_panel:
		hud_panel.visible = false


func get_powerup_symbol(slot: int) -> String:
	if slot in player_powerups:
		return Powerup.get_symbol(player_powerups[slot]["type"])
	return ""


# --- Server tick (called from GameManager._physics_process) ---

func server_tick(delta: float) -> void:
	# Powerup spawning
	if not gm.game_over:
		spawn_timer -= delta
		if spawn_timer <= 0.0:
			spawn_timer = randf_range(GameConfig.powerup_spawn_min_delay, GameConfig.powerup_spawn_max_delay)
			if items.size() < GameConfig.powerup_max_on_table:
				server_spawn_powerup()

	# Freeze timer countdown
	for ball in gm.balls:
		if ball != null and ball.is_alive and ball.held_powerup == Powerup.Type.FREEZE and ball.powerup_armed:
			ball.freeze_timer -= delta
			if ball.freeze_timer <= 0.0:
				ball.powerup_armed = false
				ball.freeze = false
				ball.held_powerup = Powerup.Type.NONE
				_log("FREEZE_EXPIRED ball=%d" % ball.slot)
				_rpc_consumed(ball.slot)

	# Portal trap: tick active portal pairs and check ball transits
	_server_tick_portals(delta)
	_server_tick_gravity_wells(delta)

	# Armed powerup timeout — auto-trigger or consume after timeout
	for ball in gm.balls:
		if ball == null or not ball.is_alive or ball.armed_timer <= 0.0:
			continue
		ball.armed_timer -= delta
		if ball.armed_timer <= 0.0:
			ball.armed_timer = 0.0
			if ball.held_powerup != Powerup.Type.NONE and ball.powerup_armed:
				_log("POWERUP_TIMEOUT ball=%d type=%s" % [ball.slot, Powerup.get_powerup_name(ball.held_powerup)])
				Powerup.get_handler(ball.held_powerup).on_timeout(ball, self)


func _server_tick_portals(delta: float) -> void:
	var det_sq: float = GameConfig.portal_trap_detection_radius * GameConfig.portal_trap_detection_radius
	var expired_slots: Array = []

	for slot in portal_states:
		var state = portal_states[slot]
		if state["timer"] < 0.0:
			continue  # Blue placed, waiting for orange — armed_timer handles expiry

		state["timer"] -= delta
		if state["timer"] <= 0.0:
			expired_slots.append(slot)
			continue

		# Tick down per-ball re-entry cooldowns
		var expired_reentry: Array = []
		for ball_slot in state["reentry"]:
			state["reentry"][ball_slot] -= delta
			if state["reentry"][ball_slot] <= 0.0:
				expired_reentry.append(ball_slot)
		for ball_slot in expired_reentry:
			state["reentry"].erase(ball_slot)

		var blue: Vector3 = state["blue"]
		var orange: Vector3 = state["orange"]

		for ball in gm.balls:
			if ball == null or not ball.is_alive or ball.is_pocketing:
				continue
			if ball.slot in state["reentry"]:
				continue
			var bx: float = ball.position.x
			var bz: float = ball.position.z
			var bdx_b: float = bx - blue.x
			var bdz_b: float = bz - blue.z
			if bdx_b * bdx_b + bdz_b * bdz_b < det_sq:
				_portal_transit(ball, blue, orange, slot, state.get("blue_yaw", 0.0), state.get("orange_yaw", 0.0))
				continue
			var bdx_o: float = bx - orange.x
			var bdz_o: float = bz - orange.z
			if bdx_o * bdx_o + bdz_o * bdz_o < det_sq:
				_portal_transit(ball, orange, blue, slot, state.get("orange_yaw", 0.0), state.get("blue_yaw", 0.0))

	for slot in expired_slots:
		_log("PORTAL_EXPIRED placer=%d" % slot)
		portal_states.erase(slot)
		if NetworkManager.is_single_player:
			gm.client_receive_portals_expired(slot)
		else:
			for pid in NetworkManager.get_room_peers(gm._room_code):
				NetworkManager._rpc_game_portals_expired.rpc_id(pid, slot)


func _server_tick_gravity_wells(delta: float) -> void:
	if gravity_wells.is_empty():
		return
	var radius: float = GameConfig.gravity_well_radius
	var radius_sq: float = radius * radius
	var max_speed_sq: float = GameConfig.gravity_well_max_speed * GameConfig.gravity_well_max_speed
	var expired_slots: Array[int] = []

	for slot in gravity_wells:
		var state: Dictionary = gravity_wells[slot]
		state["timer"] -= delta
		if state["timer"] <= 0.0:
			expired_slots.append(slot)
			continue

		var center: Vector3 = state["pos"]
		for ball in gm.balls:
			if ball == null or not ball.is_alive or ball.is_pocketing:
				continue
			var dx: float = center.x - ball.position.x
			var dz: float = center.z - ball.position.z
			var dist_sq: float = dx * dx + dz * dz
			if dist_sq >= radius_sq or dist_sq <= 0.01:
				continue
			if ball.linear_velocity.length_squared() > max_speed_sq:
				continue
			var dist := sqrt(dist_sq)
			var falloff := 1.0 - (dist / radius)
			var pull := Vector3(dx / dist, 0.0, dz / dist) * (GameConfig.gravity_well_pull_strength * falloff * delta)
			ball.apply_central_impulse(pull)

	for slot in expired_slots:
		gravity_wells.erase(slot)
		_log("GRAVITY_WELL_EXPIRED slot=%d" % slot)
		if NetworkManager.is_single_player:
			gm.client_receive_gravity_well_expired(slot)
		else:
			for pid in NetworkManager.get_room_peers(gm._room_code):
				NetworkManager._rpc_game_gravity_well_expired.rpc_id(pid, slot)


func _portal_transit(ball: PoolBall, from_pos: Vector3, to_pos: Vector3, placer_slot: int, from_yaw: float, to_yaw: float) -> void:
	var preserved_linear := ball.linear_velocity
	var preserved_angular := ball.angular_velocity
	# Portal 2-style mapping: preserve local momentum through portals,
	# applying entry->exit orientation delta plus 180deg front-face flip.
	var yaw_delta := to_yaw - from_yaw + PI
	var mapped_linear := preserved_linear.rotated(Vector3.UP, yaw_delta)
	ball.position = Vector3(to_pos.x, 0.0, to_pos.z)
	ball.linear_velocity = mapped_linear
	ball.angular_velocity = preserved_angular
	ball.synced_velocity = mapped_linear
	portal_states[placer_slot]["reentry"][ball.slot] = GameConfig.portal_trap_reentry_cooldown
	_log("PORTAL_TRANSIT ball=%d from=(%.1f,%.1f,%.1fdeg) to=(%.1f,%.1f,%.1fdeg) vel=(%.2f,%.2f)->(%.2f,%.2f)" % [
		ball.slot,
		from_pos.x, from_pos.z, rad_to_deg(from_yaw),
		to_pos.x, to_pos.z, rad_to_deg(to_yaw),
		preserved_linear.x, preserved_linear.z,
		mapped_linear.x, mapped_linear.z,
	])
	if NetworkManager.is_single_player:
		gm.client_receive_portal_transit(ball.slot, from_pos.x, from_pos.z, to_pos.x, to_pos.z)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_portal_transit.rpc_id(pid, ball.slot, from_pos.x, from_pos.z, to_pos.x, to_pos.z)


# --- RPC dispatch helpers (single-player vs multiplayer) ---

func _rpc_consumed(slot: int) -> void:
	if NetworkManager.is_single_player:
		gm.client_receive_powerup_consumed(slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot)


func _rpc_to_room(rpc_method: StringName, args: Array) -> void:
	for pid in NetworkManager.get_room_peers(gm._room_code):
		NetworkManager.callv(rpc_method + &".rpc_id", [pid] + args)


# --- Spawning ---

func server_spawn_powerup() -> void:
	# Scale bomb weight down for small player counts — bombs overwhelm 2-3 player games
	var alive_count: int = gm.alive_players.size()
	var bomb_w := lerpf(0.35, 1.6, clampf((alive_count - 2) / 6.0, 0.0, 1.0)) * GameConfig.powerup_weight_bomb
	var allowed_types: Array[int] = []
	if NetworkManager.is_single_player:
		allowed_types = NetworkManager.solo_enabled_powerups
	elif gm._room_code in NetworkManager._rooms:
		allowed_types = NetworkManager._rooms[gm._room_code].get("enabled_powerups", [])
	var type := Powerup.random_type_from_allowed(allowed_types, bomb_w)
	var pos := Vector3.ZERO

	var found := false
	var attempts := 0
	for _attempt in 20:
		attempts += 1
		var tx := randf_range(-11.0, 11.0)
		var tz := randf_range(-5.0, 5.0)
		var candidate := Vector3(tx, 0.0, tz)
		var safe := true

		for pocket in gm.POCKET_POSITIONS:
			var pdx: float = tx - pocket.x
			var pdz: float = tz - pocket.z
			if pdx * pdx + pdz * pdz < 4.0:  # 2.0^2
				safe = false
				break
		if not safe:
			continue

		for ball in gm.balls:
			if ball != null and ball.is_alive:
				# Use position (local to room) for server-side checks
				var bdx: float = tx - ball.position.x
				var bdz: float = tz - ball.position.z
				if bdx * bdx + bdz * bdz < 2.25:  # 1.5^2
					safe = false
					break
		if not safe:
			continue

		pos = candidate
		found = true
		break

	if not found:
		_log("POWERUP_SPAWN_FAILED type=%s attempts=%d table_count=%d/%d" % [
			Powerup.get_powerup_name(type), attempts, items.size(), GameConfig.powerup_max_on_table])
		return

	id_counter += 1
	var id := id_counter

	if gm._is_headless:
		items.append({"id": id, "type": type, "pos": pos})
	else:
		var item := Powerup.PowerupItem.create(id, type, pos)
		gm.add_child(item)
		items.append(item)

	if not NetworkManager.is_single_player:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_spawn_powerup.rpc_id(pid, id, type, pos.x, pos.z)
	_log("POWERUP_SPAWN id=%d type=%s pos=(%.1f,%.1f) attempts=%d table_count=%d/%d" % [
		id, Powerup.get_powerup_name(type), pos.x, pos.z,
		attempts, items.size(), GameConfig.powerup_max_on_table])


# --- Pickup detection (server-side) ---

func server_check_pickups() -> void:
	var to_remove: Array[int] = []

	for i in items.size():
		var item = items[i]
		var pu_id: int
		var pu_type: int
		var pu_pos: Vector3

		if item is Powerup.PowerupItem:
			pu_id = item.powerup_id
			pu_type = item.powerup_type
			pu_pos = item.position
		elif item is Dictionary:
			pu_id = int(item["id"])
			pu_type = int(item["type"])
			pu_pos = item["pos"]
		else:
			continue

		var pu2 := Vector2(pu_pos.x, pu_pos.z)
		for ball in gm.balls:
			if ball == null or not ball.is_alive or ball.is_pocketing:
				continue
			if ball.held_powerup != Powerup.Type.NONE:
				continue
			# Use position (local) for server-side checks
			var bp := Vector2(ball.position.x, ball.position.z)
			var vel2 := Vector2(ball.linear_velocity.x, ball.linear_velocity.z)
			var step := vel2 * (1.0 / 60.0)
			var closest_dist: float
			if step.length_squared() < 0.001:
				closest_dist = bp.distance_to(pu2)
			else:
				var seg_start := bp - step
				var seg := bp - seg_start
				var t := clampf((pu2 - seg_start).dot(seg) / seg.length_squared(), 0.0, 1.0)
				closest_dist = (seg_start + seg * t).distance_to(pu2)
			if closest_dist < GameConfig.powerup_pickup_radius:
				ball.held_powerup = pu_type
				var ball_spd: float = ball.linear_velocity.length()
				_log("POWERUP_SERVER_PICKUP ball=%d type=%d (int) name=%s" % [
					ball.slot, pu_type, Powerup.get_powerup_name(pu_type)])
				if NetworkManager.is_single_player:
					gm.client_receive_powerup_picked_up(pu_id, ball.slot, pu_type)
					# on_picked_up() handles item removal
				else:
					to_remove.append(i)
					for pid in NetworkManager.get_room_peers(gm._room_code):
						NetworkManager._rpc_game_powerup_picked_up.rpc_id(pid, pu_id, ball.slot, pu_type)
				_log("POWERUP_PICKUP ball=%d type=%s ball_spd=%.2f pos=(%.1f,%.1f) dist=%.2f" % [
					ball.slot, Powerup.get_powerup_name(pu_type), ball_spd,
					ball.position.x, ball.position.z, closest_dist])
				break

	to_remove.reverse()
	for idx in to_remove:
		var item = items[idx]
		if item is Node:
			item.queue_free()
		items.remove_at(idx)


# --- Client activation (Space key) ---

func try_activate(my_slot: int, my_ball: PoolBall, cursor_world_pos: Vector3 = Vector3.ZERO, portal_yaw: float = 0.0) -> void:
	_log("POWERUP_ACTIVATE_REQUEST ball=%d held_powerup=%d powerup_armed=%s" % [
		my_slot, my_ball.held_powerup, my_ball.powerup_armed])

	# Portal trap: both first and second SPACE press route through here with cursor position
	if my_ball.held_powerup == Powerup.Type.PORTAL_TRAP:
		if NetworkManager.is_single_player:
			server_try_place_portal(my_slot, my_ball, cursor_world_pos, portal_yaw)
		else:
			_log("PORTAL_PLACE_REQUEST ball=%d cursor=(%.1f,%.1f)" % [my_slot, cursor_world_pos.x, cursor_world_pos.z])
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "portal_trap", cursor_world_pos, portal_yaw)
		return

	# Swap: cursor-targeted instant trigger — pass cursor position to server
	if my_ball.held_powerup == Powerup.Type.SWAP and not my_ball.powerup_armed:
		# Client-side guard: only fire if there is actually a valid target in range.
		# This prevents wasting the powerup on empty space or yourself.
		var snap_sq: float = GameConfig.swap_cursor_snap_radius * GameConfig.swap_cursor_snap_radius
		var has_target := false
		for b in gm.balls:
			if b == null or not b.is_alive or b.is_pocketing or b == my_ball:
				continue
			var dx: float = b.position.x - cursor_world_pos.x
			var dz: float = b.position.z - cursor_world_pos.z
			if dx * dx + dz * dz < snap_sq:
				has_target = true
				break
		if not has_target:
			_log("SWAP_BLOCKED_CLIENT no_target ball=%d cursor=(%.1f,%.1f)" % [my_slot, cursor_world_pos.x, cursor_world_pos.z])
			return
		if NetworkManager.is_single_player:
			trigger_swap(my_ball, cursor_world_pos)
		else:
			_log("SWAP_REQUEST ball=%d cursor=(%.1f,%.1f)" % [my_slot, cursor_world_pos.x, cursor_world_pos.z])
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "swap", cursor_world_pos)
		return

	# Gravity Well: cursor-targeted instant placement
	if my_ball.held_powerup == Powerup.Type.GRAVITY_WELL and not my_ball.powerup_armed:
		if NetworkManager.is_single_player:
			server_place_gravity_well(my_slot, my_ball, cursor_world_pos)
		else:
			_log("GRAVITY_WELL_REQUEST ball=%d cursor=(%.1f,%.1f)" % [my_slot, cursor_world_pos.x, cursor_world_pos.z])
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "gravity_well", cursor_world_pos)
		return

	if my_ball.held_powerup != Powerup.Type.NONE and not my_ball.powerup_armed:
		if NetworkManager.is_single_player:
			var h := Powerup.get_handler(my_ball.held_powerup)
			if h.on_activate(my_ball, self):
				my_ball.powerup_armed = true
				my_ball.armed_timer = GameConfig.powerup_armed_timeout
				_log("POWERUP_ARMED ball=%d type=%s timeout=%.1fs (single_player)" % [my_slot, Powerup.get_powerup_name(my_ball.held_powerup), GameConfig.powerup_armed_timeout])
				on_powerup_armed(my_slot, my_ball.held_powerup)
		else:
			var type_str: String = {2: "bomb", 3: "freeze"}.get(my_ball.held_powerup, "")
			if not type_str.is_empty():
				_log("POWERUP_ARMED ball=%d type=%s sending_rpc_to_server" % [my_slot, type_str])
				NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, type_str)
	else:
		_log("POWERUP_ACTIVATE_FAIL ball=%d no_valid_powerup held=%d" % [my_slot, my_ball.held_powerup])


# --- Server activation (RPC handler body) ---

func server_activate(slot: int, powerup_type: String, ball: PoolBall, cursor_world_pos: Vector3 = Vector3.ZERO, portal_yaw: float = 0.0) -> void:
	# Portal trap: two-step placement handled separately (bypasses armed state logic)
	if powerup_type == "portal_trap":
		if ball.held_powerup == Powerup.Type.PORTAL_TRAP:
			server_try_place_portal(slot, ball, cursor_world_pos, portal_yaw)
		return

	# Swap: cursor-targeted instant trigger
	if powerup_type == "swap":
		if ball.held_powerup == Powerup.Type.SWAP and not ball.powerup_armed:
			trigger_swap(ball, cursor_world_pos)
		return

	# Gravity Well: cursor-targeted instant trigger
	if powerup_type == "gravity_well":
		if ball.held_powerup == Powerup.Type.GRAVITY_WELL and not ball.powerup_armed:
			server_place_gravity_well(slot, ball, cursor_world_pos)
		return

	var type_names: Dictionary = {2: "bomb", 3: "freeze"}
	var expected_type: String = type_names.get(ball.held_powerup, "")
	if ball.held_powerup == Powerup.Type.NONE or ball.powerup_armed or powerup_type != expected_type:
		_log("POWERUP_RPC_FAIL ball=%d invalid_state held=%d powerup_armed=%s" % [
			slot, ball.held_powerup, ball.powerup_armed])
		return
	var h := Powerup.get_handler(ball.held_powerup)
	if h.on_activate(ball, self):
		ball.powerup_armed = true
		ball.armed_timer = GameConfig.powerup_armed_timeout
		_log("POWERUP_ARMED ball=%d type=%s timeout=%.1fs (server)" % [slot, Powerup.get_powerup_name(ball.held_powerup), GameConfig.powerup_armed_timeout])
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_powerup_armed.rpc_id(pid, slot, ball.held_powerup)


# --- Powerup effects (server-side) ---

func trigger_bomb(ball: PoolBall) -> void:
	_log("BOMB_TRIGGER_START ball=%d pos=(%.1f,%.1f)" % [ball.slot, ball.position.x, ball.position.z])
	ball.held_powerup = Powerup.Type.NONE
	ball.powerup_armed = false
	ball.armed_timer = 0.0

	# Use position (local) for server-side calculations
	var center := ball.position
	var sw_force := GameConfig.bomb_force
	var sw_radius := GameConfig.bomb_radius
	var affected_count := 0

	for other_ball in gm.balls:
		if other_ball == null or not other_ball.is_alive or other_ball.is_pocketing or other_ball == ball:
			continue
		var dir: Vector3 = other_ball.position - center
		dir.y = 0
		var d: float = dir.length()
		if d < sw_radius and d > 0.01:
			var falloff: float = 1.0 - (d / sw_radius)
			var impulse: Vector3 = dir.normalized() * sw_force * falloff
			other_ball.apply_central_impulse(impulse)
			affected_count += 1
			_log("BOMB_AFFECT ball=%d dist=%.2f impulse=%.1f" % [other_ball.slot, d, impulse.length()])

	if NetworkManager.is_single_player:
		gm.client_receive_shockwave_effect(center.x, center.z)
		gm.client_receive_powerup_consumed(ball.slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_shockwave_effect.rpc_id(pid, center.x, center.z)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, ball.slot)

	_log("BOMB_EXPLODE ball=%d pos=(%.1f,%.1f) affected=%d" % [ball.slot, center.x, center.z, affected_count])


func server_place_gravity_well(slot: int, ball: PoolBall, cursor_pos: Vector3) -> void:
	if not _is_valid_gravity_well_pos(cursor_pos):
		_log("GRAVITY_WELL_REJECTED ball=%d pos=(%.1f,%.1f)" % [slot, cursor_pos.x, cursor_pos.z])
		return
	gravity_wells[slot] = {
		"pos": Vector3(cursor_pos.x, 0.0, cursor_pos.z),
		"timer": GameConfig.gravity_well_duration,
	}
	ball.held_powerup = Powerup.Type.NONE
	ball.powerup_armed = false
	ball.armed_timer = 0.0
	_log("GRAVITY_WELL_PLACED ball=%d pos=(%.1f,%.1f) duration=%.1fs radius=%.1f" % [
		slot, cursor_pos.x, cursor_pos.z, GameConfig.gravity_well_duration, GameConfig.gravity_well_radius])

	if NetworkManager.is_single_player:
		gm.client_receive_gravity_well_placed(slot, cursor_pos.x, cursor_pos.z, GameConfig.gravity_well_duration)
		gm.client_receive_powerup_consumed(slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_gravity_well_placed.rpc_id(pid, slot, cursor_pos.x, cursor_pos.z, GameConfig.gravity_well_duration)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot)

# --- Portal trap placement (server-side, called for both first and second SPACE) ---

func server_try_place_portal(slot: int, ball: PoolBall, cursor_pos: Vector3, portal_yaw: float = 0.0) -> void:
	if not slot in portal_states:
		portal_states[slot] = {
			"blue": Vector3.INF, "orange": Vector3.INF,
			"blue_yaw": 0.0, "orange_yaw": 0.0,
			"timer": -1.0, "reentry": {}
		}

	var state = portal_states[slot]
	var blue_placed: bool = state["blue"] != Vector3.INF

	if not _is_valid_portal_pos(cursor_pos, slot, blue_placed):
		_log("PORTAL_PLACE_REJECTED ball=%d portal=%s pos=(%.1f,%.1f)" % [
			slot, "orange" if blue_placed else "blue", cursor_pos.x, cursor_pos.z])
		return

	if not blue_placed:
		# First portal: blue
		state["blue"] = cursor_pos
		state["blue_yaw"] = portal_yaw
		ball.powerup_armed = true
		ball.armed_timer = GameConfig.powerup_armed_timeout  # timeout waiting for orange
		_log("PORTAL_BLUE_PLACED ball=%d pos=(%.1f,%.1f)" % [slot, cursor_pos.x, cursor_pos.z])
		if NetworkManager.is_single_player:
			gm.client_receive_portal_placed(slot, 0, cursor_pos.x, cursor_pos.z, portal_yaw)
		else:
			for pid in NetworkManager.get_room_peers(gm._room_code):
				NetworkManager._rpc_game_portal_placed.rpc_id(pid, slot, 0, cursor_pos.x, cursor_pos.z, portal_yaw)
	else:
		# Second portal: orange — activate both
		state["orange"] = cursor_pos
		state["orange_yaw"] = portal_yaw
		state["timer"] = GameConfig.portal_trap_duration
		ball.powerup_armed = false
		ball.armed_timer = 0.0
		ball.held_powerup = Powerup.Type.NONE
		_log("PORTAL_ORANGE_PLACED ball=%d pos=(%.1f,%.1f) both_active duration=%.1fs" % [
			slot, cursor_pos.x, cursor_pos.z, GameConfig.portal_trap_duration])
		if NetworkManager.is_single_player:
			gm.client_receive_portal_placed(slot, 1, cursor_pos.x, cursor_pos.z, portal_yaw)
			gm.client_receive_powerup_consumed(slot)
		else:
			for pid in NetworkManager.get_room_peers(gm._room_code):
				NetworkManager._rpc_game_portal_placed.rpc_id(pid, slot, 1, cursor_pos.x, cursor_pos.z, portal_yaw)
				NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot)


func cancel_portal(slot: int) -> void:
	if slot in portal_states:
		portal_states.erase(slot)
	_log("PORTAL_CANCELLED ball=%d" % slot)
	if NetworkManager.is_single_player:
		gm.client_receive_portals_expired(slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_portals_expired.rpc_id(pid, slot)


func _is_valid_portal_pos(pos: Vector3, placer_slot: int, check_min_dist: bool) -> bool:
	# Must be on the table surface
	if abs(pos.x) > 13.5 or abs(pos.z) > 7.5:
		return false
	# Must not be near a pocket
	var pex: float = GameConfig.portal_trap_pocket_exclusion
	var pex_sq: float = pex * pex
	for pocket in gm.POCKET_POSITIONS:
		var dx: float = pos.x - pocket.x
		var dz: float = pos.z - pocket.z
		if dx * dx + dz * dz < pex_sq:
			return false
	# Must not overlap any alive ball
	var bex: float = GameConfig.portal_trap_ball_exclusion
	var bex_sq: float = bex * bex
	for ball in gm.balls:
		if ball == null or not ball.is_alive:
			continue
		var dx: float = pos.x - ball.position.x
		var dz: float = pos.z - ball.position.z
		if dx * dx + dz * dz < bex_sq:
			return false
	# If orange is being placed, must be far enough from blue
	if check_min_dist and placer_slot in portal_states:
		var blue: Vector3 = portal_states[placer_slot]["blue"]
		if blue != Vector3.INF:
			var dx: float = pos.x - blue.x
			var dz: float = pos.z - blue.z
			var md: float = GameConfig.portal_trap_min_portal_dist
			if dx * dx + dz * dz < md * md:
				return false
	return true


func _is_valid_gravity_well_pos(pos: Vector3) -> bool:
	if not (is_finite(pos.x) and is_finite(pos.z)):
		return false
	if abs(pos.x) > 13.5 or abs(pos.z) > 7.5:
		return false
	var pex: float = GameConfig.gravity_well_pocket_exclusion
	var pex_sq: float = pex * pex
	for pocket in gm.POCKET_POSITIONS:
		var dx: float = pos.x - pocket.x
		var dz: float = pos.z - pocket.z
		if dx * dx + dz * dz < pex_sq:
			return false
	return true


func trigger_swap(ball: PoolBall, cursor_world_pos: Vector3) -> void:
	# Find closest alive enemy to cursor position within snap radius
	var snap_sq: float = GameConfig.swap_cursor_snap_radius * GameConfig.swap_cursor_snap_radius
	var target: PoolBall = null
	var target_dist_sq := INF
	for b in gm.balls:
		if b == null or not b.is_alive or b.is_pocketing or b == ball:
			continue
		var dx: float = b.position.x - cursor_world_pos.x
		var dz: float = b.position.z - cursor_world_pos.z
		var dist_sq := dx * dx + dz * dz
		if dist_sq < snap_sq and dist_sq < target_dist_sq:
			target_dist_sq = dist_sq
			target = b

	if target == null:
		# No valid target in range — do NOT consume, leave powerup intact
		_log("SWAP_NO_TARGET ball=%d cursor=(%.1f,%.1f)" % [ball.slot, cursor_world_pos.x, cursor_world_pos.z])
		return

	ball.held_powerup = Powerup.Type.NONE
	ball.powerup_armed = false
	ball.armed_timer = 0.0

	var old_a := ball.position
	var old_b := target.position
	var vel_a := ball.linear_velocity
	var vel_b := target.linear_velocity
	var ang_a := ball.angular_velocity
	var ang_b := target.angular_velocity

	# Swap positions and velocities
	ball.position = old_b
	target.position = old_a
	ball.linear_velocity = vel_b
	ball.angular_velocity = ang_b
	target.linear_velocity = vel_a
	target.angular_velocity = ang_a

	_log("SWAP ball=%d and ball=%d (%.1f,%.1f)<->(%.1f,%.1f) vel_a=%.1f vel_b=%.1f" % [
		ball.slot, target.slot, old_a.x, old_a.z, old_b.x, old_b.z,
		vel_a.length(), vel_b.length()])
	if NetworkManager.is_single_player:
		gm.client_receive_swap_effect(ball.slot, old_a.x, old_a.z, target.slot, old_b.x, old_b.z)
		gm.client_receive_powerup_consumed(ball.slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_swap_effect.rpc_id(pid, ball.slot, old_a.x, old_a.z, target.slot, old_b.x, old_b.z)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, ball.slot)


func grant_kill_reward(killer_slot: int) -> void:
	if killer_slot < 0 or killer_slot >= gm.balls.size():
		return
	var killer: PoolBall = gm.balls[killer_slot]
	if killer == null or not killer.is_alive:
		return
	if killer.held_powerup != Powerup.Type.NONE:
		return  # already carrying a powerup — don't overwrite
	var type := Powerup.random_type()
	killer.held_powerup = type
	_log("KILL_REWARD killer=%d type=%s" % [killer_slot, Powerup.get_powerup_name(type)])
	if NetworkManager.is_single_player:
		gm.client_receive_powerup_picked_up(-1, killer_slot, type)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_powerup_picked_up.rpc_id(pid, -1, killer_slot, type)



# --- RPC handler bodies (called from GameManager's client_receive_* methods) ---

func on_spawned(id: int, type: int, pos_x: float, pos_z: float) -> void:
	var item := Powerup.PowerupItem.create(id, type, Vector3(pos_x, 0.0, pos_z))
	gm.add_child(item)
	items.append(item)


func on_picked_up(powerup_id: int, slot: int, type: int) -> void:
	_log("POWERUP_RPC_PICKUP id=%d slot=%d type=%d" % [powerup_id, slot, type])

	# Remove the item visually
	for i in items.size():
		var item = items[i]
		if item is Powerup.PowerupItem and item.powerup_id == powerup_id:
			if not gm._is_headless:
				ComicBurst.fire(item.position + Vector3(0, 0.2, 0), Powerup.get_color(type), 0.5)
			item.queue_free()
			items.remove_at(i)
			break

	# Update ball's held_powerup
	if slot < gm.balls.size() and gm.balls[slot] != null:
		gm.balls[slot].held_powerup = type
		_log("POWERUP_BALL_UPDATED ball=%d held_powerup=%d" % [slot, type])
	else:
		_log("POWERUP_BALL_FAIL slot=%d out_of_range_or_null balls_size=%d" % [slot, gm.balls.size()])

	# Track powerup
	player_powerups[slot] = {"type": type, "armed": false}
	_log("POWERUP_PICKUP ball=%d type=%s armed=false" % [slot, Powerup.get_powerup_name(type)])

	update_hud()
	gm.game_hud.update_scoreboard()

	# Flash info label
	if slot == NetworkManager.my_slot and gm.game_hud:
		var color := Powerup.get_color(type)
		gm.game_hud.set_info_text("%s (SPACE) - %s" % [Powerup.get_powerup_name(type), Powerup.get_desc(type)], color)
		gm.get_tree().create_timer(3.0).timeout.connect(gm.reset_hud_info)


func on_consumed(slot: int) -> void:
	player_powerups.erase(slot)
	# Reset ball armed state
	if slot >= 0 and slot < gm.balls.size() and gm.balls[slot] != null:
		var ball: PoolBall = gm.balls[slot]
		ball.held_powerup = Powerup.Type.NONE
		ball.powerup_armed = false
		ball.armed_timer = 0.0
	update_hud()
	gm.game_hud.update_scoreboard()


func _on_armed(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	ball.powerup_armed = true
	ball.armed_timer = GameConfig.powerup_armed_timeout
	if slot in player_powerups:
		player_powerups[slot]["armed"] = true
	update_hud()


func _spawn_arm_visual(pos: Vector3, color: Color, use_sphere: bool, duration: float, end_scale: float) -> void:
	if OS.get_name() == "Web":
		return  # Skip MeshInstance3D + material alloc on web — causes GL GC pressure
	var node := MeshInstance3D.new()
	if use_sphere:
		var m := SphereMesh.new()
		m.radius = 0.5
		m.height = 1.0
		node.mesh = m
	else:
		var m := TorusMesh.new()
		m.inner_radius = 0.1
		m.outer_radius = 0.4
		node.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	node.position = pos
	gm.add_child(node)
	var tween := gm.create_tween().set_parallel(true)
	tween.tween_property(node, "scale", Vector3.ONE * end_scale, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(mat, "albedo_color:a", 0.0, duration).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(node.queue_free)


func on_powerup_armed(slot: int, type: int) -> void:
	_on_armed(slot)
	_log("VISUAL_POWERUP_ARMED ball=%d type=%s" % [slot, Powerup.get_powerup_name(type)])
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	Powerup.get_handler(type).on_armed_visual(ball, type, self)


func create_shockwave_effect(pos_x: float, pos_z: float) -> void:
	var pos := Vector3(pos_x, 0.5, pos_z)

	# Central starburst — pooled, always shown
	ComicBurst.fire(pos, Color(1.0, 0.4, 0.0), 1.0)

	# Ring + flash: skip on web to avoid MeshInstance3D/material GL allocs that trigger JS GC
	if OS.get_name() == "Web":
		return

	# Expanding shockwave ring
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.1
	torus.outer_radius = 0.3
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(1.0, 0.6, 0.1, 0.9)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(1.0, 0.5, 0.0)
	ring_mat.emission_energy_multiplier = 4.0
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = ring_mat
	ring.position = Vector3(pos_x, 0.15, pos_z)
	ring.rotation_degrees.x = 90.0
	gm.add_child(ring)

	var ring_tween := gm.create_tween()
	ring_tween.set_parallel(true)
	ring_tween.tween_property(ring, "scale", Vector3(25.0, 25.0, 25.0), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	ring_tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.5).set_ease(Tween.EASE_IN)
	ring_tween.chain().tween_callback(ring.queue_free)

	# Bright flash sphere
	var flash := MeshInstance3D.new()
	var flash_mesh := SphereMesh.new()
	flash_mesh.radius = 0.5
	flash_mesh.height = 1.0
	flash.mesh = flash_mesh
	var flash_mat := StandardMaterial3D.new()
	flash_mat.albedo_color = Color(1.0, 0.9, 0.6, 0.8)
	flash_mat.emission_enabled = true
	flash_mat.emission = Color(1.0, 0.8, 0.3)
	flash_mat.emission_energy_multiplier = 6.0
	flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.material_override = flash_mat
	flash.position = pos
	gm.add_child(flash)

	var flash_tween := gm.create_tween()
	flash_tween.set_parallel(true)
	flash_tween.tween_property(flash, "scale", Vector3(4.0, 4.0, 4.0), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	flash_tween.tween_property(flash_mat, "albedo_color:a", 0.0, 0.3).set_ease(Tween.EASE_IN)
	flash_tween.chain().tween_callback(flash.queue_free)



func on_gravity_well_placed(placer_slot: int, pos_x: float, pos_z: float, _duration: float = 0.0) -> void:
	_remove_gravity_well_visual(placer_slot)

	var root := Node3D.new()
	root.position = Vector3(pos_x, 0.08, pos_z)
	root.name = "GravityWell_%d" % placer_slot

	var color := Powerup.get_color(Powerup.Type.GRAVITY_WELL)
	var radius: float = GameConfig.gravity_well_radius

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.12
	torus.outer_radius = radius
	ring.mesh = torus
	ring.rotation_degrees.x = 90.0
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(color.r, color.g, color.b, 0.4)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.emission_enabled = true
	ring_mat.emission = color
	ring_mat.emission_energy_multiplier = 2.2
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = ring_mat
	root.add_child(ring)

	var core := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	core.mesh = sphere
	core.position = Vector3(0.0, 0.22, 0.0)
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(color.r, color.g, color.b, 0.7)
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.emission_enabled = true
	core_mat.emission = color
	core_mat.emission_energy_multiplier = 3.0
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core.material_override = core_mat
	root.add_child(core)

	gm.add_child(root)
	_gravity_well_visual_nodes[placer_slot] = root
	ComicBurst.fire(root.position + Vector3(0.0, 0.25, 0.0), color, 0.55)


func on_gravity_well_expired(placer_slot: int) -> void:
	_remove_gravity_well_visual(placer_slot)


func _remove_gravity_well_visual(slot: int) -> void:
	if slot not in _gravity_well_visual_nodes:
		return
	var node: Node3D = _gravity_well_visual_nodes[slot]
	if node != null and is_instance_valid(node):
		node.queue_free()
	_gravity_well_visual_nodes.erase(slot)


func on_portal_placed(placer_slot: int, portal_idx: int, pos_x: float, pos_z: float, yaw: float = 0.0) -> void:
	# portal_idx: 0 = blue, 1 = orange
	var pos := Vector3(pos_x, 0.08, pos_z)
	var color := Color(0.2, 0.6, 1.0) if portal_idx == 0 else Color(1.0, 0.5, 0.05)
	var det_r: float = GameConfig.portal_trap_detection_radius

	var ring_node := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = det_r - 0.12
	torus.outer_radius = det_r
	ring_node.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_node.material_override = mat
	ring_node.position = pos
	ring_node.rotation_degrees.x = 90.0
	gm.add_child(ring_node)
	ComicBurst.fire(pos + Vector3(0, 0.3, 0), color, 0.5)

	if placer_slot not in _portal_visual_nodes:
		_portal_visual_nodes[placer_slot] = {"blue": null, "orange": null, "blue_arrow": null, "orange_arrow": null}
	var key := "blue" if portal_idx == 0 else "orange"
	var arrow_key := "blue_arrow" if portal_idx == 0 else "orange_arrow"
	var old: Node3D = _portal_visual_nodes[placer_slot][key]
	if old != null and is_instance_valid(old):
		old.queue_free()
	_portal_visual_nodes[placer_slot][key] = ring_node
	var old_arrow: Node3D = _portal_visual_nodes[placer_slot][arrow_key]
	if old_arrow != null and is_instance_valid(old_arrow):
		old_arrow.queue_free()
	var arrow_node := _build_portal_arrow_node(color, 0.95)
	arrow_node.position = Vector3(pos.x, 0.0, pos.z)
	arrow_node.rotation.y = yaw
	gm.add_child(arrow_node)
	_portal_visual_nodes[placer_slot][arrow_key] = arrow_node

	# Pulse animation (scale breathe). Keep static on web to avoid tween overhead.
	if OS.get_name() != "Web":
		var tween := gm.create_tween().set_loops()
		tween.tween_property(ring_node, "scale", Vector3(1.12, 1.12, 1.12), 0.6).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(ring_node, "scale", Vector3(1.0, 1.0, 1.0), 0.6).set_ease(Tween.EASE_IN_OUT)


func on_portals_expired(placer_slot: int) -> void:
	_remove_portal_visual_nodes(placer_slot)
	_portal_visual_nodes.erase(placer_slot)
	# Also clear local ring if this was our portal
	if placer_slot == NetworkManager.my_slot and _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
		_portal_ring = null


func _remove_portal_visual_nodes(slot: int) -> void:
	if slot not in _portal_visual_nodes:
		return
	for key in ["blue", "orange", "blue_arrow", "orange_arrow"]:
		var node: Node3D = _portal_visual_nodes[slot][key]
		if node != null and is_instance_valid(node):
			node.queue_free()


func on_portal_transit(ball_slot: int, from_x: float, from_z: float, to_x: float, to_z: float) -> void:
	var from_color := Color(0.2, 0.6, 1.0)
	var to_color := Color(1.0, 0.5, 0.05)
	ComicBurst.fire(Vector3(from_x, 0.5, from_z), from_color, 0.6)
	ComicBurst.fire(Vector3(to_x, 0.5, to_z), to_color, 0.6)
	# Flash the transiting ball
	if ball_slot >= 0 and ball_slot < gm.balls.size() and gm.balls[ball_slot] != null:
		var ball: PoolBall = gm.balls[ball_slot]
		if ball.ball_mesh:
			var bmat := ball.ball_mesh.get_surface_override_material(0)
			if bmat is StandardMaterial3D:
				var orig: Color = ball.ball_color
				bmat.emission = to_color
				bmat.emission_energy_multiplier = 6.0
				var btween := gm.create_tween()
				btween.tween_interval(0.2)
				btween.tween_callback(func() -> void:
					bmat.emission = orig
					bmat.emission_energy_multiplier = 0.0
				)


# --- Portal placement radius ring (client, follows local player's ball) ---

func client_update(delta: float, cursor_world_pos: Vector3 = Vector3.ZERO) -> void:
	for slot in _gravity_well_visual_nodes:
		var gw: Node3D = _gravity_well_visual_nodes[slot]
		if gw != null and is_instance_valid(gw):
			gw.rotation.y += delta * 1.6
			gw.position.y = 0.08 + sin(Time.get_ticks_msec() / 180.0 + float(slot)) * 0.015
	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= gm.balls.size():
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false
		return
	var my_ball: PoolBall = gm.balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		if _portal_ring != null and is_instance_valid(_portal_ring):
			_portal_ring.queue_free()
		_portal_ring = null
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false
		_clear_swap_rings()
		return

	# Legacy placement radius ring remains removed by design.
	if _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
	_portal_ring = null

	# Portal placement preview: ghost ring + facing arrow at cursor.
	var has_portal := my_ball.held_powerup == Powerup.Type.PORTAL_TRAP
	if has_portal and _is_valid_cursor_pos(cursor_world_pos):
		_ensure_portal_preview_nodes()
		_portal_preview_root.visible = true
		_portal_preview_root.position = Vector3(cursor_world_pos.x, 0.08, cursor_world_pos.z)
		_portal_preview_root.rotation.y = _portal_preview_yaw

		var preview_color := Color(0.2, 0.6, 1.0)  # blue by default
		if my_slot in _portal_visual_nodes:
			var own_visuals: Dictionary = _portal_visual_nodes[my_slot]
			if own_visuals.get("blue", null) != null and own_visuals.get("orange", null) == null:
				preview_color = Color(1.0, 0.5, 0.05)  # orange for second portal

		if _portal_preview_ring != null and is_instance_valid(_portal_preview_ring):
			var mat: StandardMaterial3D = _portal_preview_ring.material_override
			mat.albedo_color = Color(preview_color.r, preview_color.g, preview_color.b, 0.35)
			mat.emission = preview_color
			mat.emission_energy_multiplier = 1.8
		if _portal_preview_arrow != null and is_instance_valid(_portal_preview_arrow):
			for n in _portal_preview_arrow.get_children():
				if n is MeshInstance3D and (n as MeshInstance3D).material_override is StandardMaterial3D:
					var amat := (n as MeshInstance3D).material_override as StandardMaterial3D
					amat.albedo_color = Color(preview_color.r, preview_color.g, preview_color.b, 0.9)
					amat.emission = preview_color

		if not _portal_hint_shown and gm.game_hud != null:
			_portal_hint_shown = true
			gm.game_hud.set_info_text("Portal: scroll or Q/E to rotate facing, SPACE to place", preview_color)
			gm.get_tree().create_timer(2.5).timeout.connect(func() -> void:
				if is_instance_valid(gm):
					gm.reset_hud_info()
			)
	else:
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false

	# --- Swap cursor highlight rings ---
	if my_ball.held_powerup == Powerup.Type.SWAP:
		_update_swap_rings(my_ball, cursor_world_pos)
	else:
		_clear_swap_rings()


func _clear_swap_rings() -> void:
	for slot in _swap_highlight_rings:
		var ring = _swap_highlight_rings[slot]
		if ring != null and is_instance_valid(ring):
			ring.queue_free()
	_swap_highlight_rings.clear()
	if _swap_target_ring != null and is_instance_valid(_swap_target_ring):
		_swap_target_ring.queue_free()
	_swap_target_ring = null


func _update_swap_rings(my_ball: PoolBall, cursor_world_pos: Vector3) -> void:
	var swap_color := Powerup.get_color(Powerup.Type.SWAP)
	var snap_sq: float = GameConfig.swap_cursor_snap_radius * GameConfig.swap_cursor_snap_radius

	# Find targeted enemy (closest to cursor within snap radius)
	var target_slot := -1
	var target_dist_sq := INF
	for b in gm.balls:
		if b == null or not b.is_alive or b == my_ball:
			continue
		var dx: float = b.global_position.x - cursor_world_pos.x
		var dz: float = b.global_position.z - cursor_world_pos.z
		var dist_sq := dx * dx + dz * dz
		if dist_sq < snap_sq and dist_sq < target_dist_sq:
			target_dist_sq = dist_sq
			target_slot = b.slot

	# Remove rings for balls that are no longer alive
	var to_remove: Array = []
	for slot in _swap_highlight_rings:
		if slot >= gm.balls.size() or gm.balls[slot] == null or not gm.balls[slot].is_alive:
			var ring = _swap_highlight_rings[slot]
			if ring != null and is_instance_valid(ring):
				ring.queue_free()
			to_remove.append(slot)
	for slot in to_remove:
		_swap_highlight_rings.erase(slot)

	# Create/update faint rings for all alive enemies
	for b in gm.balls:
		if b == null or not b.is_alive or b == my_ball:
			continue
		if b.slot not in _swap_highlight_rings:
			var ring := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = 0.32
			torus.outer_radius = 0.45
			ring.mesh = torus
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(swap_color.r, swap_color.g, swap_color.b, 0.28)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.emission_enabled = true
			mat.emission = swap_color
			mat.emission_energy_multiplier = 1.0
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			ring.material_override = mat
			ring.rotation_degrees.x = 90.0
			gm.add_child(ring)
			_swap_highlight_rings[b.slot] = ring
		var faint_ring: MeshInstance3D = _swap_highlight_rings[b.slot]
		if is_instance_valid(faint_ring):
			faint_ring.position = Vector3(b.global_position.x, 0.06, b.global_position.z)

	# Create/update bright target ring
	if target_slot >= 0 and target_slot < gm.balls.size() and gm.balls[target_slot] != null:
		var target_ball: PoolBall = gm.balls[target_slot]
		if _swap_target_ring == null or not is_instance_valid(_swap_target_ring):
			_swap_target_ring = MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = 0.32
			torus.outer_radius = 0.45
			_swap_target_ring.mesh = torus
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(swap_color.r, swap_color.g, swap_color.b, 0.95)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.emission_enabled = true
			mat.emission = swap_color
			mat.emission_energy_multiplier = 4.5
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_swap_target_ring.material_override = mat
			_swap_target_ring.rotation_degrees.x = 90.0
			gm.add_child(_swap_target_ring)
		_swap_target_ring.visible = true
		_swap_target_ring.position = Vector3(target_ball.global_position.x, 0.07, target_ball.global_position.z)
	else:
		if _swap_target_ring != null and is_instance_valid(_swap_target_ring):
			_swap_target_ring.visible = false


func create_swap_effect(slot_a: int, old_ax: float, old_az: float, slot_b: int, old_bx: float, old_bz: float) -> void:
	var swap_color := Powerup.get_color(Powerup.Type.SWAP)
	# Departure bursts at both old positions
	ComicBurst.fire(Vector3(old_ax, 0.5, old_az), swap_color, 0.7)
	ComicBurst.fire(Vector3(old_bx, 0.5, old_bz), swap_color, 0.7)
	# Flash both swapped balls
	for s in [slot_a, slot_b]:
		if s < 0 or s >= gm.balls.size() or gm.balls[s] == null:
			continue
		var ball: PoolBall = gm.balls[s]
		if ball.ball_mesh:
			var bmat := ball.ball_mesh.get_surface_override_material(0)
			if bmat is StandardMaterial3D:
				var orig: Color = ball.ball_color
				bmat.emission = swap_color
				bmat.emission_energy_multiplier = 6.0
				var btween := gm.create_tween()
				btween.tween_interval(0.25)
				btween.tween_callback(func() -> void:
					bmat.emission = orig
					bmat.emission_energy_multiplier = 0.0
				)
