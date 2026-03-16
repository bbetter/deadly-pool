extends RefCounted
class_name CollisionFXSystem
## Handles ball-to-ball and ball-to-wall collision detection for both server
## (physics tick, broadcasts RPC) and client (local single-player FX + sounds).
## Extracted from GameManager to keep collision logic self-contained.

const BALL_RADIUS := 0.35
const BALL_TOUCH_DIST := BALL_RADIUS * 2.0 + 0.05
const WALL_HALF_X := 14.0
const WALL_HALF_Z := 8.0

var _gm: Node          # GameManager — for _log() and _room_code
var _ps: PowerupSystem
var _player_count: int

# Collision state (pair keys are integer: i*PLAYER_COUNT+j)
var _server_pairs: Dictionary = {}  # server-side ball-ball + ball-wall
var _client_pairs: Dictionary = {}  # client-side ball-ball
var _client_wall:  Dictionary = {}  # client-side ball-wall


func _init(gm: Node, ps: PowerupSystem, player_count: int) -> void:
	_gm = gm
	_ps = ps
	_player_count = player_count


func reset() -> void:
	_server_pairs.clear()
	_client_pairs.clear()
	_client_wall.clear()


# --- Server-side (called from _physics_process) ---

func server_check(balls: Array[PoolBall]) -> void:
	var count := balls.size()

	# Ball-to-ball
	for i in count:
		var a := balls[i]
		if a == null or not a.is_alive or a.is_pocketing:
			continue
		for j in range(i + 1, count):
			var b := balls[j]
			if b == null or not b.is_alive or b.is_pocketing:
				continue
			var dist := a.position.distance_to(b.position)
			var key := i * _player_count + j
			var was_touching: bool = _server_pairs.get(key, false)
			var is_touching := dist < BALL_TOUCH_DIST
			if is_touching and not was_touching:
				_on_ball_collision(a, b)
			_server_pairs[key] = is_touching

	# Ball-to-wall
	var wall_limit_x := WALL_HALF_X - BALL_RADIUS - 0.05
	var wall_limit_z := WALL_HALF_Z - BALL_RADIUS - 0.05
	for i in count:
		var ball := balls[i]
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue
		var pos := ball.position
		var ax := absf(pos.x)
		var az := absf(pos.z)
		var near_wall := ax > wall_limit_x or az > wall_limit_z
		var wall_key := _player_count * _player_count + i
		var was_near: bool = _server_pairs.get(wall_key, false)
		if near_wall and not was_near:
			var speed := ball.linear_velocity.length()
			if speed > 1.0 and not NetworkManager.is_single_player:
				var intensity := clampf(speed / 8.0, 0.0, 1.0) * 0.5
				var burst_pos := ball.position
				if ax > wall_limit_x:
					burst_pos.x = signf(pos.x) * WALL_HALF_X
				if az > wall_limit_z:
					burst_pos.z = signf(pos.z) * WALL_HALF_Z
				burst_pos.y = 0.4
				for pid in NetworkManager.get_room_peers(_gm._room_code):
					NetworkManager._rpc_game_collision_effect.rpc_id(pid, burst_pos, Color(1.0, 0.9, 0.7), intensity, ball.slot, true, speed)
		_server_pairs[wall_key] = near_wall


func _on_ball_collision(a: PoolBall, b: PoolBall) -> void:
	a.last_hitter = b.slot
	b.last_hitter = a.slot

	var rel_vel := (a.linear_velocity - b.linear_velocity).length()
	var dist := a.position.distance_to(b.position)
	_gm._log("BALL_COLLISION a=%d b=%d rel_vel=%.2f dist=%.3f held_powerup_a=%d held_powerup_b=%d powerup_armed_a=%s powerup_armed_b=%s" % [
		a.slot, b.slot, rel_vel, dist, a.held_powerup, b.held_powerup, a.powerup_armed, b.powerup_armed])

	if a.held_powerup == Powerup.Type.BOMB and a.powerup_armed:
		_gm._log("BOMB_TRIGGER a=%d" % a.slot)
		_ps.trigger_bomb(a)
	if b.held_powerup == Powerup.Type.BOMB and b.powerup_armed:
		_gm._log("BOMB_TRIGGER b=%d" % b.slot)
		_ps.trigger_bomb(b)

	if not NetworkManager.is_single_player and rel_vel >= 0.5:
		var intensity := clampf(rel_vel / 10.0, 0.0, 1.0)
		var mid := a.position.lerp(b.position, 0.5)
		mid.y = 0.5
		var burst_color := a.ball_color.lerp(b.ball_color, 0.5)
		var faster_slot := a.slot if a.linear_velocity.length() >= b.linear_velocity.length() else b.slot
		for pid in NetworkManager.get_room_peers(_gm._room_code):
			NetworkManager._rpc_game_collision_effect.rpc_id(pid, mid, burst_color, intensity, faster_slot, false, rel_vel)


# --- Client-side (called from _process, single-player only) ---

func client_detect(balls: Array[PoolBall]) -> void:
	var count := balls.size()

	# Ball-to-ball
	for i in count:
		var a := balls[i]
		if a == null or not a.is_alive or a.is_pocketing:
			continue
		for j in range(i + 1, count):
			var b := balls[j]
			if b == null or not b.is_alive or b.is_pocketing:
				continue
			var dist := a._to_pos.distance_to(b._to_pos) if a._snapshot_count >= 1 and b._snapshot_count >= 1 else a.global_position.distance_to(b.global_position)
			var key := i * _player_count + j
			var was_touching: bool = _client_pairs.get(key, false)
			var is_touching := dist < BALL_TOUCH_DIST
			if is_touching and not was_touching:
				var rel_vel := (a.synced_velocity - b.synced_velocity).length()
				if rel_vel < 0.5:
					_client_pairs[key] = is_touching
					continue
				var intensity := clampf(rel_vel / 10.0, 0.0, 1.0)
				var mid := a.global_position.lerp(b.global_position, 0.5)
				mid.y = 0.5
				var burst_color := a.ball_color.lerp(b.ball_color, 0.5)
				ComicBurst.fire(mid, burst_color, intensity)
				var faster_ball: PoolBall = a if a.synced_velocity.length() >= b.synced_velocity.length() else b
				faster_ball.play_hit_ball_sound(rel_vel)
			_client_pairs[key] = is_touching

	# Ball-to-wall
	var wall_limit_x := WALL_HALF_X - BALL_RADIUS - 0.05
	var wall_limit_z := WALL_HALF_Z - BALL_RADIUS - 0.05
	for i in count:
		var ball := balls[i]
		if ball == null or not ball.is_alive or ball.is_pocketing:
			continue
		var pos := ball._to_pos if ball._snapshot_count >= 1 else ball.global_position
		var ax := absf(pos.x)
		var az := absf(pos.z)
		var near_wall := ax > wall_limit_x or az > wall_limit_z
		var was_near: bool = _client_wall.get(i, false)
		if near_wall and not was_near:
			var speed := ball.synced_velocity.length()
			if speed > 1.0:
				var intensity := clampf(speed / 8.0, 0.0, 1.0)
				var burst_pos := ball.global_position
				if ax > wall_limit_x:
					burst_pos.x = signf(pos.x) * WALL_HALF_X
				if az > wall_limit_z:
					burst_pos.z = signf(pos.z) * WALL_HALF_Z
				burst_pos.y = 0.4
				ComicBurst.fire(burst_pos, Color(1.0, 0.9, 0.7), intensity * 0.5)
				ball.play_hit_wall_sound(speed)
		_client_wall[i] = near_wall
