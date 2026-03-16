extends Node3D

const BALL_SCENE := preload("res://scenes/pool_ball.tscn")
var PLAYER_COUNT: int = 4  # Set at game-start from actual player count
const FALL_THRESHOLD := -2.0
const INVALID_POS := Vector3(INF, INF, INF)
const SYNC_INTERVAL := 1.0 / 30.0       # 30Hz while balls are moving
const SYNC_IDLE_INTERVAL := 1.0         # 1Hz keepalive when all balls stopped

# Pocket detection (matches arena.gd layout)
const CORNER_POCKET_RADIUS := 1.3
const MID_POCKET_RADIUS := 1.0
const CORNER_POCKET_RADIUS_SQ := CORNER_POCKET_RADIUS * CORNER_POCKET_RADIUS
const MID_POCKET_RADIUS_SQ := MID_POCKET_RADIUS * MID_POCKET_RADIUS
var POCKET_POSITIONS: Array[Vector3] = [
	Vector3(-14, 0, -8), Vector3(14, 0, -8),
	Vector3(-14, 0,  8), Vector3(14, 0,  8),
	Vector3(0, 0, -8), Vector3(0, 0, 8),
]

var balls: Array[PoolBall] = []
var alive_players: Array[int] = []
var active_ball: PoolBall = null
var is_dragging: bool = false
var game_over: bool = false
var _kill_streaks: Dictionary = {}  # slot -> kill count since last death this round

var player_colors: Array[Color] = [
	Color(0.9, 0.15, 0.15),   # 0 Red
	Color(0.15, 0.4, 0.9),    # 1 Blue
	Color(0.9, 0.75, 0.1),    # 2 Yellow
	Color(0.15, 0.8, 0.3),    # 3 Green
	Color(0.85, 0.4, 0.9),    # 4 Purple
	Color(0.9, 0.5, 0.1),     # 5 Orange
	Color(0.1, 0.85, 0.85),   # 6 Cyan
	Color(0.9, 0.9, 0.9),     # 7 White
]
var player_color_names: Array[String] = ["Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Cyan", "White"]
var player_names: Array[String] = ["Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Cyan", "White"]

const BOT_NAMES: Array[String] = [
	"Snooker Steve", "Masse Mike", "Rack Rachel", "Billie Banks",
	"Corner Carl", "Cue Kim", "Eight-Ball Ed", "Side-Pocket Sue",
]

var slot_to_peer: Dictionary = {}
var _sync_timer: float = 0.0
var _countdown_start_tick: int = 0  # Server: when countdown started (for watchdog)
var _ready_peers: Array[int] = []
var _spawned: bool = false

# Subsystems
var game_hud: GameHUD

var aim_visuals: AimVisuals

# Client-side collision detection (for visual effects)
var _collision_fx: CollisionFXSystem
const BALL_RADIUS := 0.35
const BALL_TOUCH_DIST := BALL_RADIUS * 2.0 + 0.05  # Slightly generous for detection
const WALL_HALF_X := 14.0  # Arena is 28x16, X walls at ±14
const WALL_HALF_Z := 8.0   # Arena is 28x16, Z walls at ±8

# Launch deduplication
var _launch_pending: bool = false  # Client-side: waiting for launch to be processed
var _server_launch_cooldown: Dictionary = {}  # slot -> float (server-side cooldown timer)
# Launch cooldown now read from GameConfig.launch_cooldown

var powerup_system: PowerupSystem

var _expired_cooldown_slots: Array[int] = []  # Reused scratch array to avoid alloc in cooldown loop

var _physics_log_timer: float = 0.0
const PHYSICS_LOG_INTERVAL := 0.5  # Log ball states every 0.5s

var _pickup_timer: float = 0.0
const PICKUP_CHECK_INTERVAL := 0.05  # 20Hz — generous for pickup radius detection

var _any_ball_moving: bool = false  # Motion gate: skip broadcast when all balls stopped
var _web_collision_timer: float = 0.0  # Web-only throttle for local collision FX checks
const WEB_COLLISION_CHECK_INTERVAL := 1.0 / 20.0  # 20Hz is enough for local-only FX

var _is_server: bool = false
var _is_headless: bool = false
var _bot_ai: Node
var _bot_slots: Array[int] = []  # Known bot slot indices (client-side)

# Room awareness
var _room_code: String = ""

# Client-side server timeout detection
var _last_sync_time: float = 0.0
const SERVER_TIMEOUT := 15.0      # Return to menu after 15s of no updates (web GC pauses can be long)

var _client_scene_start_time: float = 0.0
const CLIENT_START_TIMEOUT := 20.0  # Return to menu if balls never arrive within 20s

# Server-side periodic watchdog
var _watchdog_timer: float = 0.0

# Client-side persistent log file
var _client_log_file: FileAccess = null

# Performance tracking (server-side)
var _perf_tick_count: int = 0
var _perf_tick_timer: float = 0.0
var _perf_tick_durations: Array[float] = []
var _room_start_time: int = 0  # For room duration logging

# Frame timing debug (client-side)
var _frame_time_samples: Array[float] = []
var _frame_time_spike_count: int = 0
var _last_frame_time: float = 0.0

# Spike detection: counters accumulate in 1s windows; snapshot fires at most once per 4s.
# Uses delta (time between _process calls) to catch GC pauses that fall *between* frames.
const _SPIKE_THRESHOLD_MS := 100.0   # gap >100ms between frames = <10 FPS
const _SPIKE_COOLDOWN_S   := 4.0
const _SPIKE_WINDOW_S     := 1.0
var _spike_cooldown:        float = 0.0
var _spike_window:          float = 0.0
var _spike_sync_count:      int   = 0   # sync RPCs received this window
var _spike_aim_count:       int   = 0   # aim RPCs received this window
var _spike_fx_count:        int   = 0   # FX RPCs received this window
var _spike_last_sync:       int   = 0   # snapshot from previous window
var _spike_last_aim:        int   = 0
var _spike_last_fx:         int   = 0
var _spike_last_mesh_own:   int   = 0
var _spike_last_mesh_enemy: int   = 0

@onready var balls_container: Node3D = $Balls
@onready var hud: CanvasLayer = $HUD
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var _camera_rig: Node3D = $CameraRig


func _log(msg: String) -> void:
	NetworkManager.room_log(_room_code, msg)


# --- Client-side persistent log file ---

func _open_client_log() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("game_logs"):
		dir.make_dir("game_logs")
	var dt := Time.get_datetime_dict_from_system()
	var timestamp := "%04d-%02d-%02d_%02d-%02d-%02d" % [
		dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"]]
	var room_tag := _room_code if not _room_code.is_empty() else "SOLO"
	var path := "user://game_logs/game_%s_%s.log" % [timestamp, room_tag]
	_client_log_file = FileAccess.open(path, FileAccess.WRITE)
	_client_log("[CLIENT] === Deadly Pool session log ===")
	_client_log("[CLIENT] Room: %s | Slot: %d | Platform: %s | Renderer: %s" % [
		room_tag, NetworkManager.my_slot, OS.get_name(),
		RenderingServer.get_video_adapter_name()])
	_trim_old_client_logs(50)


func _trim_old_client_logs(max_count: int) -> void:
	var dir := DirAccess.open("user://game_logs")
	if dir == null:
		return
	var files: PackedStringArray = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("game_") and fname.ends_with(".log"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	files.sort()  # Alphabetical = chronological (timestamp prefix)
	while files.size() > max_count:
		dir.remove(files[0])
		files.remove_at(0)


func _client_log(msg: String) -> void:
	var ts := Time.get_time_string_from_system()
	var line := "[%s] %s" % [ts, msg]
	print(line)
	if _client_log_file != null and _client_log_file.is_open():
		_client_log_file.store_line(line)
		_client_log_file.flush()  # Flush immediately — catches hangs mid-session


func _ready() -> void:
	print("[GAME] _ready() started, renderer: %s" % RenderingServer.get_video_adapter_name())

	# Spectate mode: free-fly camera, no game logic
	if "--spectate" in OS.get_cmdline_user_args():
		var cam: Camera3D = load("res://scripts/spectator_camera.gd").new()
		add_child(cam)
		# Disable the normal camera rig so it doesn't fight for current
		var rig := get_node_or_null("../CameraRig")
		if rig:
			rig.process_mode = Node.PROCESS_MODE_DISABLED
		return

	# Shadows are too expensive on WebGL2 — disable them at runtime for web builds
	if OS.get_name() == "Web":
		for light in find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = false
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

	print("[GAME] mode: headless=%s server=%s single=%s room=%s" % [_is_headless, _is_server, NetworkManager.is_single_player, _room_code])

	if not _is_headless:
		_open_client_log()

	powerup_system = PowerupSystem.new(self)
	_collision_fx = CollisionFXSystem.new(self, powerup_system, PLAYER_COUNT)
	game_hud = GameHUD.new(self)

	aim_visuals = AimVisuals.new(self)

	if _is_headless:
		# Server delays bot AI to match client countdown (3-2-1-GO = ~4s)
		_server_start_countdown()
	else:
		ComicBurst.init_pool(self)
		game_hud.create(hud)
		powerup_system.create_hud(hud)
		aim_visuals.create(self)
		game_hud.create_countdown_overlay(hud)
		# Wire touch button signals → game actions
		game_hud.powerup_button_pressed.connect(_try_activate_powerup)
		game_hud.emote_button_pressed.connect(_request_emote)
		game_hud.scoreboard_button_pressed.connect(game_hud.toggle_scoreboard)
		# Cancel aim drag when two-finger camera rotation begins
		$CameraRig.two_finger_started.connect(_cancel_drag)

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
				var bot_slots_at_timeout: Array = []
				if _room_code in NetworkManager._rooms:
					var _r: Dictionary = NetworkManager._rooms[_room_code]
					room_player_count = _r["players"].size()
					bot_slots_at_timeout = _r.get("bot_slots", [])
				print("[SERVER] Room %s: Safety timeout — spawning balls (%d/%d ready) bot_slots=%s players=%s" % [
					_room_code, _ready_peers.size(), room_player_count,
					str(bot_slots_at_timeout),
					str(NetworkManager._rooms.get(_room_code, {}).get("players", []))])
				_spawned = true
				_server_spawn_balls()
			)
		else:
			# No valid room - free this scene instance
			print("[SERVER] No valid room - freeing scene")
			queue_free()
	else:
		# Client: notify server we're ready
		_client_scene_start_time = Time.get_ticks_msec() / 1000.0
		_client_log("[CLIENT] Scene ready, notifying server. room=%s slot=%d" % [_room_code, NetworkManager.my_slot])
		NetworkManager._rpc_game_client_ready.rpc_id(1)


# --- Server-side RPC handlers (called by NetworkManager proxies) ---

func server_handle_client_ready(sender: int) -> void:
	if not _is_server:
		return

	# Late-joining spectator: game already running — send current state
	if _spawned:
		_server_sync_spectator(sender)
		return

	if sender not in _ready_peers:
		_ready_peers.append(sender)
		var room_player_count := 0
		var bot_slots_log: Array = []
		if _room_code in NetworkManager._rooms:
			var room: Dictionary = NetworkManager._rooms[_room_code]
			room_player_count = room["players"].size()
			bot_slots_log = room.get("bot_slots", [])
		print("[SERVER] Room %s: Client %d ready (%d/%d) bot_slots=%s players=%s" % [
			_room_code, sender, _ready_peers.size(), room_player_count,
			str(bot_slots_log), str(NetworkManager._rooms.get(_room_code, {}).get("players", []))])

	# Check if all clients are ready
	var room_player_count := 0
	if _room_code in NetworkManager._rooms:
		room_player_count = NetworkManager._rooms[_room_code]["players"].size()
	print("[SERVER] ready check: ready=%d room_total=%d spawned=%s" % [_ready_peers.size(), room_player_count, str(_spawned)])
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


func server_handle_activate_powerup(sender: int, slot: int, powerup_type: String, cursor_world_pos: Vector3 = Vector3.ZERO, portal_yaw: float = 0.0) -> void:
	if not _is_server:
		return
	if slot_to_peer.get(slot, -1) != sender:
		return
	var ball := balls[slot] if slot < balls.size() else null
	if ball == null or not ball.is_alive:
		return
	powerup_system.server_activate(slot, powerup_type, ball, cursor_world_pos, portal_yaw)


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

func client_receive_spawn_balls(spawn_data: Array[Dictionary], alive: Array[int], player_count: int) -> void:
	_client_log("[CLIENT] spawn_balls received: %d balls, alive=%s, player_count=%d" % [spawn_data.size(), str(alive), player_count])
	_last_sync_time = Time.get_ticks_msec() / 1000.0
	PLAYER_COUNT = player_count
	alive_players = alive
	balls.clear()

	# Build a lookup from slot -> data for active players only
	_bot_slots.clear()
	var slot_data: Dictionary = {}
	for data: Dictionary in spawn_data:
		slot_data[data["slot"]] = data
		# Apply player names from server
		var slot: int = data["slot"]
		if slot >= 0 and slot < player_names.size() and data.has("name"):
			player_names[slot] = data["name"]
		if data.get("is_bot", false):
			_bot_slots.append(slot)

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


func client_receive_state(positions: PackedVector3Array, rotations: PackedVector3Array, lin_vels: PackedVector3Array) -> void:
	_last_sync_time = Time.get_ticks_msec() / 1000.0
	_spike_sync_count += 1
	game_hud.on_sync_received()
	for i in mini(balls.size(), positions.size()):
		var ball := balls[i]
		if ball != null and ball.is_alive:
			ball.receive_state(positions[i], rotations[i], lin_vels[i])


func client_receive_ball_pocketed(slot: int, pocket_pos: Vector3) -> void:
	if slot >= 0 and slot < balls.size() and balls[slot] != null:
		balls[slot].start_pocket_animation(pocket_pos)
	if slot == NetworkManager.my_slot:
		Input.vibrate_handheld(80)
	if not _is_headless and is_instance_valid(_camera_rig) and slot == NetworkManager.my_slot:
		_camera_rig.focus_on(pocket_pos, 9.0, 1.8)


func client_receive_player_eliminated(slot: int, killer_slot: int = -1) -> void:
	_client_log("[CLIENT] eliminated slot=%d by=%d alive_before=%s" % [slot, killer_slot, str(alive_players)])
	if slot >= 0 and slot < balls.size() and balls[slot] != null:
		balls[slot].eliminate()
		alive_players.erase(slot)
	_handle_elimination(slot, killer_slot)
	if _check_only_bots_alive():
		game_hud.show_skip_round_btn()


func client_receive_player_disconnected(slot: int) -> void:
	game_hud.add_disconnect_feed_entry(slot)


func client_receive_game_over(winner_slot: int) -> void:
	_client_log("[CLIENT] game_over received: winner_slot=%d alive=%s" % [winner_slot, str(alive_players)])
	_handle_game_over(winner_slot)


func client_receive_sync_scores(scores: Dictionary) -> void:
	NetworkManager.room_scores = scores
	game_hud.update_scoreboard()


func client_receive_spawn_powerup(id: int, type: int, pos_x: float, pos_z: float) -> void:
	if _is_headless:
		return
	powerup_system.on_spawned(id, type, pos_x, pos_z)
	game_hud.show_pickup_label(id, type, Vector3(pos_x, 0.45, pos_z))


func client_receive_powerup_picked_up(powerup_id: int, slot: int, type: int) -> void:
	powerup_system.on_picked_up(powerup_id, slot, type)
	game_hud.hide_pickup_label(powerup_id)


func client_receive_powerup_consumed(slot: int) -> void:
	powerup_system.on_consumed(slot)


func client_receive_shockwave_effect(pos_x: float, pos_z: float) -> void:
	if _is_headless:
		return
	powerup_system.create_shockwave_effect(pos_x, pos_z)


func client_receive_powerup_armed(slot: int, type: int) -> void:
	if _is_headless:
		return
	powerup_system.on_powerup_armed(slot, type)


func client_receive_portal_placed(placer_slot: int, portal_idx: int, pos_x: float, pos_z: float, yaw: float = 0.0) -> void:
	if _is_headless:
		return
	powerup_system.on_portal_placed(placer_slot, portal_idx, pos_x, pos_z, yaw)


func client_receive_portal_transit(ball_slot: int, from_x: float, from_z: float, to_x: float, to_z: float) -> void:
	if _is_headless:
		return
	powerup_system.on_portal_transit(ball_slot, from_x, from_z, to_x, to_z)


func client_receive_portals_expired(placer_slot: int) -> void:
	if _is_headless:
		return
	powerup_system.on_portals_expired(placer_slot)



func client_receive_gravity_well_placed(placer_slot: int, pos_x: float, pos_z: float, duration: float) -> void:
	if _is_headless:
		return
	powerup_system.on_gravity_well_placed(placer_slot, pos_x, pos_z, duration)


func client_receive_gravity_well_expired(placer_slot: int) -> void:
	if _is_headless:
		return
	powerup_system.on_gravity_well_expired(placer_slot)


func client_receive_swap_effect(slot_a: int, old_ax: float, old_az: float, slot_b: int, old_bx: float, old_bz: float) -> void:
	if _is_headless:
		return
	powerup_system.create_swap_effect(slot_a, old_ax, old_az, slot_b, old_bx, old_bz)


func client_receive_aim(slot: int, direction: Vector3, power: float) -> void:
	_spike_aim_count += 1
	aim_visuals.on_aim_received(slot, direction, power)


func client_receive_queued_for_round() -> void:
	if not _is_headless:
		game_hud.set_queued_for_round()


func reset_hud_info() -> void:
	if not game_over and not is_dragging and game_hud != null:
		game_hud.set_info_default()


func client_receive_collision_effect(pos: Vector3, color: Color, intensity: float, sound_slot: int, is_wall: bool, sound_speed: float) -> void:
	if _is_headless:
		return
	_spike_fx_count += 1
	ComicBurst.fire(pos, color, intensity)
	if sound_slot >= 0 and sound_slot < balls.size() and balls[sound_slot] != null:
		var ball := balls[sound_slot]
		if is_wall:
			ball.play_hit_wall_sound(sound_speed)
		else:
			ball.play_hit_ball_sound(sound_speed)


# --- Ball spawning ---

func _server_start_countdown() -> void:
	# Keep countdown_active true so bots wait, then release after client countdown finishes
	game_hud.countdown_active = true
	_countdown_start_tick = Time.get_ticks_msec()
	get_tree().create_timer(4.5).timeout.connect(_on_countdown_timer_done)


func _on_countdown_timer_done() -> void:
	game_hud.countdown_active = false
	_countdown_start_tick = 0


func _apply_ball_physics(ball: PoolBall) -> void:
	ball.mass = GameConfig.ball_mass
	ball.linear_damp = GameConfig.ball_linear_damp
	ball.angular_damp = GameConfig.ball_angular_damp
	if ball.physics_material_override:
		ball.physics_material_override = ball.physics_material_override.duplicate()
		ball.physics_material_override.friction = GameConfig.ball_friction
		ball.physics_material_override.bounce = GameConfig.ball_bounce


func _server_spawn_balls() -> void:
	print("[DEBUG] _server_spawn_balls START room=%s nm_players=%d" % [_room_code, NetworkManager.players.size()])
	# Set PLAYER_COUNT from active (non-spectator) players only
	if _room_code in NetworkManager._rooms:
		var room: Dictionary = NetworkManager._rooms[_room_code]
		PLAYER_COUNT = room["players"].size() - room.get("spectators", []).size()
	print("[DEBUG] PLAYER_COUNT=%d" % PLAYER_COUNT)

	for peer_id: int in NetworkManager.players:
		var pdata: Dictionary = NetworkManager.players[peer_id]
		print("[DEBUG] player peer=%d slot=%s room=%s" % [peer_id, str(pdata.get("slot", "?")), pdata.get("room", "?")])
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
		Vector3(-5, 0.5, -3),   # 0 top-left
		Vector3( 5, 0.5, -3),   # 1 top-right
		Vector3(-5, 0.5,  3),   # 2 bottom-left
		Vector3( 5, 0.5,  3),   # 3 bottom-right
		Vector3( 0, 0.5, -4),   # 4 top-center
		Vector3( 0, 0.5,  4),   # 5 bottom-center
		Vector3(-6, 0.5,  0),   # 6 left-center
		Vector3( 6, 0.5,  0),   # 7 right-center
	]

	# Get bot slots from room data (needed before spawn loop for is_bot flag in spawn data)
	# NOTE: Use untyped Array to avoid GDScript typed-variable crash when assigning
	# Variant result from Dictionary.get() to Array[int] — this silently aborts the function.
	var room_bot_slots: Array = []
	if _room_code in NetworkManager._rooms:
		var raw = NetworkManager._rooms[_room_code].get("bot_slots", [])
		for s in raw:
			room_bot_slots.append(s as int)
	_bot_slots.clear()
	for s in room_bot_slots:
		_bot_slots.append(s as int)

	# Billiards-themed names for bots
	for i in room_bot_slots.size():
		var s: int = room_bot_slots[i]
		if s >= 0 and s < player_names.size():
			player_names[s] = BOT_NAMES[i % BOT_NAMES.size()]

	print("[DEBUG] slot_to_peer after build: %s" % str(slot_to_peer))
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

		# Apply visuals after _ready has run
		ball.apply_setup(slot_idx + 1, player_colors[slot_idx])

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
			"is_bot": slot_idx in room_bot_slots,
		})

	print("[DEBUG] spawn loop done: alive=%s spawn_data_size=%d" % [str(alive_players), spawn_data.size()])
	# Tell all clients in this room to create their balls
	var room_peers := NetworkManager.get_room_peers(_room_code)
	print("[DEBUG] room_peers=%s" % str(room_peers))
	for pid in room_peers:
		print("[DEBUG] sending spawn_balls to pid=%d" % pid)
		NetworkManager._rpc_game_spawn_balls.rpc_id(pid, spawn_data, alive_players, PLAYER_COUNT)
	print("[DEBUG] _server_spawn_balls COMPLETE")

	_log("GAME_START players=%d slots=%s bots=%d" % [
		slot_to_peer.size(), str(slot_to_peer.keys()), room_bot_slots.size()])

	# Start bot AI if there are bots in this room
	print("[DEBUG] bot_slots check: room_bot_slots=%s is_empty=%s" % [str(room_bot_slots), str(room_bot_slots.is_empty())])
	if not room_bot_slots.is_empty():
		var BotAI := preload("res://scripts/bot_ai.gd")
		_bot_ai = BotAI.new()
		print("[DEBUG] bot_ai created, calling setup with slots=%s" % str(room_bot_slots))
		_bot_ai.setup(self, room_bot_slots)
		print("[DEBUG] Adding bot_ai to scene, self_in_tree=%s" % str(is_inside_tree()))
		add_child(_bot_ai)
		print("[DEBUG] bot_ai added: in_tree=%s is_processing=%s process_mode=%d" % [
			str(_bot_ai.is_inside_tree()), str(_bot_ai.is_processing()), _bot_ai.process_mode])
	else:
		print("[DEBUG] No bots in this room, skipping bot_ai creation")


func _server_sync_spectator(peer_id: int) -> void:
	# Send current game state to a newly joined spectator
	var spawn_data: Array[Dictionary] = []
	for ball in balls:
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue
		var s := ball.slot
		spawn_data.append({
			"slot": s,
			"id": s + 1,
			"color_r": player_colors[s].r,
			"color_g": player_colors[s].g,
			"color_b": player_colors[s].b,
			"pos_x": ball.position.x,
			"pos_y": ball.position.y,
			"pos_z": ball.position.z,
			"name": player_names[s],
		})
	NetworkManager._rpc_game_spawn_balls.rpc_id(peer_id, spawn_data, alive_players.duplicate(), PLAYER_COUNT)
	_log("SPECTATOR_SYNC peer=%d active_balls=%d" % [peer_id, spawn_data.size()])


func _spawn_balls_local() -> void:
	# Single-player: create balls locally with real physics (no freeze, no RPCs)
	PLAYER_COUNT = NetworkManager.players.size()

	var spawn_positions: Array[Vector3] = [
		Vector3(-5, 0.5, -3),   # 0 top-left
		Vector3( 5, 0.5, -3),   # 1 top-right
		Vector3(-5, 0.5,  3),   # 2 bottom-left
		Vector3( 5, 0.5,  3),   # 3 bottom-right
		Vector3( 0, 0.5, -4),   # 4 top-center
		Vector3( 0, 0.5,  4),   # 5 bottom-center
		Vector3(-6, 0.5,  0),   # 6 left-center
		Vector3( 6, 0.5,  0),   # 7 right-center
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

	_bot_slots = NetworkManager.bot_slots.duplicate()

	# Billiards-themed names for bots
	for i in _bot_slots.size():
		var s: int = _bot_slots[i]
		if s >= 0 and s < player_names.size():
			player_names[s] = BOT_NAMES[i % BOT_NAMES.size()]

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
		_pickup_timer += delta
		if _pickup_timer >= PICKUP_CHECK_INTERVAL:
			_pickup_timer = 0.0
			powerup_system.server_check_pickups()
		_collision_fx.server_check(balls)

		# Tick down launch cooldowns (two-pass to avoid .keys() alloc and erase-while-iterating)
		for slot in _server_launch_cooldown:
			_server_launch_cooldown[slot] -= delta
			if _server_launch_cooldown[slot] <= 0.0:
				_expired_cooldown_slots.append(slot)
		for slot in _expired_cooldown_slots:
			_server_launch_cooldown.erase(slot)
		_expired_cooldown_slots.clear()

		# Powerup system tick (spawning, freeze timer, armed timeout, mass restore)
		powerup_system.server_tick(delta)

		if not NetworkManager.is_single_player:
			# Motion gate: track whether any ball is still moving
			var was_moving := _any_ball_moving
			_any_ball_moving = false
			for ball in balls:
				if ball != null and ball.is_alive and not ball.is_pocketing \
						and ball.linear_velocity.length_squared() > 0.0001:
					_any_ball_moving = true
					break

			# When motion stops, immediately send final positions so clients snap to rest
			if was_moving and not _any_ball_moving:
				_server_broadcast_state()
				_sync_timer = 0.0

			# Broadcast at 30Hz while moving, 1Hz idle keepalive when stopped
			_sync_timer += delta
			var effective_interval := SYNC_INTERVAL if _any_ball_moving else SYNC_IDLE_INTERVAL
			if _sync_timer >= effective_interval:
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
				var mem_mb: float = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
				var peers: int = multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0
				_log("PERF ticks=%d avg=%.2fms max=%.2fms rate=%.1fHz peers=%d mem=%.0fMB" % [
					_perf_tick_count, avg_tick, max_tick, tick_rate, peers, mem_mb])
				_perf_tick_count = 0
				_perf_tick_timer = 0.0
				_perf_tick_durations.clear()

		# Watchdog: 30s heartbeat so admin logs always show game state
		_watchdog_timer += delta
		if _watchdog_timer >= 30.0:
			_watchdog_timer = 0.0
			var age := (Time.get_ticks_msec() - _room_start_time) / 1000.0 if _room_start_time > 0 else 0.0
			var peer_count: int = multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0
			_log("HEARTBEAT age=%.0fs alive=%s game_over=%s spawned=%s peers=%d" % [
				age, str(alive_players), str(game_over), str(_spawned), peer_count])
			if _spawned and not game_over and alive_players.size() <= 1:
				_log("WATCHDOG_STUCK alive=%s game_over=false age=%.0fs — round should have ended" % [str(alive_players), age])
			# Countdown safety: if stuck >10s force-clear (timer callback may have been swallowed)
			if game_hud.countdown_active and _countdown_start_tick > 0:
				var countdown_age := (Time.get_ticks_msec() - _countdown_start_tick) / 1000.0
				if countdown_age > 10.0:
					_log("COUNTDOWN_STUCK age=%.0fs — forcing countdown_active=false" % countdown_age)
					game_hud.countdown_active = false
					_countdown_start_tick = 0


func _server_broadcast_state() -> void:
	# Pack all ball states into arrays for efficient transfer
	# ang_vel omitted: clients store but never read it for rendering
	var positions := PackedVector3Array()
	var rotations := PackedVector3Array()
	var lin_vels := PackedVector3Array()

	for ball in balls:
		if ball != null and ball.is_alive and not ball.is_pocketing:
			# Use position (local to room) not global_position (includes room offset)
			positions.append(ball.position)
			rotations.append(ball.rotation)
			lin_vels.append(ball.linear_velocity)
		else:
			positions.append(Vector3.ZERO)
			rotations.append(Vector3.ZERO)
			lin_vels.append(Vector3.ZERO)

	for pid in NetworkManager.get_room_peers(_room_code):
		NetworkManager._rpc_game_sync_state.rpc_id(pid, positions, rotations, lin_vels)


# --- Input (client-only) ---

func _unhandled_input(event: InputEvent) -> void:
	# Tab: hold to expand scoreboard — works regardless of game state
	if not _is_headless and event is InputEventKey and event.keycode == KEY_TAB:
		if not event.echo:
			game_hud.set_scoreboard_expanded(event.pressed)
		get_viewport().set_input_as_handled()
		return

	if _is_headless or game_over or game_hud.countdown_active:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and not is_dragging:
				_try_grab_own_ball(mb.position)
			elif not mb.pressed and is_dragging:
				_release_shot()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			powerup_system.rotate_portal_preview(12.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			powerup_system.rotate_portal_preview(-12.0)

	elif event is InputEventMouseMotion and is_dragging:
		_update_drag(event.position)

	elif event is InputEventScreenTouch:
		if event.pressed:
			if not $CameraRig.is_two_finger():
				_try_grab_own_ball(event.position)
		else:
			if is_dragging:
				_release_shot()

	elif event is InputEventScreenDrag:
		if is_dragging:
			if $CameraRig.is_two_finger():
				_cancel_drag()
			else:
				_update_drag(event.position)

	# SPACEBAR - activate powerup (Bomb/Freeze/etc.)
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_try_activate_powerup()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			powerup_system.rotate_portal_preview(-15.0)
		elif event.keycode == KEY_E:
			powerup_system.rotate_portal_preview(15.0)
		elif event.keycode == KEY_Z:
			_request_emote(0)
		elif event.keycode == KEY_X:
			_request_emote(1)
		elif event.keycode == KEY_C:
			_request_emote(2)


func _try_grab_own_ball(screen_pos: Vector2) -> void:
	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= balls.size():
		return

	var my_ball := balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		return

	# Only allow aiming when ball is stopped
	if my_ball.is_moving():
		return

	var ball_screen := camera.unproject_position(my_ball.global_position)
	var grab_radius := 180.0 if DisplayServer.is_touchscreen_available() else 100.0
	if screen_pos.distance_to(ball_screen) > grab_radius:
		return

	active_ball = my_ball
	is_dragging = true
	active_ball.is_dragging = true
	active_ball.drag_start = active_ball.global_position
	active_ball.drag_current = active_ball.global_position

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
		_client_log("[CLIENT] shot fired: slot=%d dir=(%.2f,%.2f) power=%.0f%%" % [
			NetworkManager.my_slot, direction.x, direction.z, power_ratio * 100.0])
		_launch_pending = true
		Input.vibrate_handheld(40)
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


# Cancels an in-progress drag without firing (used when two-finger touch begins)
func _cancel_drag() -> void:
	if active_ball == null:
		return
	active_ball.is_dragging = false
	is_dragging = false
	active_ball = null
	aim_visuals.hide()
	game_hud.hide_power_bar()


# --- Active Powerup Activation (client-side) ---

# ============================================================
# EMOTES
# ============================================================

const EMOTE_TEXTS: Array[String] = ["HA!", "GG", "???"]

func _request_emote(emote_id: int) -> void:
	if game_over or game_hud.countdown_active:
		return
	var my_slot := NetworkManager.my_slot
	if my_slot < 0:
		return
	if NetworkManager.is_single_player:
		_broadcast_emote(my_slot, emote_id)
	else:
		NetworkManager._rpc_game_request_emote.rpc_id(1, my_slot, emote_id)


func server_handle_emote(sender: int, slot: int, emote_id: int) -> void:
	if slot_to_peer.get(slot, -1) != sender:
		return
	_broadcast_emote(slot, emote_id)


func _broadcast_emote(slot: int, emote_id: int) -> void:
	if NetworkManager.is_single_player:
		client_receive_emote(slot, emote_id)
	else:
		for pid in NetworkManager.get_room_peers(_room_code):
			NetworkManager._rpc_game_emote.rpc_id(pid, slot, emote_id)
		client_receive_emote(slot, emote_id)


func client_receive_emote(slot: int, emote_id: int) -> void:
	if _is_headless or slot < 0 or slot >= balls.size() or balls[slot] == null:
		return
	var ball: PoolBall = balls[slot]
	if not ball.is_alive:
		return
	var text: String = EMOTE_TEXTS[clamp(emote_id, 0, EMOTE_TEXTS.size() - 1)]
	_show_emote_label(ball, text)


func _show_emote_label(ball: PoolBall, text: String) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 56
	label.modulate = ball.ball_color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 1
	label.position = Vector3(0, 1.5, 0)
	ball.add_child(label)
	# Two separate tweens — avoids the parallel+set_delay infinite-loop Godot quirk
	var rise := label.create_tween()
	rise.tween_property(label, "position:y", 3.2, 2.5)
	var fade := label.create_tween()
	fade.tween_interval(0.5)
	fade.tween_property(label, "modulate:a", 0.0, 2.0)
	fade.tween_callback(label.queue_free)


func _try_activate_powerup() -> void:
	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= balls.size():
		return
	var my_ball := balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		return
	var cursor_pos := _screen_to_ground(get_viewport().get_mouse_position())
	powerup_system.try_activate(my_slot, my_ball, cursor_pos, powerup_system.get_portal_preview_yaw())


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

	# Reject launch while freeze powerup is active
	if ball.powerup_armed and ball.held_powerup == Powerup.Type.FREEZE:
		_log("LAUNCH_REJECTED slot=%d reason=FREEZE_ACTIVE" % slot)
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

	# Bomb is consumed on collision, Freeze expires by timer

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
				ball._visuals._pocket_timer += delta
			if ball.position.y < FALL_THRESHOLD or ball._visuals._pocket_timer > 1.0:
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
			var radius_sq: float = CORNER_POCKET_RADIUS_SQ if i < 4 else MID_POCKET_RADIUS_SQ
			var dx := bx - pocket.x
			var dz := bz - pocket.z
			if dx * dx + dz * dz < radius_sq:
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
		_handle_elimination(s, ball.last_hitter)
		if _check_only_bots_alive():
			game_hud.show_skip_round_btn()
	else:
		for pid in NetworkManager.get_room_peers(_room_code):
			NetworkManager._rpc_game_player_eliminated.rpc_id(pid, s, ball.last_hitter)
		_handle_elimination(s, ball.last_hitter)

	# Grant kill reward to whoever pocketed this ball (only if game continues)
	if alive_players.size() > 1 and ball.last_hitter != s and ball.last_hitter != -1:
		powerup_system.grant_kill_reward(ball.last_hitter)

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


func _check_only_bots_alive() -> bool:
	# Returns true when the human player is out and 2+ bots are still fighting.
	# (If only 1 bot is alive the round ends naturally on the next elimination.)
	if alive_players.size() <= 1 or game_over:
		return false
	var my_slot := NetworkManager.my_slot
	if my_slot >= 0 and my_slot in alive_players:
		return false  # The human is still in the game
	for slot in alive_players:
		if slot not in _bot_slots:
			return false  # A human player is still alive
	return true


func skip_round() -> void:
	if not _check_only_bots_alive():
		return
	if NetworkManager.is_single_player:
		_local_restart_round()
	else:
		NetworkManager._rpc_game_request_skip_round.rpc_id(1, _room_code)


func _handle_elimination(slot: int, killer_slot: int = -1) -> void:
	# Streak tracking: victim loses streak, killer gains one
	_kill_streaks[slot] = 0
	if killer_slot >= 0 and killer_slot != slot:
		_kill_streaks[killer_slot] = int(_kill_streaks.get(killer_slot, 0)) + 1
		var streak: int = int(_kill_streaks[killer_slot])
		if streak >= 2:
			game_hud.add_streak_entry(killer_slot, streak)

	if slot < player_names.size():
		game_hud.add_kill_feed_entry(slot, killer_slot)

	game_hud.update_scoreboard()

	# Bots taunt on kill (server-side only to avoid double-broadcast)
	if (_is_server or NetworkManager.is_single_player) and killer_slot >= 0 \
			and killer_slot != slot and killer_slot in _bot_slots and randf() < 0.45:
		_broadcast_emote(killer_slot, randi() % EMOTE_TEXTS.size())



func _handle_game_over(winner_slot: int) -> void:
	if game_over:
		return  # Guard: simultaneous pockets can trigger two eliminations in one frame
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
			_server_restart_round()
		)
		return

	game_hud.show_game_over(winner_slot)  # hide_skip_round_btn() called inside

	# Single-player: auto-restart after delay
	if NetworkManager.is_single_player:
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			if not is_instance_valid(self):
				return
			_local_restart_round()
		)


func get_state_dict() -> Dictionary:
	var age := (Time.get_ticks_msec() - _room_start_time) / 1000.0 if _room_start_time > 0 else 0.0
	var ball_count := 0
	for b in balls:
		if b != null:
			ball_count += 1
	return {
		"game_over": game_over,
		"spawned": _spawned,
		"alive_players": alive_players.duplicate(),
		"alive_count": alive_players.size(),
		"ball_count": ball_count,
		"age_seconds": int(age),
		"any_ball_moving": _any_ball_moving,
	}


func _reset_round_state() -> void:
	# Clear existing balls
	for ball in balls:
		if ball != null and is_instance_valid(ball):
			ball.queue_free()
	balls.clear()
	alive_players.clear()
	slot_to_peer.clear()

	# Reset game state
	game_over = false
	is_dragging = false
	active_ball = null
	aim_visuals.reset()
	_launch_pending = false
	_server_launch_cooldown.clear()
	_collision_fx.reset()
	_pickup_timer = 0.0
	_web_collision_timer = 0.0
	_any_ball_moving = false
	_spike_cooldown = 0.0
	_spike_window = 0.0
	_spike_sync_count = 0
	_spike_aim_count = 0
	_spike_fx_count = 0

	_kill_streaks.clear()

	# Reset powerups
	powerup_system.reset()

	# Remove old bot AI
	if _bot_ai and is_instance_valid(_bot_ai):
		_bot_ai.queue_free()
		_bot_ai = null


func _server_restart_round() -> void:
	_log("ROUND_RESTART starting new round")
	_reset_round_state()
	_room_start_time = Time.get_ticks_msec()

	# Promote pending spectators to active players before spawning
	if _room_code in NetworkManager._rooms:
		var room: Dictionary = NetworkManager._rooms[_room_code]
		var pending: Array = room.get("pending_players", [])
		for peer_id: int in pending:
			var new_slot := NetworkManager._assign_slot_in_room(_room_code)
			if new_slot == -1:
				continue  # No slots left
			if peer_id in NetworkManager.players:
				NetworkManager.players[peer_id]["slot"] = new_slot
				NetworkManager.players[peer_id].erase("spectator")
				NetworkManager._rpc_assign_slot.rpc_id(peer_id, new_slot)
				_log("SPECTATOR_PROMOTED peer=%d slot=%d" % [peer_id, new_slot])
			room["spectators"].erase(peer_id)
		room["pending_players"].clear()

	# Delay bots to match client countdown
	_server_start_countdown()

	# Tell clients to reset
	for pid in NetworkManager.get_room_peers(_room_code):
		NetworkManager._rpc_game_restart.rpc_id(pid)

	# Re-spawn balls (reuses the same spawn logic)
	_server_spawn_balls()


func _local_restart_round() -> void:
	_reset_round_state()

	# Reset HUD
	game_hud.hide_game_over()
	game_hud.clear_pickup_labels()
	game_hud.create_countdown_overlay(hud)

	# Re-spawn balls locally
	_spawn_balls_local()


func client_receive_restart() -> void:
	_client_log("[CLIENT] restart received (new round)")
	_reset_round_state()

	# Reset HUD
	game_hud.hide_game_over()
	game_hud.clear_pickup_labels()
	game_hud.create_countdown_overlay(hud)




# --- Client-side updates ---

func _process(delta: float) -> void:
	if _is_headless:
		return

	# Frame timing: measure how long this frame takes
	var frame_start := Time.get_ticks_usec()

	game_hud.update_debug(delta)

	if game_over:
		return

	# Per-frame HUD status: READY/WAIT pill + powerup hint + pickup label projection
	var _hud_slot := NetworkManager.my_slot
	game_hud.update_pickup_labels()
	if _hud_slot >= 0 and _hud_slot < balls.size() and balls[_hud_slot] != null:
		var _hud_ball := balls[_hud_slot]
		game_hud.update_status(is_dragging, _hud_ball.is_alive, not _hud_ball.is_moving())
		var _hud_remaining := 0.0
		if _hud_ball.is_alive and _hud_ball.held_powerup != Powerup.Type.NONE:
			if _hud_ball.held_powerup == Powerup.Type.FREEZE and _hud_ball.powerup_armed:
				_hud_remaining = _hud_ball.freeze_timer
			elif _hud_ball.armed_timer > 0.0:
				_hud_remaining = _hud_ball.armed_timer
		game_hud.update_powerup_hint(
			_hud_ball.held_powerup if _hud_ball.is_alive else Powerup.Type.NONE,
			_hud_ball.powerup_armed, _hud_remaining)
	else:
		game_hud.update_status(false, false, false)
		game_hud.update_powerup_hint(Powerup.Type.NONE, false, 0.0)

	# Client-side: detect server timeout (not in single-player)
	if not NetworkManager.is_single_player and not _is_server:
		var now := Time.get_ticks_msec() / 1000.0
		if _last_sync_time > 0.0 and now - _last_sync_time > SERVER_TIMEOUT:
			_client_log("[CLIENT] Server timeout — no sync for %.0fs, returning to menu" % SERVER_TIMEOUT)
			NetworkManager.disconnect_from_server()
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
			return
		if _last_sync_time == 0.0 and _client_scene_start_time > 0.0 and now - _client_scene_start_time > CLIENT_START_TIMEOUT:
			_client_log("[CLIENT] Start timeout — server never sent balls after %.0fs (room=%s), returning to menu" % [CLIENT_START_TIMEOUT, _room_code])
			NetworkManager.disconnect_from_server()
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
			return

	# Spike reporter: runs every frame including during countdown, so round-start GC pauses
	# are also captured. Uses delta (gap between _process calls) to catch JS GC / WebGL stalls
	# that are invisible to frame_time_ms. 1-second windows snapshot RPC counters.
	_spike_cooldown -= delta
	_spike_window   += delta
	if _spike_window >= _SPIKE_WINDOW_S:
		_spike_window          -= _SPIKE_WINDOW_S
		_spike_last_sync        = _spike_sync_count
		_spike_last_aim         = _spike_aim_count
		_spike_last_fx          = _spike_fx_count
		_spike_last_mesh_own    = aim_visuals.rebuild_count_own
		_spike_last_mesh_enemy  = aim_visuals.rebuild_count_enemy
		_spike_sync_count       = 0
		_spike_aim_count        = 0
		_spike_fx_count         = 0
		aim_visuals.rebuild_count_own   = 0
		aim_visuals.rebuild_count_enemy = 0
	if delta * 1000.0 >= _SPIKE_THRESHOLD_MS and _spike_cooldown <= 0.0:
		_spike_cooldown = _SPIKE_COOLDOWN_S
		var bc := 0
		for b in balls:
			if b != null and b.is_alive:
				bc += 1
		var report := "gap=%.0fms fps=%d sync/s=%d aim/s=%d fx/s=%d mesh_own=%d mesh_enemy=%d balls=%d plat=%s" % [
			delta * 1000.0, Engine.get_frames_per_second(),
			_spike_last_sync, _spike_last_aim, _spike_last_fx,
			_spike_last_mesh_own, _spike_last_mesh_enemy,
			bc, OS.get_name()]
		if NetworkManager.is_single_player:
			print("[SPIKE] " + report)
		else:
			NetworkManager._rpc_client_spike_report.rpc_id(1, report)

	if game_hud.countdown_active:
		game_hud.update_countdown(delta)
		return

	# Update client-side powerup visuals (portal ring, swap highlights etc.)
	powerup_system.client_update(delta, _screen_to_ground(get_viewport().get_mouse_position()))

	# Broadcast own aim to other players while dragging (not in single-player)
	if not NetworkManager.is_single_player and is_dragging and active_ball != null:
		aim_visuals.broadcast_timer += delta
		if aim_visuals.broadcast_timer >= AimVisuals.BROADCAST_INTERVAL:
			aim_visuals.broadcast_timer = 0.0
			var dir := active_ball.get_launch_direction()
			var power := active_ball.get_power_ratio()
			NetworkManager._rpc_game_send_aim.rpc_id(1, NetworkManager.my_slot, dir, power)

	# Update enemy aim line visuals (bots in single-player also populate enemy_data)
	aim_visuals.update_enemy_lines()

	# Collision detection for comic burst effects and sounds.
	# In multiplayer, the server detects and broadcasts via RPC (Fix 1).
	# In single-player, detect locally (no networking needed).
	if NetworkManager.is_single_player:
		if OS.get_name() == "Web":
			_web_collision_timer += delta
			if _web_collision_timer >= WEB_COLLISION_CHECK_INTERVAL:
				_web_collision_timer = 0.0
				_collision_fx.client_detect(balls)
		else:
			_collision_fx.client_detect(balls)

	# Frame timing: calculate frame duration and track spikes
	var frame_time_ms := (Time.get_ticks_usec() - frame_start) / 1000.0  # Convert to ms
	_last_frame_time = frame_time_ms
	# _frame_time_samples is only read by the debug HUD (OS.is_debug_build() only).
	# Skip the append+remove_at(0) shift in release builds to avoid 60 element-moves/frame.
	if OS.is_debug_build():
		_frame_time_samples.append(frame_time_ms)
		if _frame_time_samples.size() > 60:
			_frame_time_samples.remove_at(0)

	# Track frames that took >16ms (60 FPS target)
	if frame_time_ms > 16.0:
		_frame_time_spike_count += 1
		if frame_time_ms > 50 and OS.get_name() != "Web":  # Major spike (skip on web: console.log adds GC pressure)
			print("[PERF] FRAME SPIKE: %.2fms" % frame_time_ms)




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
