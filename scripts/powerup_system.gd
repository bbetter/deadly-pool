extends RefCounted
class_name PowerupSystem
## Manages all powerup game logic: spawning, pickups, activation, effects.
## Visual rendering is handled by PowerupVisuals (ps.visuals).
## Instantiated by GameManager; RPCs route through NetworkManager.

var gm: Node  # GameManager reference
var visuals: PowerupVisuals

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
var gravity_wells: Dictionary = {}  # slot -> { "pos": Vector3, "timer": float }


func _init(game_manager: Node) -> void:
	gm = game_manager
	visuals = PowerupVisuals.new(game_manager, self)


func reset() -> void:
	for item in items:
		if item is Node and is_instance_valid(item):
			item.queue_free()
	items.clear()
	player_powerups.clear()
	portal_states.clear()
	gravity_wells.clear()
	visuals.reset()
	spawn_timer = 10.0


func _log(msg: String) -> void:
	gm._log(msg)


# --- Visual delegation (keep same API for game_manager.gd callers) ---

func rotate_portal_preview(step_deg: float) -> void: visuals.rotate_portal_preview(step_deg)
func get_portal_preview_yaw() -> float: return visuals.get_portal_preview_yaw()
func create_hud(parent: CanvasLayer) -> void: visuals.create_hud(parent)
func update_hud() -> void: visuals.update_hud()
func hide_hud() -> void: visuals.hide_hud()
func client_update(delta: float, cursor_world_pos: Vector3 = Vector3.ZERO) -> void: visuals.client_update(delta, cursor_world_pos)

# Called by powerup.gd handlers via ps._spawn_arm_visual(...)
func _spawn_arm_visual(pos: Vector3, color: Color, use_sphere: bool, duration: float, end_scale: float) -> void:
	visuals.spawn_arm_visual(pos, color, use_sphere, duration, end_scale)


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
		_broadcast(
			func(): gm.client_receive_portals_expired(slot),
			func(pid): NetworkManager._rpc_game_portals_expired.rpc_id(pid, slot))


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
		_broadcast(
			func(): gm.client_receive_gravity_well_expired(slot),
			func(pid): NetworkManager._rpc_game_gravity_well_expired.rpc_id(pid, slot))


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
	_broadcast(
		func(): gm.client_receive_portal_transit(ball.slot, from_pos.x, from_pos.z, to_pos.x, to_pos.z),
		func(pid): NetworkManager._rpc_game_portal_transit.rpc_id(pid, ball.slot, from_pos.x, from_pos.z, to_pos.x, to_pos.z))


# --- RPC dispatch helpers (single-player vs multiplayer) ---

## Generic broadcast: calls sp_call() in single-player, mp_call(peer_id) for each peer in MP.
## Both callables are invoked synchronously — no deferred-capture risk.
func _broadcast(sp_call: Callable, mp_call: Callable) -> void:
	if NetworkManager.is_single_player:
		sp_call.call()
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			mp_call.call(pid)


func _rpc_consumed(slot: int) -> void:
	_broadcast(
		func(): gm.client_receive_powerup_consumed(slot),
		func(pid): NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot))


# --- Spawning ---

func _find_valid_spawn_pos() -> Vector3:
	for _attempt in 20:
		var tx := randf_range(-11.0, 11.0)
		var tz := randf_range(-5.0, 5.0)
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
				var bdx: float = tx - ball.position.x
				var bdz: float = tz - ball.position.z
				if bdx * bdx + bdz * bdz < 2.25:  # 1.5^2
					safe = false
					break
		if not safe:
			continue
		return Vector3(tx, 0.0, tz)
	return Vector3.INF  # all 20 attempts failed


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

	var pos := _find_valid_spawn_pos()
	if pos == Vector3.INF:
		_log("POWERUP_SPAWN_FAILED type=%s table_count=%d/%d" % [
			Powerup.get_powerup_name(type), items.size(), GameConfig.powerup_max_on_table])
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
	_log("POWERUP_SPAWN id=%d type=%s pos=(%.1f,%.1f) table_count=%d/%d" % [
		id, Powerup.get_powerup_name(type), pos.x, pos.z,
		items.size(), GameConfig.powerup_max_on_table])


# --- Pickup detection (server-side) ---

func server_check_pickups() -> void:
	var to_remove: Array[int] = []
	var sp_pickups: Array = []  # [[pu_id, ball_slot, pu_type]] deferred for single-player

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
					# Defer notification until after the loop — calling client_receive_powerup_picked_up
					# here would invoke on_picked_up → items.remove_at mid-iteration → out-of-bounds.
					sp_pickups.append([pu_id, ball.slot, pu_type])
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

	# Process single-player pickups after the loop — safe to modify items now
	for p in sp_pickups:
		gm.client_receive_powerup_picked_up(p[0], p[1], p[2])


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

	_broadcast(
		func():
			gm.client_receive_shockwave_effect(center.x, center.z)
			gm.client_receive_powerup_consumed(ball.slot),
		func(pid):
			NetworkManager._rpc_game_shockwave_effect.rpc_id(pid, center.x, center.z)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, ball.slot))

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

	_broadcast(
		func():
			gm.client_receive_gravity_well_placed(slot, cursor_pos.x, cursor_pos.z, GameConfig.gravity_well_duration)
			gm.client_receive_powerup_consumed(slot),
		func(pid):
			NetworkManager._rpc_game_gravity_well_placed.rpc_id(pid, slot, cursor_pos.x, cursor_pos.z, GameConfig.gravity_well_duration)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot))

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
		_broadcast(
			func(): gm.client_receive_portal_placed(slot, 0, cursor_pos.x, cursor_pos.z, portal_yaw),
			func(pid): NetworkManager._rpc_game_portal_placed.rpc_id(pid, slot, 0, cursor_pos.x, cursor_pos.z, portal_yaw))
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
		_broadcast(
			func():
				gm.client_receive_portal_placed(slot, 1, cursor_pos.x, cursor_pos.z, portal_yaw)
				gm.client_receive_powerup_consumed(slot),
			func(pid):
				NetworkManager._rpc_game_portal_placed.rpc_id(pid, slot, 1, cursor_pos.x, cursor_pos.z, portal_yaw)
				NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot))


func cancel_portal(slot: int) -> void:
	if slot in portal_states:
		portal_states.erase(slot)
	_log("PORTAL_CANCELLED ball=%d" % slot)
	_broadcast(
		func(): gm.client_receive_portals_expired(slot),
		func(pid): NetworkManager._rpc_game_portals_expired.rpc_id(pid, slot))


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
	_broadcast(
		func():
			gm.client_receive_swap_effect(ball.slot, old_a.x, old_a.z, target.slot, old_b.x, old_b.z)
			gm.client_receive_powerup_consumed(ball.slot),
		func(pid):
			NetworkManager._rpc_game_swap_effect.rpc_id(pid, ball.slot, old_a.x, old_a.z, target.slot, old_b.x, old_b.z)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, ball.slot))


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
	_broadcast(
		func(): gm.client_receive_powerup_picked_up(-1, killer_slot, type),
		func(pid): NetworkManager._rpc_game_powerup_picked_up.rpc_id(pid, -1, killer_slot, type))



# --- RPC handler bodies (called from GameManager's client_receive_* methods) ---

func on_spawned(id: int, type: int, pos_x: float, pos_z: float) -> void:
	var item := Powerup.PowerupItem.create(id, type, Vector3(pos_x, 0.0, pos_z))
	gm.add_child(item)
	items.append(item)


func on_picked_up(powerup_id: int, slot: int, type: int) -> void:
	_log("POWERUP_RPC_PICKUP id=%d slot=%d type=%d" % [powerup_id, slot, type])
	for i in items.size():
		var item = items[i]
		if item is Powerup.PowerupItem and item.powerup_id == powerup_id:
			if not gm._is_headless:
				ComicBurst.fire(item.position + Vector3(0, 0.2, 0), Powerup.get_color(type), 0.5)
			item.queue_free()
			items.remove_at(i)
			break
	if slot < gm.balls.size() and gm.balls[slot] != null:
		gm.balls[slot].held_powerup = type
		_log("POWERUP_BALL_UPDATED ball=%d held_powerup=%d" % [slot, type])
	else:
		_log("POWERUP_BALL_FAIL slot=%d out_of_range_or_null balls_size=%d" % [slot, gm.balls.size()])
	player_powerups[slot] = {"type": type, "armed": false}
	_log("POWERUP_PICKUP ball=%d type=%s armed=false" % [slot, Powerup.get_powerup_name(type)])
	visuals.update_hud()
	gm.game_hud.update_scoreboard()
	if slot == NetworkManager.my_slot and gm.game_hud:
		var color := Powerup.get_color(type)
		gm.game_hud.set_info_text("%s (SPACE) - %s" % [Powerup.get_powerup_name(type), Powerup.get_desc(type)], color)
		gm.get_tree().create_timer(3.0).timeout.connect(gm.reset_hud_info)


func on_consumed(slot: int) -> void:
	player_powerups.erase(slot)
	if slot >= 0 and slot < gm.balls.size() and gm.balls[slot] != null:
		var ball: PoolBall = gm.balls[slot]
		ball.held_powerup = Powerup.Type.NONE
		ball.powerup_armed = false
		ball.armed_timer = 0.0
	visuals.update_hud()
	gm.game_hud.update_scoreboard()


func _on_armed(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	ball.powerup_armed = true
	ball.armed_timer = GameConfig.powerup_armed_timeout
	if slot in player_powerups:
		player_powerups[slot]["armed"] = true
	visuals.update_hud()


func on_powerup_armed(slot: int, type: int) -> void:
	_on_armed(slot)
	_log("VISUAL_POWERUP_ARMED ball=%d type=%s" % [slot, Powerup.get_powerup_name(type)])
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	Powerup.get_handler(type).on_armed_visual(ball, type, self)


func create_shockwave_effect(pos_x: float, pos_z: float) -> void:
	visuals.create_shockwave_effect(pos_x, pos_z)


func on_gravity_well_placed(placer_slot: int, pos_x: float, pos_z: float, _duration: float = 0.0) -> void:
	visuals.on_gravity_well_placed(placer_slot, pos_x, pos_z, _duration)


func on_gravity_well_expired(placer_slot: int) -> void:
	visuals.on_gravity_well_expired(placer_slot)


func on_portal_placed(placer_slot: int, portal_idx: int, pos_x: float, pos_z: float, yaw: float = 0.0) -> void:
	visuals.on_portal_placed(placer_slot, portal_idx, pos_x, pos_z, yaw)


func on_portals_expired(placer_slot: int) -> void:
	visuals.on_portals_expired(placer_slot)


func on_portal_transit(ball_slot: int, from_x: float, from_z: float, to_x: float, to_z: float) -> void:
	visuals.on_portal_transit(ball_slot, from_x, from_z, to_x, to_z)


func create_swap_effect(slot_a: int, old_ax: float, old_az: float, slot_b: int, old_bx: float, old_bz: float) -> void:
	visuals.create_swap_effect(slot_a, old_ax, old_az, slot_b, old_bx, old_bz)
