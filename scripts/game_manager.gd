extends Node3D

const BALL_SCENE := preload("res://scenes/pool_ball.tscn")
const PLAYER_COUNT := 4
const FALL_THRESHOLD := -2.0
const INVALID_POS := Vector3(INF, INF, INF)
const SYNC_INTERVAL := 1.0 / 60.0  # 60Hz state broadcast

# Pocket detection (matches arena.gd layout)
const CORNER_POCKET_RADIUS := 1.3
const MID_POCKET_RADIUS := 1.0
var POCKET_POSITIONS: Array[Vector3] = [
	Vector3(-10, 0, -10), Vector3(10, 0, -10),
	Vector3(-10, 0, 10), Vector3(10, 0, 10),
	Vector3(0, 0, -10), Vector3(0, 0, 10),
]

var balls: Array[PoolBall] = []
var alive_players: Array[int] = []
var active_ball: PoolBall = null
var is_dragging: bool = false
var game_over: bool = false

var player_colors: Array[Color] = [
	Color(0.9, 0.15, 0.15),
	Color(0.15, 0.4, 0.9),
	Color(0.9, 0.75, 0.1),
	Color(0.15, 0.8, 0.3),
]
var player_color_names: Array[String] = ["Red", "Blue", "Yellow", "Green"]
var player_names: Array[String] = ["Red", "Blue", "Yellow", "Green"]

var slot_to_peer: Dictionary = {}
var _sync_timer: float = 0.0
var _ready_peers: Array[int] = []
var _spawned: bool = false

# Subsystems
var game_hud: GameHUD

var aim_visuals: AimVisuals

# Client-side collision detection (for visual effects)
var _collision_pairs: Dictionary = {}  # "i_j" -> bool (true = currently overlapping)
var _wall_collision: Dictionary = {}   # slot -> bool (true = currently near wall)
const BALL_RADIUS := 0.35
const BALL_TOUCH_DIST := BALL_RADIUS * 2.0 + 0.05  # Slightly generous for detection
const WALL_HALF := 10.0  # Arena is 20x20, walls at +/-10

# Launch deduplication
var _launch_pending: bool = false  # Client-side: waiting for launch to be processed
var _server_launch_cooldown: Dictionary = {}  # slot -> float (server-side cooldown timer)
# Launch cooldown now read from GameConfig.launch_cooldown

var powerup_system: PowerupSystem
var _server_collision_pairs_phys: Dictionary = {}  # "i_j" -> bool (server-side ball collision tracking)

var _physics_log_timer: float = 0.0
const PHYSICS_LOG_INTERVAL := 0.5  # Log ball states every 0.5s

var _is_server: bool = false
var _is_headless: bool = false
var _bot_ai: Node

# Room awareness
var _room_code: String = ""

# Client-side server timeout detection
var _last_sync_time: float = 0.0
const SERVER_TIMEOUT := 5.0  # Return to menu after 5s of no updates

# Performance tracking (server-side)
var _perf_tick_count: int = 0
var _perf_tick_timer: float = 0.0
var _perf_tick_durations: Array[float] = []
var _room_start_time: int = 0  # For room duration logging

@onready var balls_container: Node3D = $Balls
@onready var hud: CanvasLayer = $HUD
@onready var camera: Camera3D = $CameraRig/Camera3D


func _log(msg: String) -> void:
	NetworkManager.room_log(_room_code, msg)


func _ready() -> void:
	if NetworkManager.is_single_player:
		_is_server = true
		_is_headless = false
		_room_code = "SOLO"
	else:
		_is_server = multiplayer.has_multiplayer_peer() and multiplayer.is_server()
		_is_headless = NetworkManager.is_server_mode
		if _is_headless:
			# Server: get room code from meta set during instantiation
			_room_code = get_meta("room_code", "")
		else:
			# Client: use NetworkManager.current_room as before
			_room_code = NetworkManager.current_room

	powerup_system = PowerupSystem.new(self)
	game_hud = GameHUD.new(self)

	aim_visuals = AimVisuals.new(self)

	if _is_headless:
		# Server has no visual countdown — disable immediately so bot AI can start
		game_hud.countdown_active = false
	else:
		game_hud.create(hud)
		powerup_system.create_hud(hud)
		aim_visuals.create(self)
		game_hud.create_countdown_overlay(hud)

	if NetworkManager.is_single_player:
		_spawned = true
		_room_start_time = Time.get_ticks_msec()
		_spawn_balls_local()
	elif _is_server:
		_room_start_time = Time.get_ticks_msec()
		NetworkManager.player_disconnected.connect(_on_player_disconnected)

		# Check if we have a valid room with players
		var has_valid_room := false
		if _room_code in NetworkManager._rooms:
			var room: Dictionary = NetworkManager._rooms[_room_code]
			has_valid_room = room["players"].size() > 0

		if has_valid_room:
			# Wait for clients to report ready before spawning
			# Safety timeout: spawn after 3s even if not all clients reported
			get_tree().create_timer(3.0).timeout.connect(func() -> void:
				if not is_instance_valid(self) or _spawned:
					return
				var room_player_count := 0
				if _room_code in NetworkManager._rooms:
					room_player_count = NetworkManager._rooms[_room_code]["players"].size()
				print("[SERVER] Room %s: Spawning balls (%d/%d ready)" % [_room_code, _ready_peers.size(), room_player_count])
				_spawned = true
				_server_spawn_balls()
			)
		else:
			# No valid room - free this scene instance
			print("[SERVER] No valid room - freeing scene")
			queue_free()
	else:
		# Client: notify server we're ready
		NetworkManager._rpc_game_client_ready.rpc_id(1)


# --- Server-side RPC handlers (called by NetworkManager proxies) ---

func server_handle_client_ready(sender: int) -> void:
	if not _is_server:
		return
	if sender not in _ready_peers:
		_ready_peers.append(sender)
		var room_player_count := 0
		if _room_code in NetworkManager._rooms:
			room_player_count = NetworkManager._rooms[_room_code]["players"].size()
		print("[SERVER] Room %s: Client %d ready (%d/%d)" % [_room_code, sender, _ready_peers.size(), room_player_count])

	# Check if all clients are ready
	var room_player_count := 0
	if _room_code in NetworkManager._rooms:
		room_player_count = NetworkManager._rooms[_room_code]["players"].size()
	if not _spawned and _ready_peers.size() >= room_player_count:
		_spawned = true
		_server_spawn_balls()


func server_handle_request_launch(sender: int, slot: int, direction: Vector3, power: float) -> void:
	if not _is_server:
		return

	if slot_to_peer.get(slot, -1) != sender:
		_log("LAUNCH_REJECTED slot=%d peer=%d reason=NOT_OWNER" % [slot, sender])
		print("[SERVER] Rejected launch from peer %d for slot %d (not owner)" % [sender, slot])
		return

	# Reject NaN/INF inputs — malicious or corrupted client data
	if not (is_finite(power) and is_finite(direction.x) and is_finite(direction.y) and is_finite(direction.z)):
		_log("LAUNCH_REJECTED slot=%d peer=%d reason=INVALID_VALUES" % [slot, sender])
		print("[SERVER] Rejected launch from peer %d: invalid values" % sender)
		return

	_execute_launch(slot, direction, power)


func server_handle_activate_powerup(sender: int, slot: int, powerup_type: String) -> void:
	if not _is_server:
		return
	if slot_to_peer.get(slot, -1) != sender:
		return
	var ball := balls[slot] if slot < balls.size() else null
	if ball == null or not ball.is_alive:
		return
	powerup_system.server_activate(slot, powerup_type, ball)


func server_handle_send_aim(sender: int, slot: int, direction: Vector3, power: float) -> void:
	if not _is_server:
		return
	if slot_to_peer.get(slot, -1) != sender:
		return
	# Relay to all other players in the room
	for peer_slot: int in slot_to_peer:
		var pid: int = slot_to_peer[peer_slot]
		if pid != sender and pid > 0:
			NetworkManager._rpc_game_receive_aim.rpc_id(pid, slot, direction, power)


# --- Client-side RPC handlers (called by NetworkManager proxies) ---

func client_receive_spawn_balls(spawn_data: Array[Dictionary], alive: Array[int]) -> void:
	_last_sync_time = Time.get_ticks_msec() / 1000.0
	alive_players = alive
	balls.clear()

	# Build a lookup from slot -> data for active players only
	var slot_data: Dictionary = {}
	for data: Dictionary in spawn_data:
		slot_data[data["slot"]] = data
		# Apply player names from server
		var slot: int = data["slot"]
		if slot >= 0 and slot < player_names.size() and data.has("name"):
			player_names[slot] = data["name"]

	for slot_idx in PLAYER_COUNT:
		if slot_idx not in slot_data:
			balls.append(null)
			continue

		var data: Dictionary = slot_data[slot_idx]
		var ball: PoolBall = BALL_SCENE.instantiate()
		ball.name = "Ball_%d" % slot_idx
		var color := Color(data["color_r"], data["color_g"], data["color_b"])
		ball.setup(data["id"], color)
		ball.slot = slot_idx
		ball.position = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])

		balls_container.add_child(ball)
		balls.append(ball)

		# Apply visuals after _ready has run
		ball.apply_setup(data["id"], color)
		ball._is_local_ball = (slot_idx == NetworkManager.my_slot)

	game_hud.set_info_default()
	game_hud.build_scoreboard()


func client_receive_state(positions: PackedVector3Array, rotations: PackedVector3Array, lin_vels: PackedVector3Array, ang_vels: PackedVector3Array) -> void:
	_last_sync_time = Time.get_ticks_msec() / 1000.0
	for i in mini(balls.size(), positions.size()):
		var ball := balls[i]
		if ball != null and ball.is_alive:
			ball.receive_state(positions[i], rotations[i], lin_vels[i], ang_vels[i])


func client_receive_ball_pocketed(slot: int, pocket_pos: Vector3) -> void:
	if slot >= 0 and slot < balls.size() and balls[slot] != null:
		balls[slot].start_pocket_animation(pocket_pos)


func client_receive_player_eliminated(slot: int) -> void:
	if slot >= 0 and slot < balls.size() and balls[slot] != null:
		balls[slot].eliminate()
		alive_players.erase(slot)
	_handle_elimination(slot)


func client_receive_player_disconnected(slot: int) -> void:
	game_hud.add_disconnect_feed_entry(slot)


func client_receive_game_over(winner_slot: int) -> void:
	_handle_game_over(winner_slot)


func client_receive_sync_scores(scores: Dictionary) -> void:
	NetworkManager.room_scores = scores
	game_hud.update_scoreboard()


func client_receive_spawn_powerup(id: int, type: int, pos_x: float, pos_z: float) -> void:
	if _is_headless:
		return
	powerup_system.on_spawned(id, type, pos_x, pos_z)


func client_receive_powerup_picked_up(powerup_id: int, slot: int, type: int) -> void:
	powerup_system.on_picked_up(powerup_id, slot, type)


func client_receive_powerup_consumed(slot: int) -> void:
	powerup_system.on_consumed(slot)


func client_receive_shockwave_effect(pos_x: float, pos_z: float) -> void:
	if _is_headless:
		return
	powerup_system.create_shockwave_effect(pos_x, pos_z)


func client_receive_speed_boost_armed(slot: int) -> void:
	if _is_headless:
		return
	powerup_system.on_speed_boost_armed(slot)


func client_receive_bomb_armed(slot: int) -> void:
	if _is_headless:
		return
	powerup_system.on_bomb_armed(slot)


func client_receive_shield_activate(slot: int) -> void:
	if _is_headless:
		return
	powerup_system.on_shield_activate(slot)


func client_receive_shield_block(pos_x: float, pos_z: float) -> void:
	if _is_headless:
		return
	powerup_system.create_shield_block_effect(pos_x, pos_z)


func client_receive_speed_boost(slot: int) -> void:
	if _is_headless:
		return
	powerup_system.create_speed_boost_effect(slot)


func client_receive_anchor_effect(slot: int) -> void:
	if _is_headless:
		return
	powerup_system.create_anchor_effect(slot)


func client_receive_aim(slot: int, direction: Vector3, power: float) -> void:
	aim_visuals.on_aim_received(slot, direction, power)


# --- Ball spawning ---

func _apply_ball_physics(ball: PoolBall) -> void:
	ball.mass = GameConfig.ball_mass
	ball.linear_damp = GameConfig.ball_linear_damp
	ball.angular_damp = GameConfig.ball_angular_damp
	if ball.physics_material_override:
		ball.physics_material_override = ball.physics_material_override.duplicate()
		ball.physics_material_override.friction = GameConfig.ball_friction
		ball.physics_material_override.bounce = GameConfig.ball_bounce


func _server_spawn_balls() -> void:
	for peer_id: int in NetworkManager.players:
		var pdata: Dictionary = NetworkManager.players[peer_id]
		# Only include players from this room
		if pdata.get("room", "") != _room_code:
			continue
		var slot: int = pdata["slot"]
		if slot < 0 or slot >= PLAYER_COUNT:
			push_warning("Invalid slot %d for peer %d, skipping" % [slot, peer_id])
			continue
		slot_to_peer[slot] = peer_id

	# Build player_names from lobby data
	for peer_id: int in NetworkManager.players:
		var pdata: Dictionary = NetworkManager.players[peer_id]
		if pdata.get("room", "") != _room_code:
			continue
		var slot: int = pdata["slot"]
		var pname: String = pdata.get("name", "")
		if not pname.is_empty() and slot >= 0 and slot < player_names.size():
			player_names[slot] = "%s (%s)" % [pname, player_color_names[slot]]

	var spawn_positions: Array[Vector3] = [
		Vector3(-3, 0.5, -3),
		Vector3(3, 0.5, -3),
		Vector3(-3, 0.5, 3),
		Vector3(3, 0.5, 3),
	]

	# Build spawn data to send to clients
	var spawn_data: Array[Dictionary] = []

	for slot_idx in PLAYER_COUNT:
		var is_active := slot_idx in slot_to_peer

		if not is_active:
			balls.append(null)
			continue

		var ball: PoolBall = BALL_SCENE.instantiate()
		ball.name = "Ball_%d" % slot_idx
		ball.setup(slot_idx + 1, player_colors[slot_idx])
		ball.slot = slot_idx
		ball.position = spawn_positions[slot_idx]

		alive_players.append(slot_idx)
		balls_container.add_child(ball)
		balls.append(ball)

		# Apply physics from config
		_apply_ball_physics(ball)

		spawn_data.append({
			"slot": slot_idx,
			"id": slot_idx + 1,
			"color_r": player_colors[slot_idx].r,
			"color_g": player_colors[slot_idx].g,
			"color_b": player_colors[slot_idx].b,
			"pos_x": spawn_positions[slot_idx].x,
			"pos_y": spawn_positions[slot_idx].y,
			"pos_z": spawn_positions[slot_idx].z,
			"name": player_names[slot_idx],
		})

	# Tell all clients in this room to create their balls
	for pid in NetworkManager.get_room_peers(_room_code):
		NetworkManager._rpc_game_spawn_balls.rpc_id(pid, spawn_data, alive_players)

	# Get bot slots from room data
	var room_bot_slots: Array[int] = []
	if _room_code in NetworkManager._rooms:
		room_bot_slots = NetworkManager._rooms[_room_code].get("bot_slots", [])

	_log("GAME_START players=%d slots=%s bots=%d" % [
		slot_to_peer.size(), str(slot_to_peer.keys()), room_bot_slots.size()])

	# Start bot AI if there are bots in this room
	if not room_bot_slots.is_empty():
		var BotAI := preload("res://scripts/bot_ai.gd")
		_bot_ai = BotAI.new()
		_bot_ai.setup(self, room_bot_slots)
		add_child(_bot_ai)


func _spawn_balls_local() -> void:
	# Single-player: create balls locally with real physics (no freeze, no RPCs)
	var spawn_positions: Array[Vector3] = [
		Vector3(-3, 0.5, -3),
		Vector3(3, 0.5, -3),
		Vector3(-3, 0.5, 3),
		Vector3(3, 0.5, 3),
	]

	# Build player names from NetworkManager.players
	for peer_id: int in NetworkManager.players:
		var pdata: Dictionary = NetworkManager.players[peer_id]
		var slot: int = pdata["slot"]
		var pname: String = pdata.get("name", "")
		if not pname.is_empty() and slot >= 0 and slot < player_names.size():
			player_names[slot] = "%s (%s)" % [pname, player_color_names[slot]]

	for slot_idx in PLAYER_COUNT:
		# Check if this slot has a player
		var has_player := false
		for peer_id: int in NetworkManager.players:
			if NetworkManager.players[peer_id]["slot"] == slot_idx:
				has_player = true
				break

		if not has_player:
			balls.append(null)
			continue

		var ball: PoolBall = BALL_SCENE.instantiate()
		ball.name = "Ball_%d" % slot_idx
		ball.setup(slot_idx + 1, player_colors[slot_idx])
		ball.slot = slot_idx
		ball.position = spawn_positions[slot_idx]

		alive_players.append(slot_idx)
		balls_container.add_child(ball)
		balls.append(ball)

		# Apply physics from config
		_apply_ball_physics(ball)

		# Apply visuals after _ready
		ball.apply_setup(slot_idx + 1, player_colors[slot_idx])
		ball._is_local_ball = (slot_idx == NetworkManager.my_slot)

	game_hud.set_info_default()
	game_hud.build_scoreboard()
	_log("GAME_START single_player slots=%s bots=%d" % [str(alive_players), NetworkManager.bot_slots.size()])

	# Start bot AI
	if not NetworkManager.bot_slots.is_empty():
		var BotAI := preload("res://scripts/bot_ai.gd")
		_bot_ai = BotAI.new()
		_bot_ai.setup(self, NetworkManager.bot_slots)
		add_child(_bot_ai)


# --- Server state broadcast (60Hz) ---

func _physics_process(delta: float) -> void:
	if _is_server:
		var tick_start := Time.get_ticks_usec()

		_server_check_fallen_balls(delta)
		powerup_system.server_check_pickups()
		_server_check_ball_collisions()

		# Tick down launch cooldowns
		for slot: int in _server_launch_cooldown.keys():
			_server_launch_cooldown[slot] -= delta
			if _server_launch_cooldown[slot] <= 0.0:
				_server_launch_cooldown.erase(slot)

		# Powerup system tick (spawning, shield timer, armed timeout, mass restore)
		powerup_system.server_tick(delta)

		if not NetworkManager.is_single_player:
			_sync_timer += delta
			if _sync_timer >= SYNC_INTERVAL:
				_sync_timer = 0.0
				_server_broadcast_state()

		# Periodic physics state log - only during active game
		if not game_over:
			_physics_log_timer += delta
			if _physics_log_timer >= PHYSICS_LOG_INTERVAL:
				_physics_log_timer = 0.0
				var any_moving := false
				for ball in balls:
					if ball != null and ball.is_alive and not ball.is_pocketing and ball.linear_velocity.length() > 0.05:
						any_moving = true
						break
				if any_moving:
					var parts: Array[String] = []
					for ball in balls:
						if ball == null or not ball.is_alive or ball.is_pocketing:
							continue
						var spd := ball.linear_velocity.length()
						parts.append("b%d:(%.1f,%.1f)v=%.2f" % [
							ball.slot, ball.position.x, ball.position.z, spd])
					_log("STATE %s" % " | ".join(parts))

		# Performance tracking - only during active game
		if not game_over:
			var tick_end := Time.get_ticks_usec()
			var tick_duration_ms := (tick_end - tick_start) / 1000.0
			_perf_tick_durations.append(tick_duration_ms)
			if _perf_tick_durations.size() > 60:
				_perf_tick_durations.remove_at(0)
			_perf_tick_count += 1
			_perf_tick_timer += delta
			if _perf_tick_timer >= 5.0:
				var avg_tick := 0.0
				var max_tick := 0.0
				if _perf_tick_durations.size() > 0:
					avg_tick = _perf_tick_durations.reduce(func(a, b): return a + b) / _perf_tick_durations.size()
					max_tick = _perf_tick_durations.max()
				var tick_rate := float(_perf_tick_count) / _perf_tick_timer
				_log("PERF ticks=%d avg=%.2fms max=%.2fms rate=%.1fHz" % [
					_perf_tick_count, avg_tick, max_tick, tick_rate])
				_perf_tick_count = 0
				_perf_tick_timer = 0.0
				_perf_tick_durations.clear()


func _server_broadcast_state() -> void:
	# Pack all ball states into arrays for efficient transfer
	var positions := PackedVector3Array()
	var rotations := PackedVector3Array()
	var lin_vels := PackedVector3Array()
	var ang_vels := PackedVector3Array()

	for ball in balls:
		if ball != null and ball.is_alive and not ball.is_pocketing:
			# Use position (local to room) not global_position (includes room offset)
			positions.append(ball.position)
			rotations.append(ball.rotation)
			lin_vels.append(ball.linear_velocity)
			ang_vels.append(ball.angular_velocity)
		else:
			positions.append(Vector3.ZERO)
			rotations.append(Vector3.ZERO)
			lin_vels.append(Vector3.ZERO)
			ang_vels.append(Vector3.ZERO)

	for pid in NetworkManager.get_room_peers(_room_code):
		NetworkManager._rpc_game_sync_state.rpc_id(pid, positions, rotations, lin_vels, ang_vels)


# --- Input (client-only) ---

func _unhandled_input(event: InputEvent) -> void:
	if _is_headless or game_over or game_hud.countdown_active:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and not is_dragging:
				_try_grab_own_ball(mb.position)
			elif not mb.pressed and is_dragging:
				_release_shot()

	elif event is InputEventMouseMotion and is_dragging:
		_update_drag(event.position)

	# SPACEBAR - activate powerup (Bomb/Shield)
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_try_activate_powerup()


func _try_grab_own_ball(screen_pos: Vector2) -> void:
	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= balls.size():
		return

	var my_ball := balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		return

	# Only allow aiming when ball is stopped
	if my_ball.is_moving():
		game_hud.set_info_text("Wait for your ball to stop!", Color(1.0, 0.6, 0.2))
		return

	var ball_screen := camera.unproject_position(my_ball.global_position)
	if screen_pos.distance_to(ball_screen) > 100.0:
		return

	active_ball = my_ball
	is_dragging = true
	active_ball.is_dragging = true
	active_ball.drag_start = active_ball.global_position
	active_ball.drag_current = active_ball.global_position

	game_hud.set_info_text("Aiming...", player_colors[my_slot])
	game_hud.show_power_bar()
	aim_visuals.show()


func _update_drag(screen_pos: Vector2) -> void:
	if active_ball == null:
		return

	# Keep drag_start anchored to ball's current position (tracks moving ball)
	active_ball.drag_start = active_ball.global_position

	var world_pos := _screen_to_ground(screen_pos)
	if world_pos == INVALID_POS:
		return

	active_ball.drag_current = world_pos

	var power_ratio := active_ball.get_power_ratio()
	game_hud.update_power_bar(power_ratio)
	aim_visuals.update(active_ball, active_ball.get_launch_direction(), power_ratio)


func _release_shot() -> void:
	if active_ball == null:
		return

	var direction := active_ball.get_launch_direction()
	var power_ratio := active_ball.get_power_ratio()
	var power := power_ratio * active_ball.max_power

	active_ball.is_dragging = false
	is_dragging = false

	aim_visuals.hide()
	game_hud.hide_power_bar()

	# Clear aim indicator for other players
	if not NetworkManager.is_single_player:
		NetworkManager._rpc_game_send_aim.rpc_id(1, NetworkManager.my_slot, Vector3.ZERO, 0.0)

	if power_ratio > 0.02 and not _launch_pending:
		_launch_pending = true
		if NetworkManager.is_single_player:
			_execute_launch(NetworkManager.my_slot, direction, power)
		else:
			NetworkManager._rpc_game_request_launch.rpc_id(1, NetworkManager.my_slot, direction, power)
		# Reset the flag after a short delay to allow next shot
		get_tree().create_timer(GameConfig.launch_cooldown).timeout.connect(func() -> void:
			_launch_pending = false
		)

	game_hud.set_info_default()
	active_ball = null


# --- Active Powerup Activation (client-side) ---

func _try_activate_powerup() -> void:
	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= balls.size():
		return
	var my_ball := balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		return
	powerup_system.try_activate(my_slot, my_ball)


# --- Launch execution ---

func _execute_launch(slot: int, direction: Vector3, power: float) -> void:
	if slot < 0 or slot >= balls.size():
		_log("LAUNCH_REJECTED slot=%d reason=INVALID_SLOT" % slot)
		return

	var ball := balls[slot]
	if ball == null or not ball.is_alive or ball.is_pocketing:
		_log("LAUNCH_REJECTED slot=%d reason=BALL_NOT_ACTIVE alive=%s pocketing=%s" % [slot, ball != null and ball.is_alive, ball != null and ball.is_pocketing])
		return

	# Rate limit: reject if ball is still moving (prevents spam launches)
	if ball.is_moving():
		_log("LAUNCH_REJECTED slot=%d reason=BALL_MOVING spd=%.2f" % [slot, ball.linear_velocity.length()])
		return

	# Cooldown: reject if launched too recently (prevents duplicate RPCs)
	if slot in _server_launch_cooldown:
		_log("LAUNCH_REJECTED slot=%d reason=COOLDOWN_ACTIVE remaining=%.2fs" % [slot, _server_launch_cooldown[slot]])
		return
	_server_launch_cooldown[slot] = GameConfig.launch_cooldown

	direction.y = 0.0
	if direction.length_squared() < 0.001:
		_log("LAUNCH_REJECTED slot=%d reason=INVALID_DIRECTION" % slot)
		return
	direction = direction.normalized()
	power = clampf(power, ball.min_power, ball.max_power)

	# Store pre-launch state for logging
	var pre_pos := ball.position
	var pre_mass := ball.mass

	# Apply speed boost if armed (consumed on launch)
	if ball.held_powerup == Powerup.Type.SPEED_BOOST and ball.speed_boost_armed:
		var pre_power := power
		power = minf(power * GameConfig.speed_boost_multiplier, ball.max_power * GameConfig.speed_boost_multiplier)
		_log("POWERUP_CONSUME ball=%d type=SPEED_BOOST power_before=%.1f power_after=%.1f" % [slot, pre_power, power])
		powerup_system.consume_speed_boost(ball, slot)

	# Bomb and Shield are consumed on collision, not on launch

	ball.launch(direction, power)

	# Log launch outcome - use impulse as proxy for speed since we can't await here
	var launch_spd := power  # Approximate: speed correlates with power
	_log("LAUNCH ball=%d dir=(%.2f,%.2f) power=%.1f mass=%.2f pos=(%.2f,%.2f) impulse=%.1f" % [
		slot, direction.x, direction.z, power, pre_mass,
		pre_pos.x, pre_pos.z, launch_spd])


# --- Server-side disconnect handling ---

func _on_player_disconnected(peer_id: int) -> void:
	if not _is_server or game_over or not _spawned:
		return

	# Bots use negative fake peer IDs and never disconnect
	if peer_id < 0:
		return

	# Find which slot this peer owned
	var slot := -1
	for s: int in slot_to_peer:
		if slot_to_peer[s] == peer_id:
			slot = s
			break

	if slot < 0 or slot >= balls.size():
		return

	var ball := balls[slot]
	if ball == null or not ball.is_alive:
		return

	_log("DISCONNECT ball=%d peer=%d" % [slot, peer_id])
	slot_to_peer.erase(slot)

	# Check if any real players remain (not bots)
	var real_players_left := 0
	for s: int in slot_to_peer:
		if slot_to_peer[s] > 0:
			real_players_left += 1

	if real_players_left == 0:
		_log("ALL_PLAYERS_LEFT — destroying room")
		# Stop bot AI
		if _bot_ai:
			_bot_ai.set_process(false)
			_bot_ai.queue_free()
			_bot_ai = null
		# Clean up room from NetworkManager
		NetworkManager.cleanup_room(_room_code)
		return

	# Notify clients about the disconnect
	for pid in NetworkManager.get_room_peers(_room_code):
		NetworkManager._rpc_game_player_disconnected.rpc_id(pid, slot)

	# Eliminate after grace period (in case of brief network hiccup)
	get_tree().create_timer(GameConfig.disconnect_grace_period).timeout.connect(func() -> void:
		if not is_instance_valid(self):
			return
		if ball != null and ball.is_alive and not ball.is_pocketing and not game_over:
			_log("DISCONNECT_ELIM ball=%d (ghost ball removed)" % slot)
			ball.is_pocketing = true
			ball.set_collision_layer_value(1, false)
			ball.set_collision_mask_value(1, false)
			ball.linear_velocity *= 0.2
			ball.apply_central_impulse(Vector3(0, -3, 0))
			for pid in NetworkManager.get_room_peers(_room_code):
				NetworkManager._rpc_game_ball_pocketed.rpc_id(pid, slot, ball.position)
	)


# --- Server-side game logic ---

func _server_check_fallen_balls(delta: float) -> void:
	for ball in balls:
		if ball == null or not ball.is_alive:
			continue

		# Skip balls already in pocketing animation
		if ball.is_pocketing:
			# Wait for ball to fall far enough then finalize elimination
			# Also force eliminate after 1 second as safety
			# In single-player, pool_ball._process() already increments _pocket_timer for the visual animation
			if not NetworkManager.is_single_player:
				ball._pocket_timer += delta
			if ball.position.y < FALL_THRESHOLD or ball._pocket_timer > 1.0:
				_finalize_elimination(ball)
			continue

		# Check pocket detection (XZ distance to each pocket center)
		# Use position (local to room) for server-side logic
		var bx := ball.position.x
		var bz := ball.position.z
		var pocket_pos := Vector3.ZERO
		var pocketed := false

		for i in POCKET_POSITIONS.size():
			var pocket := POCKET_POSITIONS[i]
			var is_corner := i < 4
			var radius: float = CORNER_POCKET_RADIUS if is_corner else MID_POCKET_RADIUS
			var dist := Vector2(bx, bz).distance_to(Vector2(pocket.x, pocket.z))
			if dist < radius:
				pocketed = true
				pocket_pos = pocket
				break

		if pocketed:
			# Start pocketing: disable collision, let ball fall visually
			ball.is_pocketing = true
			ball.set_collision_layer_value(1, false)
			ball.set_collision_mask_value(1, false)
			ball.linear_velocity *= 0.2
			ball.apply_central_impulse(Vector3(0, -3, 0))
			_log("POCKET ball=%d pos=(%.2f,%.2f,%.2f) pocket=(%.1f,%.1f) vel=(%.2f,%.2f,%.2f)" % [
				ball.slot, ball.position.x, ball.position.y, ball.position.z,
				pocket_pos.x, pocket_pos.z,
				ball.linear_velocity.x, ball.linear_velocity.y, ball.linear_velocity.z])
			# Tell clients to play pocket animation
			if NetworkManager.is_single_player:
				client_receive_ball_pocketed(ball.slot, pocket_pos)
			else:
				for pid in NetworkManager.get_room_peers(_room_code):
					NetworkManager._rpc_game_ball_pocketed.rpc_id(pid, ball.slot, pocket_pos)
		elif ball.position.y < FALL_THRESHOLD:
			# Fell off edge (fallback)
			_finalize_elimination(ball)


func _finalize_elimination(ball: PoolBall) -> void:
	var s := ball.slot
	ball.is_alive = false
	alive_players.erase(s)
	_log("ELIMINATED ball=%d pos=(%.2f,%.2f,%.2f) alive_left=%d" % [
		s, ball.position.x, ball.position.y, ball.position.z,
		alive_players.size()])

	if NetworkManager.is_single_player:
		# Call eliminate() + _handle_elimination() directly (no RPC needed)
		if s >= 0 and s < balls.size() and balls[s] != null:
			balls[s].eliminate()
		_handle_elimination(s)
	else:
		for pid in NetworkManager.get_room_peers(_room_code):
			NetworkManager._rpc_game_player_eliminated.rpc_id(pid, s)
		_handle_elimination(s)

	if alive_players.size() <= 1:
		var winner := alive_players[0] if alive_players.size() == 1 else -1
		# Get room scores from room data
		var scores: Dictionary = {}
		if _room_code in NetworkManager._rooms:
			scores = NetworkManager._rooms[_room_code].get("scores", {})
		elif NetworkManager.is_single_player:
			scores = NetworkManager.room_scores

		if winner >= 0:
			if winner not in scores:
				scores[winner] = 0
			scores[winner] += 1

		# Store back
		if _room_code in NetworkManager._rooms:
			NetworkManager._rooms[_room_code]["scores"] = scores
		elif NetworkManager.is_single_player:
			NetworkManager.room_scores = scores

		# Broadcast scores to all clients along with game over
		if NetworkManager.is_single_player:
			_handle_game_over(winner)
		else:
			var scores_dict: Dictionary = scores.duplicate()
			for pid in NetworkManager.get_room_peers(_room_code):
				NetworkManager._rpc_game_sync_scores.rpc_id(pid, scores_dict)
				NetworkManager._rpc_game_over.rpc_id(pid, winner)
			_handle_game_over(winner)


func _handle_elimination(slot: int) -> void:
	if slot < player_names.size():
		game_hud.add_kill_feed_entry(slot)

	game_hud.update_scoreboard()

	if slot < player_names.size():
		game_hud.set_info_text("%s eliminated!" % player_names[slot], Color(1, 0.3, 0.3))
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if not is_instance_valid(self):
				return
			if not game_over:
				game_hud.set_info_default()
		)


func _handle_game_over(winner_slot: int) -> void:
	game_over = true
	is_dragging = false

	aim_visuals.hide()
	game_hud.hide_power_bar()
	powerup_system.hide_hud()

	if _is_headless:
		var room_duration := (Time.get_ticks_msec() - _room_start_time) / 1000.0 if _room_start_time > 0 else 0.0
		if winner_slot >= 0:
			_log("GAME_OVER winner=%s duration=%.1fs" % [player_names[winner_slot], room_duration])
		else:
			_log("GAME_OVER draw duration=%.1fs" % room_duration)
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			if not is_instance_valid(self):
				return
			print("[SERVER] Room %s: Round complete - cleaning up..." % _room_code)
			# Tell clients to go back to menu
			for pid in NetworkManager.get_room_peers(_room_code):
				NetworkManager._rpc_game_restart.rpc_id(pid)
			# Clean up the room (disposable rooms)
			NetworkManager.cleanup_room(_room_code)
		)
		return

	game_hud.show_game_over(winner_slot)


func _server_check_ball_collisions() -> void:
	var count := balls.size()
	for i in count:
		var a := balls[i]
		if a == null or not a.is_alive or a.is_pocketing:
			continue
		for j in range(i + 1, count):
			var b := balls[j]
			if b == null or not b.is_alive or b.is_pocketing:
				continue

			# Use position (local) for server-side distance checks
			var dist := a.position.distance_to(b.position)
			var key := "%d_%d" % [i, j]
			var was_touching: bool = _server_collision_pairs_phys.get(key, false)
			var is_touching := dist < BALL_TOUCH_DIST

			if is_touching and not was_touching:
				_on_server_ball_collision(a, b)

			_server_collision_pairs_phys[key] = is_touching


func _on_server_ball_collision(a: PoolBall, b: PoolBall) -> void:
	# Log collision details
	var rel_vel := (a.linear_velocity - b.linear_velocity).length()
	var dist := a.position.distance_to(b.position)
	_log("BALL_COLLISION a=%d b=%d rel_vel=%.2f dist=%.3f held_powerup_a=%d held_powerup_b=%d bomb_armed_a=%s bomb_armed_b=%s" % [
		a.slot, b.slot, rel_vel, dist, a.held_powerup, b.held_powerup, a.bomb_armed, b.bomb_armed])

	# Check BOMB - explodes on collision
	if a.held_powerup == Powerup.Type.BOMB and a.bomb_armed:
		_log("BOMB_TRIGGER a=%d" % a.slot)
		powerup_system.trigger_bomb(a)
	if b.held_powerup == Powerup.Type.BOMB and b.bomb_armed:
		_log("BOMB_TRIGGER b=%d" % b.slot)
		powerup_system.trigger_bomb(b)

	# Check SHIELD - blocks collision and knocks back attacker
	if a.held_powerup == Powerup.Type.SHIELD and a.shield_active:
		_log("SHIELD_TRIGGER a=%d" % a.slot)
		powerup_system.trigger_shield(a, b)
		return  # Cancel normal collision
	if b.held_powerup == Powerup.Type.SHIELD and b.shield_active:
		_log("SHIELD_TRIGGER b=%d" % b.slot)
		powerup_system.trigger_shield(b, a)
		return  # Cancel normal collision

	# Normal collision continues...


# --- Client-side updates ---

func _process(delta: float) -> void:
	if _is_headless or game_over:
		return

	# Client-side: detect server timeout (not in single-player)
	if not NetworkManager.is_single_player and not _is_server and _last_sync_time > 0.0:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_sync_time > SERVER_TIMEOUT:
			print("[CLIENT] Server timeout — no sync for %.0fs, returning to menu" % SERVER_TIMEOUT)
			NetworkManager.disconnect_from_server()
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
			return

	if game_hud.countdown_active:
		game_hud.update_countdown(delta)
		return

	# Broadcast own aim to other players while dragging (not in single-player)
	if not NetworkManager.is_single_player and is_dragging and active_ball != null:
		aim_visuals.broadcast_timer += delta
		if aim_visuals.broadcast_timer >= AimVisuals.BROADCAST_INTERVAL:
			aim_visuals.broadcast_timer = 0.0
			var dir := active_ball.get_launch_direction()
			var power := active_ball.get_power_ratio()
			NetworkManager._rpc_game_send_aim.rpc_id(1, NetworkManager.my_slot, dir, power)

	# Update enemy aim line visuals
	if not NetworkManager.is_single_player:
		aim_visuals.update_enemy_lines()

	# Client-side collision detection for comic burst effects and sounds
	if not _is_server or NetworkManager.is_single_player:
		_detect_ball_collisions()


func _detect_ball_collisions() -> void:
	var count := balls.size()

	# Ball-to-ball collisions — use server-synced positions to avoid interpolation jitter
	for i in count:
		var a := balls[i]
		if a == null or not a.is_alive or a.is_pocketing:
			continue
		for j in range(i + 1, count):
			var b := balls[j]
			if b == null or not b.is_alive or b.is_pocketing:
				continue

			var dist := a._to_pos.distance_to(b._to_pos) if a._snapshot_count >= 1 and b._snapshot_count >= 1 else a.global_position.distance_to(b.global_position)
			var key := "%d_%d" % [i, j]
			var was_touching: bool = _collision_pairs.get(key, false)
			var is_touching := dist < BALL_TOUCH_DIST

			if is_touching and not was_touching:
				var rel_vel := (a.synced_velocity - b.synced_velocity).length()
				# At least one ball must be moving meaningfully
				if rel_vel < 0.5:
					_collision_pairs[key] = is_touching
					continue
				var intensity := clampf(rel_vel / 10.0, 0.0, 1.0)
				var mid := a.global_position.lerp(b.global_position, 0.5)
				mid.y = 0.5
				var burst_color := a.ball_color.lerp(b.ball_color, 0.5)
				var burst := ComicBurst.create(mid, burst_color, intensity, intensity > 0.15)
				add_child(burst)
				# Play hit sound on the faster-moving ball
				var faster_ball: PoolBall = a if a.synced_velocity.length() >= b.synced_velocity.length() else b
				faster_ball.play_hit_ball_sound(rel_vel)

			_collision_pairs[key] = is_touching

	# Ball-to-wall collisions — use server-synced positions
	var wall_limit := WALL_HALF - BALL_RADIUS - 0.05
	for i in count:
		var ball := balls[i]
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue

		var pos := ball._to_pos if ball._snapshot_count >= 1 else ball.global_position
		var near_wall := absf(pos.x) > wall_limit or absf(pos.z) > wall_limit
		var was_near: bool = _wall_collision.get(i, false)

		if near_wall and not was_near:
			var speed := ball.synced_velocity.length()
			# Must be moving meaningfully to trigger wall burst
			if speed > 1.0:
				var intensity := clampf(speed / 8.0, 0.0, 1.0)
				var burst_pos := ball.global_position
				if absf(pos.x) > wall_limit:
					burst_pos.x = signf(pos.x) * WALL_HALF
				if absf(pos.z) > wall_limit:
					burst_pos.z = signf(pos.z) * WALL_HALF
				burst_pos.y = 0.4
				var burst := ComicBurst.create(burst_pos, Color(1.0, 0.9, 0.7), intensity * 0.5, false)
				add_child(burst)
				ball.play_hit_wall_sound(speed)

		_wall_collision[i] = near_wall


# --- Utility ---

func _screen_to_ground(screen_pos: Vector2) -> Vector3:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if abs(dir.y) < 0.001:
		return INVALID_POS
	var t := -from.y / dir.y
	if t < 0:
		return INVALID_POS
	return from + dir * t
