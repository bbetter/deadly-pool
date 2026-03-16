extends RefCounted
class_name BallVisuals
## Per-ball visual effects: powerup ring pulse, glow, trail, pocket animation.
## Extracted from PoolBall._process() to keep pool_ball.gd focused on physics/input.
## Holds animation timers and reads/writes the ball's visual nodes directly.

var _ball: PoolBall

# Animation timers (moved from pool_ball)
var _glow_time: float = 0.0
var _ring_timer: float = 0.0
var _cached_powerup_type: int = -1
var _cached_powerup_color: Color = Color.WHITE
var _pocket_center: Vector3
var _pocket_timer: float = 0.0
const POCKET_ANIM_DURATION := 0.5


func _init(ball: PoolBall) -> void:
	_ball = ball


func start_pocket(center: Vector3) -> void:
	_pocket_center = center
	_pocket_timer = 0.0


## Advance all visual effects by delta seconds.
## Returns true if a pocket animation is in progress — caller should return early from _process.
func tick(delta: float) -> bool:
	_tick_powerup_ring(delta)
	_tick_glow(delta)
	_tick_trail()
	if _ball.is_pocketing:
		_tick_pocket_anim(delta)
		return true
	return false


func _tick_powerup_ring(delta: float) -> void:
	var ring: MeshInstance3D = _ball.powerup_ring
	if ring == null or not _ball.is_alive or _ball.is_pocketing:
		return
	if _ball.held_powerup != Powerup.Type.NONE:
		ring.visible = true
		_ring_timer += delta
		# Refresh color cache only when powerup type changes
		if _ball.held_powerup != _cached_powerup_type:
			_cached_powerup_type = _ball.held_powerup
			_cached_powerup_color = Powerup.get_color(_ball.held_powerup)
		var pu_color: Color = _cached_powerup_color
		var pulse := 1.0
		if _ball.powerup_armed:
			pulse = 0.7 + 0.3 * absf(sin(_ring_timer * 6.0))
		var mat: StandardMaterial3D = _ball.powerup_ring_mat
		mat.albedo_color = Color(pu_color.r, pu_color.g, pu_color.b, 0.9 * pulse)
		mat.emission = Color(pu_color.r, pu_color.g, pu_color.b)
		mat.emission_energy_multiplier = 2.5 * pulse
	else:
		ring.visible = false
		_ring_timer = 0.0


func _tick_glow(delta: float) -> void:
	if not _ball._is_local_ball or _ball._ball_mat == null:
		return
	var can_launch := _ball.is_alive and not _ball.is_pocketing and not _ball.is_moving() and not _ball.is_dragging
	if can_launch:
		_glow_time += delta
		var pulse := (sin(_glow_time * 3.0) + 1.0) * 0.5
		_ball._ball_mat.emission_energy_multiplier = lerpf(0.15, 0.6, pulse)
	else:
		if _ball._ball_mat.emission_energy_multiplier > 0.0:
			_ball._ball_mat.emission_energy_multiplier = 0.0
		_glow_time = 0.0


func _tick_trail() -> void:
	var trail: GPUParticles3D = _ball._trail
	if trail != null:
		trail.emitting = _ball.is_alive and not _ball.is_pocketing and _ball.is_moving()


func _tick_pocket_anim(delta: float) -> void:
	_pocket_timer += delta
	var t := clampf(_pocket_timer / POCKET_ANIM_DURATION, 0.0, 1.0)
	var ease_t := t * t  # ease-in for acceleration into pocket
	var start_y := 0.35
	var end_y := -1.5
	_ball.global_position.x = lerpf(_ball.global_position.x, _pocket_center.x, ease_t * 0.3)
	_ball.global_position.z = lerpf(_ball.global_position.z, _pocket_center.z, ease_t * 0.3)
	_ball.global_position.y = lerpf(start_y, end_y, ease_t)
	var s := lerpf(1.0, 0.3, ease_t)
	_ball.scale = Vector3(s, s, s)
