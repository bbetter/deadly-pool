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
	spawn_timer = 10.0
	update_hud()


func _log(msg: String) -> void:
	gm._log(msg)


# --- HUD ---

func create_hud(parent: CanvasLayer) -> void:
	hud_panel = PanelContainer.new()
	hud_panel.anchor_left = 1.0
	hud_panel.anchor_top = 0.0
	hud_panel.anchor_right = 1.0
	hud_panel.anchor_bottom = 0.0
	hud_panel.offset_left = -220
	hud_panel.offset_top = 20
	hud_panel.offset_right = -20
	hud_panel.offset_bottom = 100
	hud_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.08, 0.02, 0.7)
	style.border_color = Color(1, 0.85, 0.2, 0.5)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	hud_panel.add_theme_stylebox_override("panel", style)
	hud_panel.visible = false

	hud_label = RichTextLabel.new()
	hud_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_label.bbcode_enabled = true
	hud_label.fit_content = true
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
			var status := "ARMED" if armed else "[SPACE]"
			hud_label.text = "[color=#%s]%s %s %s[/color]" % [
				color.to_html(false), Powerup.get_symbol(ptype), Powerup.get_name(ptype), status]
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

	# Restore heavy ball mass when ball stops
	for ball in gm.balls:
		if ball != null and ball.is_alive and not ball.is_pocketing:
			if ball.mass > GameConfig.ball_mass + 0.05 and not ball.is_moving() and ball.shield_timer <= 0.0:
				ball.mass = GameConfig.ball_mass

	# Shield timer countdown
	for ball in gm.balls:
		if ball != null and ball.is_alive and ball.shield_active:
			ball.shield_timer -= delta
			if ball.shield_timer <= 0.0:
				ball.shield_active = false
				ball.mass = GameConfig.ball_mass
				ball.held_powerup = Powerup.Type.NONE
				_log("SHIELD_EXPIRED ball=%d" % ball.slot)
				_rpc_consumed(ball.slot)

	# Armed powerup timeout — auto-trigger or consume after timeout
	for ball in gm.balls:
		if ball == null or not ball.is_alive or ball.armed_timer <= 0.0:
			continue
		ball.armed_timer -= delta
		if ball.armed_timer <= 0.0:
			ball.armed_timer = 0.0
			if ball.held_powerup == Powerup.Type.BOMB and ball.bomb_armed:
				_log("POWERUP_TIMEOUT ball=%d type=BOMB auto_trigger" % ball.slot)
				trigger_bomb(ball)
			elif ball.held_powerup == Powerup.Type.SHIELD and ball.shield_active:
				ball.shield_active = false
				ball.mass = GameConfig.ball_mass
				ball.held_powerup = Powerup.Type.NONE
				_log("POWERUP_TIMEOUT ball=%d type=SHIELD expired" % ball.slot)
				_rpc_consumed(ball.slot)
			elif ball.held_powerup == Powerup.Type.SPEED_BOOST and ball.speed_boost_armed:
				ball.held_powerup = Powerup.Type.NONE
				ball.speed_boost_armed = false
				_log("POWERUP_TIMEOUT ball=%d type=SPEED_BOOST expired" % ball.slot)
				_rpc_consumed(ball.slot)


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
	var type := Powerup.random_type()
	var pos := Vector3.ZERO

	var found := false
	var attempts := 0
	for _attempt in 20:
		attempts += 1
		var tx := randf_range(-7.0, 7.0)
		var tz := randf_range(-7.0, 7.0)
		var candidate := Vector3(tx, 0.0, tz)
		var safe := true

		for pocket in gm.POCKET_POSITIONS:
			if Vector2(tx, tz).distance_to(Vector2(pocket.x, pocket.z)) < 2.0:
				safe = false
				break
		if not safe:
			continue

		for ball in gm.balls:
			if ball != null and ball.is_alive:
				# Use position (local to room) for server-side checks
				if Vector2(tx, tz).distance_to(Vector2(ball.position.x, ball.position.z)) < 1.5:
					safe = false
					break
		if not safe:
			continue

		pos = candidate
		found = true
		break

	if not found:
		_log("POWERUP_SPAWN_FAILED type=%s attempts=%d table_count=%d/%d" % [
			Powerup.get_name(type), attempts, items.size(), GameConfig.powerup_max_on_table])
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
		id, Powerup.get_name(type), pos.x, pos.z,
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
					ball.slot, pu_type, Powerup.get_name(pu_type)])
				if NetworkManager.is_single_player:
					gm.client_receive_powerup_picked_up(pu_id, ball.slot, pu_type)
				else:
					to_remove.append(i)
					for pid in NetworkManager.get_room_peers(gm._room_code):
						NetworkManager._rpc_game_powerup_picked_up.rpc_id(pid, pu_id, ball.slot, pu_type)
				_log("POWERUP_PICKUP ball=%d type=%s ball_spd=%.2f pos=(%.1f,%.1f) dist=%.2f" % [
					ball.slot, Powerup.get_name(pu_type), ball_spd,
					ball.position.x, ball.position.z, closest_dist])
				break

	to_remove.reverse()
	for idx in to_remove:
		var item = items[idx]
		if item is Node:
			item.queue_free()
		items.remove_at(idx)


# --- Client activation (Space key) ---

func try_activate(my_slot: int, my_ball: PoolBall) -> void:
	_log("POWERUP_ACTIVATE_REQUEST ball=%d held_powerup=%d bomb_armed=%s shield_active=%s" % [
		my_slot, my_ball.held_powerup, my_ball.bomb_armed, my_ball.shield_active])

	if my_ball.held_powerup == Powerup.Type.SPEED_BOOST and not my_ball.speed_boost_armed:
		if NetworkManager.is_single_player:
			my_ball.speed_boost_armed = true
			my_ball.armed_timer = GameConfig.powerup_armed_timeout
			my_ball.update_powerup_icon()
			if my_slot in player_powerups:
				player_powerups[my_slot]["armed"] = true
			update_hud()
			_log("POWERUP_ARMED ball=%d type=SPEED_BOOST timeout=%.1fs (single_player)" % [my_slot, GameConfig.powerup_armed_timeout])
		else:
			_log("POWERUP_ARMED ball=%d type=SPEED_BOOST sending_rpc_to_server" % my_slot)
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "speed_boost")
	elif my_ball.held_powerup == Powerup.Type.BOMB and not my_ball.bomb_armed:
		if NetworkManager.is_single_player:
			my_ball.bomb_armed = true
			my_ball.armed_timer = GameConfig.powerup_armed_timeout
			my_ball.update_powerup_icon()
			if my_slot in player_powerups:
				player_powerups[my_slot]["armed"] = true
			update_hud()
			_log("POWERUP_ARMED ball=%d type=BOMB timeout=%.1fs (single_player)" % [my_slot, GameConfig.powerup_armed_timeout])
		else:
			_log("POWERUP_ARMED ball=%d type=BOMB sending_rpc_to_server" % my_slot)
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "bomb")
	elif my_ball.held_powerup == Powerup.Type.SHIELD and not my_ball.shield_active:
		if NetworkManager.is_single_player:
			my_ball.shield_active = true
			my_ball.shield_timer = GameConfig.shield_duration
			my_ball.mass = GameConfig.shield_mass
			my_ball.armed_timer = GameConfig.powerup_armed_timeout
			my_ball.update_powerup_icon()
			if my_slot in player_powerups:
				player_powerups[my_slot]["armed"] = true
			update_hud()
			_log("POWERUP_ARMED ball=%d type=SHIELD timeout=%.1fs (single_player)" % [my_slot, GameConfig.powerup_armed_timeout])
			on_shield_activate(my_slot)
		else:
			_log("POWERUP_ARMED ball=%d type=SHIELD sending_rpc_to_server" % my_slot)
			NetworkManager._rpc_game_activate_powerup.rpc_id(1, my_slot, "shield")
	else:
		_log("POWERUP_ACTIVATE_FAIL ball=%d no_valid_powerup held=%d" % [my_slot, my_ball.held_powerup])


# --- Server activation (RPC handler body) ---

func server_activate(slot: int, powerup_type: String, ball: PoolBall) -> void:
	if powerup_type == "speed_boost" and ball.held_powerup == Powerup.Type.SPEED_BOOST and not ball.speed_boost_armed:
		ball.speed_boost_armed = true
		ball.armed_timer = GameConfig.powerup_armed_timeout
		_log("POWERUP_ARMED ball=%d type=SPEED_BOOST timeout=%.1fs (server)" % [slot, GameConfig.powerup_armed_timeout])
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_speed_boost_armed.rpc_id(pid, slot)
	elif powerup_type == "bomb" and ball.held_powerup == Powerup.Type.BOMB and not ball.bomb_armed:
		ball.bomb_armed = true
		ball.armed_timer = GameConfig.powerup_armed_timeout
		_log("POWERUP_ARMED ball=%d type=BOMB timeout=%.1fs (server)" % [slot, GameConfig.powerup_armed_timeout])
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_bomb_armed.rpc_id(pid, slot)
	elif powerup_type == "shield" and ball.held_powerup == Powerup.Type.SHIELD and not ball.shield_active:
		ball.shield_active = true
		ball.shield_timer = GameConfig.shield_duration
		ball.mass = GameConfig.shield_mass
		ball.armed_timer = GameConfig.powerup_armed_timeout
		_log("POWERUP_ARMED ball=%d type=SHIELD timeout=%.1fs (server)" % [slot, GameConfig.powerup_armed_timeout])
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_shield_activate.rpc_id(pid, slot)
	else:
		_log("POWERUP_RPC_FAIL ball=%d invalid_state held=%d bomb_armed=%s shield_active=%s" % [
			slot, ball.held_powerup, ball.bomb_armed, ball.shield_active])


# --- Powerup effects (server-side) ---

func trigger_bomb(ball: PoolBall) -> void:
	_log("BOMB_TRIGGER_START ball=%d pos=(%.1f,%.1f)" % [ball.slot, ball.position.x, ball.position.z])
	ball.held_powerup = Powerup.Type.NONE
	ball.bomb_armed = false
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


func trigger_shield(shield_ball: PoolBall, attacker: PoolBall) -> void:
	_log("SHIELD_TRIGGER_START shield_ball=%d attacker=%d" % [shield_ball.slot, attacker.slot])
	shield_ball.held_powerup = Powerup.Type.NONE
	shield_ball.shield_active = false
	shield_ball.armed_timer = 0.0
	shield_ball.mass = GameConfig.ball_mass

	var push_dir := (attacker.position - shield_ball.position).normalized()
	attacker.apply_central_impulse(push_dir * GameConfig.shield_knockback)

	_log("SHIELD_BLOCK shield_ball=%d attacker=%d knockback=%.1f" % [
		shield_ball.slot, attacker.slot, GameConfig.shield_knockback])

	if NetworkManager.is_single_player:
		gm.client_receive_shield_block(shield_ball.position.x, shield_ball.position.z)
		gm.client_receive_powerup_consumed(shield_ball.slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_shield_block.rpc_id(pid, shield_ball.position.x, shield_ball.position.z)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, shield_ball.slot)

	_log("SHIELD_BLOCK_COMPLETE shield_ball=%d attacker=%d" % [shield_ball.slot, attacker.slot])


# --- Speed boost consumption (called from _execute_launch) ---

func consume_speed_boost(ball: PoolBall, slot: int) -> void:
	ball.held_powerup = Powerup.Type.NONE
	ball.speed_boost_armed = false
	ball.armed_timer = 0.0
	if NetworkManager.is_single_player:
		gm.client_receive_speed_boost(slot)
		gm.client_receive_powerup_consumed(slot)
	else:
		for pid in NetworkManager.get_room_peers(gm._room_code):
			NetworkManager._rpc_game_speed_boost.rpc_id(pid, slot)
			NetworkManager._rpc_game_powerup_consumed.rpc_id(pid, slot)
	_log("POWERUP_CONSUME ball=%d type=SPEED_BOOST visual_consumed" % slot)


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
				var burst := ComicBurst.create(item.position + Vector3(0, 0.2, 0), Powerup.get_color(type), 0.5, false)
				gm.add_child(burst)
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
	_log("POWERUP_PICKUP ball=%d type=%s armed=false" % [slot, Powerup.get_name(type)])

	update_hud()
	gm.game_hud.update_scoreboard()

	# Flash info label
	if slot == NetworkManager.my_slot and gm.game_hud:
		var color := Powerup.get_color(type)
		gm.game_hud.set_info_text("%s (SPACE) - %s" % [Powerup.get_name(type), Powerup.get_desc(type)], color)
		gm.get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if not is_instance_valid(gm):
				return
			if not gm.game_over and not gm.is_dragging:
				gm.game_hud.set_info_default()
		)


func on_consumed(slot: int) -> void:
	player_powerups.erase(slot)
	# Reset ball armed state
	if slot >= 0 and slot < gm.balls.size() and gm.balls[slot] != null:
		var ball: PoolBall = gm.balls[slot]
		ball.held_powerup = Powerup.Type.NONE
		ball.speed_boost_armed = false
		ball.bomb_armed = false
		ball.shield_active = false
		ball.armed_timer = 0.0
	update_hud()
	gm.game_hud.update_scoreboard()


func on_speed_boost_armed(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	ball.speed_boost_armed = true
	ball.update_powerup_icon()
	if slot in player_powerups:
		player_powerups[slot]["armed"] = true
	update_hud()
	_log("VISUAL_SPEED_BOOST_ARMED ball=%d icon=⚡" % slot)


func on_bomb_armed(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	ball.update_powerup_icon()
	if slot in player_powerups:
		player_powerups[slot]["armed"] = true
	update_hud()
	_log("VISUAL_BOMB_ARMED ball=%d icon=💣" % slot)


func on_shield_activate(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	ball.update_powerup_icon()
	if slot in player_powerups:
		player_powerups[slot]["armed"] = true
	update_hud()
	# Blue sphere visual
	var sphere := MeshInstance3D.new()
	var sph_mesh := SphereMesh.new()
	sph_mesh.radius = 0.6
	sph_mesh.height = 1.2
	sphere.mesh = sph_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.5, 1.0, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.5, 1.0, 0.6)
	mat.emission_energy_multiplier = 2.0
	sphere.material_override = mat

	sphere.position = ball.global_position
	gm.add_child(sphere)

	var tween := gm.create_tween()
	tween.tween_property(sphere, "scale", Vector3(1.3, 1.3, 1.3), 0.3)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.3)
	tween.tween_callback(sphere.queue_free)


func create_shockwave_effect(pos_x: float, pos_z: float) -> void:
	var pos := Vector3(pos_x, 0.5, pos_z)

	# Central starburst
	var burst := ComicBurst.create(pos, Color(1.0, 0.4, 0.0), 1.0, true)
	gm.add_child(burst)

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


func create_shield_block_effect(pos_x: float, pos_z: float) -> void:
	var pos := Vector3(pos_x, 0.5, pos_z)
	var burst := ComicBurst.create(pos, Color(0.8, 0.9, 1.0), 0.8, false)
	gm.add_child(burst)


func create_speed_boost_effect(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	var burst := ComicBurst.create(ball.global_position + Vector3(0, 0.3, 0), Color(0.2, 0.9, 0.9), 0.6, false)
	gm.add_child(burst)


func create_anchor_effect(slot: int) -> void:
	if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null:
		return
	var ball: PoolBall = gm.balls[slot]
	if ball.ball_mesh:
		var mat := ball.ball_mesh.get_surface_override_material(0)
		if mat is StandardMaterial3D:
			var original_color: Color = ball.ball_color
			mat.albedo_color = Color(0.7, 0.7, 0.7)
			mat.emission_enabled = true
			mat.emission = Color(0.5, 0.5, 0.6)
			mat.emission_energy_multiplier = 1.5
			var tween := gm.create_tween()
			tween.tween_interval(0.5)
			tween.tween_callback(func() -> void:
				mat.albedo_color = original_color
				mat.emission_enabled = false
			)
