extends Node

var game_manager: Node  # Reference to GameManager
var bot_slots: Array[int] = []
var _bot_timers: Dictionary = {}  # slot -> float (countdown to next shot)
var _bot_shot_count: Dictionary = {}  # slot -> int (for tracking bot activity)

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
			continue

		# Auto-arm any held powerup (bots always arm immediately)
		if ball.held_powerup != Powerup.Type.NONE:
			if ball.held_powerup == Powerup.Type.SPEED_BOOST and not ball.speed_boost_armed:
				ball.speed_boost_armed = true
				ball.armed_timer = GameConfig.powerup_armed_timeout
				ball.update_powerup_icon()
			elif ball.held_powerup == Powerup.Type.BOMB and not ball.bomb_armed:
				ball.bomb_armed = true
				ball.armed_timer = GameConfig.powerup_armed_timeout
				ball.update_powerup_icon()
			elif ball.held_powerup == Powerup.Type.SHIELD and not ball.shield_active:
				ball.shield_active = true
				ball.shield_timer = GameConfig.shield_duration
				ball.mass = GameConfig.shield_mass
				ball.armed_timer = GameConfig.powerup_armed_timeout
				ball.update_powerup_icon()

		_bot_timers[slot] -= delta
		if _bot_timers[slot] > 0.0:
			continue

		# Time to shoot — pick a target and launch
		_bot_timers[slot] = randf_range(GameConfig.bot_min_delay, GameConfig.bot_max_delay)
		_bot_shot_count[slot] += 1
		_bot_shoot(slot, ball)


func _bot_shoot(slot: int, ball: PoolBall) -> void:
	# Pick a target using smart targeting if enabled
	var targets: Array[PoolBall] = []
	for other in game_manager.balls:
		if other == null or other == ball or not other.is_alive or other.is_pocketing:
			continue
		targets.append(other)

	if targets.is_empty():
		_log("BOT_SHOOT slot=%d NO_TARGETS" % slot)
		return

	var target: PoolBall = _select_best_target(ball, targets)

	# Direction toward target (use position for server-side)
	var dir := (target.position - ball.position)
	dir.y = 0.0
	var distance := dir.length()
	if distance < 0.01:
		_log("BOT_SHOOT slot=%d target=%d TOO_CLOSE" % [slot, target.slot])
		return
	dir = dir.normalized()

	# Calculate scatter based on distance - closer = more accurate, farther = more scatter
	var scatter_multiplier := _calculate_scatter_multiplier(distance)
	var scatter_angle := randf_range(-GameConfig.bot_scatter_angle, GameConfig.bot_scatter_angle) * scatter_multiplier
	dir = dir.rotated(Vector3.UP, scatter_angle)

	# Calculate power based on distance - ensure enough power to reach target
	var power := _calculate_power(ball, distance)

	game_manager._execute_launch(slot, dir, power)

	# Build targets string manually (GDScript has no Array.join())
	var targets_str := ""
	for i in range(targets.size()):
		if i > 0: targets_str += ","
		targets_str += str(targets[i].slot)

	_log("BOT_DECIDE slot=%d shot=%d targets=[%s] chosen=%d dist=%.2f scatter_mult=%.2f power=%.1f" % [
		slot, _bot_shot_count[slot], targets_str,
		target.slot, distance, scatter_multiplier, power])


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
