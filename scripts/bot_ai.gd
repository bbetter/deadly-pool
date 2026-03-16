extends Node

# ============================================================
# STATE
# ============================================================

var game_manager: Node
var bot_slots: Array = []  # untyped to avoid GDScript typed-Array call mismatch in release builds

var _bot_timers: Dictionary = {}                # int -> float  remaining wait before shot
var _bot_timers_max: Dictionary = {}            # int -> float  full wait duration (for progress)
var _bot_shot_count: Dictionary = {}            # int -> int
var _bot_aim: Dictionary = {}                   # int -> Dictionary  the actual shot to fire
var _bot_aim_display: Dictionary = {}           # int -> Vector3    currently displayed direction
var _bot_aim_broadcast_timers: Dictionary = {}  # int -> float

# Powerup state
var _bot_powerup_timers: Dictionary = {}        # int -> float  countdown to activate powerup
var _bot_portal_step: Dictionary = {}           # int -> int    portal trap placement step (0/1/2)

var _debug_timer: float = 0.0  # Periodic debug log

const BALL_DIAMETER := 0.70  # 2 × ball radius (0.35), used for ghost ball offset

# Pocket positions mirror arena.gd — half_w=14, half_h=8
const POCKET_POSITIONS: Array[Vector3] = [
	Vector3(-14.0, 0.0, -8.0),  # top-left corner
	Vector3( 14.0, 0.0, -8.0),  # top-right corner
	Vector3(-14.0, 0.0,  8.0),  # bottom-left corner
	Vector3( 14.0, 0.0,  8.0),  # bottom-right corner
	Vector3(  0.0, 0.0, -8.0),  # north mid-side
	Vector3(  0.0, 0.0,  8.0),  # south mid-side
]
const ARENA_HALF_W := 14.0
const ARENA_HALF_H := 8.0

# Aiming feel constants
const AIM_WINDOW := 0.35         # seconds before shot: compute real aim, snap display to it
const WOBBLE_INITIAL := 0.65     # radians — how far off the initial rough aim display is
const WOBBLE_DRIFT := 1.6        # radians/second of Brownian drift at start of thinking
const WOBBLE_SNAP_SPEED := 12.0  # lerp rate when converging display to real aim


# ============================================================
# SETUP
# ============================================================

func _ready() -> void:
	print("[BOT_AI] _ready called, bot_slots=%s in_tree=%s" % [str(bot_slots), str(is_inside_tree())])


func setup(gm: Node, slots: Array) -> void:  # untyped Array — avoids GDScript release-build type rejection
	game_manager = gm
	bot_slots = slots
	print("[BOT_AI] setup called, slots=%s gm_null=%s" % [str(slots), str(gm == null)])

	for slot: int in bot_slots:
		var t: float = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
		_bot_timers[slot] = t
		_bot_timers_max[slot] = t
		_bot_shot_count[slot] = 0
	print("[BOT_AI] setup complete, timers=%s" % str(_bot_timers))


# ============================================================
# MAIN LOOP
# ============================================================

func _process(delta: float) -> void:
	if game_manager == null:
		print("[BOT_AI] _process: game_manager is null!")
		return

	_debug_timer += delta
	if _debug_timer >= 3.0:
		_debug_timer = 0.0
		var cd: bool = game_manager.game_hud.countdown_active if game_manager.game_hud != null else true
		var hud_null: bool = game_manager.game_hud == null
		print("[BOT_AI] TICK slots=%s game_over=%s countdown=%s hud_null=%s balls_size=%d timers=%s shots=%s" % [
			str(bot_slots), str(game_manager.game_over), str(cd), str(hud_null),
			game_manager.balls.size(), str(_bot_timers), str(_bot_shot_count)])
		# Per-slot detail
		var balls_ref: Array = game_manager.balls
		for slot in bot_slots:
			var in_range := int(slot) < balls_ref.size()
			var b: PoolBall = balls_ref[int(slot)] if in_range else null
			print("[BOT_AI]   slot=%d in_range=%s ball_null=%s alive=%s moving=%s pocketing=%s timer=%.2f has_aim=%s" % [
				int(slot), str(in_range), str(b == null),
				str(b != null and b.is_alive),
				str(b != null and b.is_moving()),
				str(b != null and b.is_pocketing),
				float(_bot_timers.get(slot, -1.0)),
				str(_bot_aim.has(slot))])

	if game_manager.game_over:
		return
	if game_manager.game_hud == null:
		print("[BOT_AI] game_hud is null, cannot check countdown!")
		return
	if game_manager.game_hud.countdown_active:
		return

	var balls: Array = game_manager.balls

	for slot in bot_slots:
		if int(slot) >= balls.size():
			print("[BOT_AI] slot=%d out of range (balls.size=%d)" % [int(slot), balls.size()])
			continue

		var ball: PoolBall = balls[int(slot)]
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue

		# Powerup activation runs even while moving (bomb arms mid-roll, etc.)
		_process_bot_powerup(slot, ball, balls, delta)

		if ball.is_moving():
			var t: float = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
			_bot_timers[slot] = t
			_bot_timers_max[slot] = t
			_clear_aim(slot)
			continue

		# First frame after ball settles: pick a rough initial display aim
		if not _bot_aim_display.has(slot):
			_init_display_aim(slot, ball.position, balls)

		_bot_timers[slot] = float(_bot_timers[slot]) - delta
		var t: float = float(_bot_timers[slot])

		# Enter precision phase: compute real aim shortly before the shot
		if t <= AIM_WINDOW and not _bot_aim.has(slot):
			print("[BOT_AI] slot=%d entering aim window, computing aim" % slot)
			_compute_bot_aim(slot, ball.position, balls)

		# Update the wobbling display direction each frame
		_update_display_aim(slot, t, delta)

		# Broadcast whatever the display arrow is showing
		_broadcast_display_aim(slot, ball, delta)

		if t > 0.0:
			continue

		# Timer expired — fire
		print("[BOT_AI] slot=%d timer expired (shot#%d), computing final aim" % [slot, int(_bot_shot_count.get(slot, 0)) + 1])
		if not _bot_aim.has(slot):
			_compute_bot_aim(slot, ball.position, balls)
		var new_t: float = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
		_bot_timers[slot] = new_t
		_bot_timers_max[slot] = new_t
		_bot_shot_count[slot] = int(_bot_shot_count[slot]) + 1
		_bot_shoot(slot, ball)


# ============================================================
# DISPLAY AIM — wobble toward real aim over time
# ============================================================

# Pick an initial rough aim direction when the ball first settles.
# Points vaguely toward a random enemy with a large angle offset.
func _init_display_aim(slot: int, ball_pos: Vector3, balls: Array) -> void:
	var bot_pos := Vector3(ball_pos.x, 0.0, ball_pos.z)
	var enemies: Array = []
	for i: int in range(balls.size()):
		if i == slot:
			continue
		var b: PoolBall = balls[i]
		if b == null or not b.is_alive or b.is_pocketing:
			continue
		enemies.append(i)

	var dir: Vector3
	if enemies.is_empty():
		dir = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()
	else:
		var target: PoolBall = balls[enemies[randi() % enemies.size()]]
		dir = (Vector3(target.position.x, 0.0, target.position.z) - bot_pos).normalized()
		dir = dir.rotated(Vector3.UP, randf_range(-WOBBLE_INITIAL, WOBBLE_INITIAL))

	_bot_aim_display[slot] = dir


# Each frame: drift randomly (Brownian motion) when thinking;
# snap smoothly toward the real computed aim once we have it.
func _update_display_aim(slot: int, t: float, delta: float) -> void:
	if not _bot_aim_display.has(slot):
		return

	var disp: Vector3 = _bot_aim_display[slot]
	var max_t: float = float(_bot_timers_max.get(slot, 1.0))
	var progress: float = 1.0 - clampf(t / max_t, 0.0, 1.0)  # 0 at start, 1 at end

	if _bot_aim.has(slot):
		# Real aim computed — converge quickly
		var real_dir: Vector3 = _bot_aim[slot]["dir"]
		disp = disp.lerp(real_dir, delta * WOBBLE_SNAP_SPEED).normalized()
	else:
		# Thinking phase: random drift that shrinks as we get closer to shooting
		var drift: float = WOBBLE_DRIFT * delta * (1.0 - progress)
		disp = disp.rotated(Vector3.UP, randf_range(-drift, drift))
		disp.y = 0.0
		disp = disp.normalized()

	_bot_aim_display[slot] = disp


func _broadcast_display_aim(slot: int, ball: PoolBall, delta: float) -> void:
	if not _bot_aim_display.has(slot):
		return

	var disp_dir: Vector3 = _bot_aim_display[slot]
	var power_ratio: float
	if _bot_aim.has(slot):
		power_ratio = float(_bot_aim[slot]["power"]) / ball.max_power
	else:
		# Show a plausible power level during the thinking phase
		power_ratio = 0.65

	if game_manager._is_headless:
		var bt: float = float(_bot_aim_broadcast_timers.get(slot, 0.0)) - delta
		_bot_aim_broadcast_timers[slot] = bt
		if bt <= 0.0:
			_bot_aim_broadcast_timers[slot] = AimVisuals.BROADCAST_INTERVAL
			for pid: int in NetworkManager.get_room_peers(game_manager._room_code):
				if pid > 0:
					NetworkManager._rpc_game_receive_aim.rpc_id(
						pid, slot, disp_dir, power_ratio
					)
	else:
		game_manager.aim_visuals.on_aim_received(slot, disp_dir, power_ratio)


# ============================================================
# AIM — pocket geometry
# ============================================================

func _compute_bot_aim(slot: int, ball_pos: Vector3, balls: Array) -> void:
	var bot_pos := Vector3(ball_pos.x, 0.0, ball_pos.z)
	var candidates: Array = []

	for i: int in range(balls.size()):
		if i == slot:
			continue

		var target: PoolBall = balls[i]
		if target == null or not target.is_alive or target.is_pocketing:
			continue

		var target_pos := Vector3(target.position.x, 0.0, target.position.z)

		for pocket in POCKET_POSITIONS:
			# Direction target ball must travel to drop into this pocket
			var to_pocket: Vector3 = pocket - target_pos
			to_pocket.y = 0.0
			var dist_to_pocket: float = to_pocket.length()
			if dist_to_pocket < 0.5:
				continue
			var to_pocket_dir: Vector3 = to_pocket.normalized()

			# Ghost ball: where the bot ball's center must be at the moment
			# of contact so the target travels in to_pocket_dir
			var ghost := target_pos - to_pocket_dir * BALL_DIAMETER

			# Skip if ghost is outside the arena (shot is physically impossible)
			if absf(ghost.x) > ARENA_HALF_W - 0.4 or absf(ghost.z) > ARENA_HALF_H - 0.4:
				continue

			# Direction bot must shoot to reach the ghost
			var to_ghost: Vector3 = ghost - bot_pos
			to_ghost.y = 0.0
			var dist_to_ghost: float = to_ghost.length()
			if dist_to_ghost < 0.05:
				continue
			var shot_dir: Vector3 = to_ghost.normalized()

			# Cut quality: 1.0 = full-ball straight shot (easiest),
			# 0.0 = 90-degree cut (impossible), negative = wrong side
			var cut_quality: float = shot_dir.dot(to_pocket_dir)
			if cut_quality <= 0.05:
				continue

			# Prefer moderate cuts (peak ≈ 0.45). Straight shots (cut_quality→1)
			# look like bot is aiming at the pocket; thin cuts (→0) are hard to execute.
			var ideal_cut: float = 0.45
			var cut_score: float = 1.0 - clampf(absf(cut_quality - ideal_cut) * 2.2, 0.0, 1.0)
			var score: float = cut_score * 5.0
			score -= dist_to_ghost * 0.12
			score -= dist_to_pocket * 0.06

			candidates.append({
				"score": score,
				"dir": shot_dir,
				"target_slot": i,
				"dist": dist_to_ghost,
			})

	if candidates.is_empty():
		# No valid pocket shot found — fall back to hitting the nearest enemy
		print("[BOT_AI] slot=%d no pocket candidates, using direct aim" % slot)
		_compute_bot_aim_direct(slot, ball_pos, balls)
		return

	# Sort by score, pick randomly from top 3 — variety without wild scatter
	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	var top_n: int = mini(3, candidates.size())
	var chosen: Dictionary = candidates[randi() % top_n]

	_bot_aim[slot] = {
		"dir": chosen["dir"],
		"power": _calculate_power(balls[slot], chosen["dist"]),
		"target_slot": chosen["target_slot"],
	}
	print("[BOT_AI] slot=%d pocket aim computed: target=%d dir=(%.2f,%.2f) power=%.1f score=%.2f" % [
		slot, chosen["target_slot"], chosen["dir"].x, chosen["dir"].z,
		float(_bot_aim[slot]["power"]), chosen["score"]])


# Fallback: aim straight at the nearest/best enemy (used when no pocket shot exists)
func _compute_bot_aim_direct(slot: int, ball_pos: Vector3, balls: Array) -> void:
	var candidates: Array = []

	for i: int in range(balls.size()):
		if i == slot:
			continue

		var target: PoolBall = balls[i]
		if target == null or not target.is_alive or target.is_pocketing:
			continue

		var to_target: Vector3 = target.position - ball_pos
		to_target.y = 0.0
		var dist: float = to_target.length()
		if dist < 0.05:
			continue

		candidates.append({
			"score": -dist * 0.15,
			"dir": to_target.normalized(),
			"target_slot": i,
			"dist": dist,
		})

	if candidates.is_empty():
		print("[BOT_AI] slot=%d NO aim candidates at all (no enemies?)" % slot)
		return

	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	var top_n: int = mini(3, candidates.size())
	var chosen: Dictionary = candidates[randi() % top_n]

	_bot_aim[slot] = {
		"dir": chosen["dir"],
		"power": _calculate_power(balls[slot], chosen["dist"]),
		"target_slot": chosen["target_slot"],
	}
	print("[BOT_AI] slot=%d direct aim computed: target=%d dir=(%.2f,%.2f) power=%.1f" % [
		slot, chosen["target_slot"], chosen["dir"].x, chosen["dir"].z,
		float(_bot_aim[slot]["power"])])


# ============================================================
# SHOOT
# ============================================================

func _bot_shoot(slot: int, ball: PoolBall) -> void:
	if not _bot_aim.has(slot):
		print("[BOT_AI] _bot_shoot slot=%d: no aim computed, skipping" % slot)
		return

	var aim: Dictionary = _bot_aim[slot]
	print("[BOT_AI] SHOOT slot=%d dir=(%.2f,%.2f) power=%.1f target=%s ball_alive=%s ball_moving=%s" % [
		slot, float(aim["dir"].x), float(aim["dir"].z), float(aim["power"]),
		str(aim.get("target_slot", "?")), str(ball.is_alive), str(ball.is_moving())])
	_clear_aim(slot)

	game_manager._execute_launch(
		slot,
		aim["dir"],
		float(aim["power"])
	)


func _clear_aim(slot: int) -> void:
	_bot_aim.erase(slot)
	_bot_aim_display.erase(slot)
	_bot_aim_broadcast_timers.erase(slot)

	if game_manager._is_headless:
		for pid: int in NetworkManager.get_room_peers(game_manager._room_code):
			if pid > 0:
				NetworkManager._rpc_game_receive_aim.rpc_id(pid, slot, Vector3.ZERO, 0.0)
	else:
		game_manager.aim_visuals.on_aim_received(slot, Vector3.ZERO, 0.0)


# ============================================================
# POWER / ACCURACY
# ============================================================

func _calculate_power(ball: PoolBall, distance: float) -> float:
	var min_p: float = ball.max_power * GameConfig.bot_power_min_pct
	var max_p: float = ball.max_power * GameConfig.bot_power_max_pct

	var power: float = randf_range(min_p, max_p)
	power = maxf(power, distance * GameConfig.bot_min_power_for_distance)
	power *= randf_range(
		1.0 - GameConfig.bot_power_variance,
		1.0 + GameConfig.bot_power_variance
	)

	return clampf(power, ball.min_power, ball.max_power)


# ============================================================
# POWERUP USAGE
# ============================================================

func _process_bot_powerup(slot: int, ball: PoolBall, balls: Array, delta: float) -> void:
	if ball.held_powerup == Powerup.Type.NONE:
		_bot_powerup_timers.erase(slot)
		_bot_portal_step.erase(slot)
		return

	if ball.powerup_armed:
		return  # Already activated — let it run its course

	# Portal trap is two-step; handle separately
	if ball.held_powerup == Powerup.Type.PORTAL_TRAP:
		_process_bot_portal(slot, ball, balls, delta)
		return

	# All other powerups: wait a random delay then activate
	if not _bot_powerup_timers.has(slot):
		_bot_powerup_timers[slot] = randf_range(1.5, 4.0)
	_bot_powerup_timers[slot] = float(_bot_powerup_timers[slot]) - delta
	if float(_bot_powerup_timers[slot]) > 0.0:
		return

	_bot_powerup_timers.erase(slot)
	_bot_activate_powerup(slot, ball, balls)


func _process_bot_portal(slot: int, ball: PoolBall, balls: Array, delta: float) -> void:
	var step: int = int(_bot_portal_step.get(slot, 0))
	var ps: PowerupSystem = game_manager.powerup_system

	if step == 0:
		# Wait then place blue portal somewhere random on table
		if not _bot_powerup_timers.has(slot):
			_bot_powerup_timers[slot] = randf_range(1.0, 2.5)
		_bot_powerup_timers[slot] = float(_bot_powerup_timers[slot]) - delta
		if float(_bot_powerup_timers[slot]) > 0.0:
			return
		var blue_pos := _random_table_pos()
		ps.server_activate(slot, "portal_trap", ball, blue_pos)
		_bot_portal_step[slot] = 1
		_bot_powerup_timers[slot] = randf_range(1.5, 3.0)  # Delay before orange

	elif step == 1:
		# Wait then place orange portal near an enemy
		_bot_powerup_timers[slot] = float(_bot_powerup_timers[slot]) - delta
		if float(_bot_powerup_timers[slot]) > 0.0:
			return
		var enemy_pos := _find_nearest_enemy_pos(slot, ball, balls)
		if enemy_pos == Vector3.INF:
			enemy_pos = _random_table_pos()
		ps.server_activate(slot, "portal_trap", ball, enemy_pos)
		_bot_portal_step[slot] = 2  # Done — wait for powerup to clear naturally

	# step == 2: both portals placed, nothing more to do


func _bot_activate_powerup(slot: int, ball: PoolBall, balls: Array) -> void:
	var ps: PowerupSystem = game_manager.powerup_system
	match ball.held_powerup:
		Powerup.Type.BOMB:
			ps.server_activate(slot, "bomb", ball)
		Powerup.Type.FREEZE:
			ps.server_activate(slot, "freeze", ball)
		Powerup.Type.SWAP:
			var target_pos := _find_nearest_enemy_pos(slot, ball, balls)
			if target_pos != Vector3.INF:
				ps.server_activate(slot, "swap", ball, target_pos)
		Powerup.Type.GRAVITY_WELL:
			var well_pos := _find_enemy_centroid(slot, balls)
			ps.server_activate(slot, "gravity_well", ball, well_pos)


func _find_nearest_enemy_pos(slot: int, ball: PoolBall, balls: Array) -> Vector3:
	var bot_pos := Vector3(ball.position.x, 0.0, ball.position.z)
	var best_dist := INF
	var best_pos := Vector3.INF
	for i in range(balls.size()):
		if i == slot:
			continue
		var b: PoolBall = balls[i]
		if b == null or not b.is_alive or b.is_pocketing:
			continue
		var d: float = bot_pos.distance_to(b.position)
		if d < best_dist:
			best_dist = d
			best_pos = Vector3(b.position.x, 0.0, b.position.z)
	return best_pos


func _find_enemy_centroid(slot: int, balls: Array) -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for i in range(balls.size()):
		if i == slot:
			continue
		var b: PoolBall = balls[i]
		if b == null or not b.is_alive or b.is_pocketing:
			continue
		sum += Vector3(b.position.x, 0.0, b.position.z)
		count += 1
	if count == 0:
		return _random_table_pos()
	return sum / float(count)


func _random_table_pos() -> Vector3:
	return Vector3(randf_range(-8.0, 8.0), 0.0, randf_range(-4.5, 4.5))
