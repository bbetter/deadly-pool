extends Node

var game_manager: Node  # Reference to GameManager
var bot_slots: Array[int] = []
var _bot_timers: Dictionary = {}  # slot -> float (countdown to next shot)
var _bot_shot_count: Dictionary = {}  # slot -> int (for tracking bot activity)
var _bot_aim: Dictionary = {}          # slot -> {dir, power, target_slot} — pre-computed on ball stop
var _bot_aim_broadcast_timers: Dictionary = {}  # slot -> float, for rate-limiting RPC aim broadcasts

func setup(gm: Node, slots: Array[int]) -> void:
	game_manager = gm
	bot_slots = slots
	for slot in bot_slots:
		_bot_timers[slot] = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
		_bot_shot_count[slot] = 0


func _process(delta: float) -> void:
	if game_manager == null or game_manager.game_over or game_manager.game_hud.countdown_active:
		return

	for slot in bot_slots:
		if slot >= game_manager.balls.size():
			continue
		var ball: PoolBall = game_manager.balls[slot]
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue

		# Wait for ball to stop before aiming
		if ball.is_moving():
			_bot_timers[slot] = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
			_clear_aim(slot)
			continue

		# Auto-arm any held powerup (bots always arm immediately)
		if ball.held_powerup != Powerup.Type.NONE and not ball.powerup_armed:
			ball.powerup_armed = true
			ball.armed_timer = GameConfig.powerup_armed_timeout
			if ball.held_powerup == Powerup.Type.FREEZE:
				ball.freeze_timer = GameConfig.freeze_duration
				ball.linear_velocity = Vector3.ZERO
				ball.angular_velocity = Vector3.ZERO
				ball.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				ball.freeze = true
			if NetworkManager.is_single_player:
				game_manager.powerup_system.on_powerup_armed(slot, ball.held_powerup)
			else:
				for pid in NetworkManager.get_room_peers(game_manager._room_code):
					NetworkManager._rpc_game_powerup_armed.rpc_id(pid, slot, ball.held_powerup)

		# Pre-compute aim the moment ball stops so aim line shows during full countdown
		if slot not in _bot_aim:
			_compute_bot_aim(slot, ball)

		# Feed aim into the aim line system
		if slot in _bot_aim:
			var aim: Dictionary = _bot_aim[slot]
			var power_ratio: float = aim["power"] / ball.max_power
			if game_manager._is_headless:
				# Multiplayer: server broadcasts bot aim to clients via the same RPC used for
				# human player aim relaying, rate-limited to BROADCAST_INTERVAL
				_bot_aim_broadcast_timers[slot] = _bot_aim_broadcast_timers.get(slot, 0.0) - delta
				if _bot_aim_broadcast_timers[slot] <= 0.0:
					_bot_aim_broadcast_timers[slot] = AimVisuals.BROADCAST_INTERVAL
					for pid in NetworkManager.get_room_peers(game_manager._room_code):
						if pid > 0:
							NetworkManager._rpc_game_receive_aim.rpc_id(pid, slot, aim["dir"], power_ratio)
			else:
				# Single-player: inject directly into local aim_visuals
				game_manager.aim_visuals.on_aim_received(slot, aim["dir"], power_ratio)

		_bot_timers[slot] -= delta
		if _bot_timers[slot] > 0.0:
			continue

		# Timer expired — fire with pre-computed aim
		_bot_timers[slot] = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
		_bot_shot_count[slot] += 1
		_bot_shoot(slot, ball)


func _compute_bot_aim(slot: int, ball: PoolBall) -> void:
	var targets: Array[PoolBall] = []
	for other in game_manager.balls:
		if other == null or other == ball or not other.is_alive or other.is_pocketing:
			continue
		targets.append(other)

	if targets.is_empty():
		return

	var target: PoolBall = _select_best_target(ball, targets)

	var dir := (target.position - ball.position)
	dir.y = 0.0
	var distance := dir.length()
	if distance < 0.01:
		return
	dir = dir.normalized()

	var scatter_multiplier := _calculate_scatter_multiplier(distance)
	var scatter_angle := randf_range(-GameConfig.bot_scatter_angle, GameConfig.bot_scatter_angle) * scatter_multiplier
	dir = dir.rotated(Vector3.UP, scatter_angle)

	var power := _calculate_power(ball, distance)

	_bot_aim[slot] = {"dir": dir, "power": power, "target_slot": target.slot}


func _bot_shoot(slot: int, ball: PoolBall) -> void:
	if slot not in _bot_aim:
		_log("BOT_SHOOT slot=%d NO_AIM_DATA" % slot)
		return

	var aim: Dictionary = _bot_aim[slot]
	var dir: Vector3 = aim["dir"]
	var power: float = aim["power"]

	_clear_aim(slot)
	game_manager._execute_launch(slot, dir, power)

	_log("BOT_SHOOT slot=%d shot=%d target=%d power=%.1f" % [
		slot, _bot_shot_count[slot], aim.get("target_slot", -1), power])


func _clear_aim(slot: int) -> void:
	if slot not in _bot_aim:
		return
	_bot_aim.erase(slot)
	_bot_aim_broadcast_timers.erase(slot)
	if game_manager._is_headless:
		for pid in NetworkManager.get_room_peers(game_manager._room_code):
			if pid > 0:
				NetworkManager._rpc_game_receive_aim.rpc_id(pid, slot, Vector3.ZERO, 0.0)
	else:
		game_manager.aim_visuals.on_aim_received(slot, Vector3.ZERO, 0.0)


func _select_best_target(ball: PoolBall, targets: Array[PoolBall]) -> PoolBall:
	if not GameConfig.bot_smart_targeting:
		return targets[randi() % targets.size()]

	# Score each target - lower is better
	var best_target: PoolBall = targets[0]
	var best_score := INF

	for target: PoolBall in targets:
		# Use position (local to room) for server-side calculations
		var dist := ball.position.distance_to(target.position)

		# Score based on distance (closer = easier = lower score)
		var score := dist

		# Add some randomness to make it unpredictable (±20%)
		score *= randf_range(0.8, 1.2)

		# Bonus for targets near pockets (easier to hit into pocket)
		for pocket in game_manager.POCKET_POSITIONS:
			var dist_to_pocket := target.position.distance_to(pocket)
			if dist_to_pocket < 3.0:
				score *= 0.7  # 30% easier if near pocket

		if score < best_score:
			best_score = score
			best_target = target

	return best_target


func _calculate_scatter_multiplier(distance: float) -> float:
	# Base scatter modified by distance
	# Close range (0-5m): more accurate (multiplier < 1)
	# Far range (10m+): less accurate (multiplier > 1)

	var base_multiplier: float = lerp(GameConfig.bot_accuracy_easy, GameConfig.bot_accuracy_hard,
		clampf(distance / 15.0, 0.0, 1.0))

	# Add distance-based scatter increase
	var distance_penalty := distance * GameConfig.bot_distance_factor

	# Add small random variance for unpredictability (±10%)
	var variance := randf_range(0.9, 1.1)

	return (base_multiplier + distance_penalty) * variance


func _calculate_power(ball: PoolBall, distance: float) -> float:
	# Base power range from config
	var base_min := ball.max_power * GameConfig.bot_power_min_pct
	var base_max := ball.max_power * GameConfig.bot_power_max_pct

	# Calculate minimum power needed to reach target (empirical)
	var min_power_for_dist := distance * GameConfig.bot_min_power_for_distance

	# Random base power
	var power := randf_range(base_min, base_max)

	# Ensure minimum power for distance
	power = maxf(power, min_power_for_dist)

	# Add variance for unpredictability
	power *= randf_range(1.0 - GameConfig.bot_power_variance, 1.0 + GameConfig.bot_power_variance)

	return clampf(power, ball.min_power, ball.max_power)


func _log(msg: String) -> void:
	if game_manager and game_manager.has_method("_log"):
		game_manager._log(msg)
