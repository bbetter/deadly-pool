extends RigidBody3D
class_name PoolBall

@export var player_id: int = 0
@export var ball_color: Color = Color.WHITE

var is_alive: bool = true
var is_dragging: bool = false
var drag_start: Vector3
var drag_current: Vector3
var max_power: float
var min_power: float
var slot: int = -1
var is_pocketing: bool = false

# Powerup state
var held_powerup: int = 0  # Powerup.Type
var powerup_armed: bool = false  # Whether the held powerup has been activated
var freeze_timer: float = 0.0  # Freeze countdown (server-side)
var armed_timer: float = 0.0  # Countdown until armed powerup auto-triggers/expires
var _anchor_saved_mass: float = 0.5  # Used by anchor trap mass restore
var _last_process_us: int = 0  # Debug: µs spent in last _process() call

@onready var ball_mesh: MeshInstance3D = $BallMesh
@onready var number_label: Label3D = $NumberLabel
var powerup_ring: MeshInstance3D = null  # Ring aura around ball when holding powerup
var powerup_ring_mat: StandardMaterial3D = null  # Ring material for color/alpha updates

# Static cache — procedural audio generated once, shared across all ball instances
static var _shared_ball_hit_stream: AudioStreamWAV
static var _shared_wall_hit_stream: AudioStreamWAV
static var _shared_fall_stream: AudioStreamWAV

var hit_ball_sound: AudioStreamPlayer3D
var hit_wall_sound: AudioStreamPlayer3D
var fall_sound: AudioStreamPlayer3D

signal ball_launched(ball: PoolBall)
signal ball_fell(ball: PoolBall)

var _sound_cooldown: float = 0.0
var _is_client: bool = false
var _glow_time: float = 0.0
var _is_local_ball: bool = false
var _ball_mat: StandardMaterial3D
var _ring_timer: float = 0.0  # For powerup ring pulse animation

# Client-readable velocity (linear_velocity may not be writable on frozen bodies)
var synced_velocity: Vector3 = Vector3.ZERO
var _prev_velocity: Vector3 = Vector3.ZERO  # For server-side direction change detection

# Client-side smooth tracking of server state
var _to_pos: Vector3
var _to_rot: Vector3
var _to_lin_vel: Vector3
var _snapshot_count: int = 0  # How many snapshots received so far

# Pocketing animation
var _pocket_center: Vector3
var _pocket_timer: float = 0.0
const POCKET_ANIM_DURATION := 0.5


func _ready() -> void:
	max_power = GameConfig.ball_max_power
	min_power = GameConfig.ball_min_power

	if NetworkManager.is_single_player:
		_is_client = false
	else:
		_is_client = multiplayer.has_multiplayer_peer() and not multiplayer.is_server()

	if _is_client:
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		# Disable collision so Jolt doesn't interfere with server-driven positions
		set_collision_layer_value(1, false)
		set_collision_mask_value(1, false)

	# Enable contact monitoring on server for bounce debug logging
	if not _is_client:
		contact_monitor = true
		max_contacts_reported = 4

	_create_powerup_ring()

	if not NetworkManager.is_server_mode:
		_setup_sounds()


func _apply_visuals() -> void:
	if ball_mesh == null:
		return
	var mat := ball_mesh.get_surface_override_material(0)
	if mat == null:
		return
	mat = mat.duplicate() as StandardMaterial3D
	mat.albedo_color = ball_color
	ball_mesh.set_surface_override_material(0, mat)
	_ball_mat = mat
	if number_label:
		number_label.text = str(player_id)


func _create_powerup_ring() -> void:
	# Create powerup ring aura (torus around ball)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.45
	torus.outer_radius = 0.60

	var ring := MeshInstance3D.new()
	ring.name = "PowerupRing"
	ring.mesh = torus
	ring.position = Vector3(0, 0.05, 0)
	ring.visible = false

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.emission_enabled = true
	mat.emission = Color.WHITE
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	add_child(ring)

	powerup_ring = ring
	powerup_ring_mat = mat


func apply_setup(id: int, color: Color) -> void:
	player_id = id
	ball_color = color
	_apply_visuals()


func setup(id: int, color: Color) -> void:
	player_id = id
	ball_color = color
	_apply_visuals()


func _setup_sounds() -> void:
	# Generate procedural audio once; reuse the same streams across all balls
	if _shared_ball_hit_stream == null:
		_shared_ball_hit_stream = _generate_ball_hit_sound()
	if _shared_wall_hit_stream == null:
		_shared_wall_hit_stream = _generate_wall_hit_sound()
	if _shared_fall_stream == null:
		_shared_fall_stream = _generate_fall_sound()

	hit_ball_sound = AudioStreamPlayer3D.new()
	hit_ball_sound.stream = _shared_ball_hit_stream
	hit_ball_sound.max_db = 5.0
	hit_ball_sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(hit_ball_sound)

	hit_wall_sound = AudioStreamPlayer3D.new()
	hit_wall_sound.stream = _shared_wall_hit_stream
	hit_wall_sound.max_db = 3.0
	hit_wall_sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(hit_wall_sound)

	fall_sound = AudioStreamPlayer3D.new()
	fall_sound.stream = _shared_fall_stream
	fall_sound.max_db = 8.0
	fall_sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(fall_sound)

	# Server uses body_entered for collision sounds; clients use game_manager detection
	if not _is_client:
		body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if _is_client or not is_alive or is_pocketing:
		return

	# Keep synced_velocity in sync for local physics (used by collision detection)
	synced_velocity = linear_velocity

	# Progressive damping: apply extra drag when ball is slow
	var speed := linear_velocity.length()
	if speed > 0.01 and speed < GameConfig.ball_slow_threshold:
		var factor := 1.0 - clampf(speed / GameConfig.ball_slow_threshold, 0.0, 1.0)
		var extra_damp := factor * GameConfig.ball_extra_damp_factor
		linear_velocity *= 1.0 - extra_damp * delta
		angular_velocity *= 1.0 - extra_damp * delta

	# Hard stop to prevent endless crawl
	if speed < GameConfig.ball_stop_threshold:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO

	# Detect sudden direction changes (collisions with walls/balls/unknown)
	# DEBUG ONLY - disable in release builds for performance
	if OS.is_debug_build() and not _is_client:
		var prev_spd := _prev_velocity.length()
		if speed > 1.0 and prev_spd > 1.0:
			var dot := linear_velocity.normalized().dot(_prev_velocity.normalized())
			if dot < 0.5:  # More than ~60 degree change
				var pos := global_position
				# Use Jolt's own contact list to see what we actually hit
				var colliders := get_colliding_bodies()
				var hit_what := ""
				for body in colliders:
					if body is PoolBall:
						hit_what += "BALL_%d " % body.slot
					elif body is StaticBody3D:
						hit_what += "STATIC(%s@%.1f,%.1f) " % [body.name, body.global_position.x, body.global_position.z]
					else:
						hit_what += "%s " % body.name
				if hit_what.is_empty():
					# Fallback: distance-based guess
					var near_wall := absf(pos.x) > 9.0 or absf(pos.z) > 9.0
					hit_what = "WALL_NEAR" if near_wall else "NOTHING"
				# Find room code from parent GameManager
				var room_code := ""
				var gm_node := get_parent().get_parent()  # Ball -> Balls -> GameManager
				if gm_node and "_room_code" in gm_node:
					room_code = gm_node._room_code
				NetworkManager.room_log(room_code,
					"BOUNCE ball=%d hit=[%s] pos=(%.2f,%.2f) vel_before=(%.1f,%.1f)v=%.1f vel_after=(%.1f,%.1f)v=%.1f dot=%.2f" % [
					slot, hit_what.strip_edges(), pos.x, pos.z,
					_prev_velocity.x, _prev_velocity.z, prev_spd,
					linear_velocity.x, linear_velocity.z, speed, dot])
	_prev_velocity = linear_velocity


func _process(delta: float) -> void:
	var _t0 := Time.get_ticks_usec()
	if _sound_cooldown > 0.0:
		_sound_cooldown -= delta

	# Client-side timer countdown (server handles this in server_tick; clients need local copy for HUD)
	if _is_client and powerup_armed:
		if armed_timer > 0.0:
			armed_timer -= delta
		if freeze_timer > 0.0:
			freeze_timer -= delta

	# Update powerup ring aura
	if powerup_ring != null and is_alive and not is_pocketing:
		if held_powerup != Powerup.Type.NONE:
			powerup_ring.visible = true

			# Update ring timer for pulse animation
			_ring_timer += delta

			# Get powerup color
			var pu_color: Color = Powerup.get_color(held_powerup)

			# Pulse effect when armed
			var armed: bool = powerup_armed
			var pulse: float = 1.0
			if armed:
				pulse = 0.7 + 0.3 * absf(sin(_ring_timer * 6.0))  # Faster pulse when armed

			powerup_ring_mat.albedo_color = Color(pu_color.r, pu_color.g, pu_color.b, 0.9 * pulse)
			powerup_ring_mat.emission = Color(pu_color.r, pu_color.g, pu_color.b)
			powerup_ring_mat.emission_energy_multiplier = 2.5 * pulse
		else:
			powerup_ring.visible = false
			_ring_timer = 0.0

	# Launchable glow pulse (client-side, local ball only)
	if _is_local_ball and _ball_mat:
		var can_launch := is_alive and not is_pocketing and not is_moving() and not is_dragging
		if can_launch:
			_glow_time += delta
			var pulse := (sin(_glow_time * 3.0) + 1.0) * 0.5  # 0..1
			var intensity := lerpf(0.15, 0.6, pulse)
			_ball_mat.emission_enabled = true
			_ball_mat.emission = ball_color
			_ball_mat.emission_energy_multiplier = intensity
		else:
			if _ball_mat.emission_enabled:
				_ball_mat.emission_enabled = false
			_glow_time = 0.0

	# Pocketing animation (client-side)
	if is_pocketing and not NetworkManager.is_server_mode:
		_pocket_timer += delta
		var t := clampf(_pocket_timer / POCKET_ANIM_DURATION, 0.0, 1.0)
		# Ease-in curve for acceleration into pocket
		var ease_t := t * t

		# Move toward pocket center and sink down
		var start_y := 0.35  # ball surface height
		var end_y := -1.5
		global_position.x = lerpf(global_position.x, _pocket_center.x, ease_t * 0.3)
		global_position.z = lerpf(global_position.z, _pocket_center.z, ease_t * 0.3)
		global_position.y = lerpf(start_y, end_y, ease_t)

		# Shrink the ball as it falls in
		var s := lerpf(1.0, 0.3, ease_t)
		scale = Vector3(s, s, s)
		_last_process_us = Time.get_ticks_usec() - _t0
		return

	# Client-side position tracking
	# Smoothly blend toward server position. At 60Hz updates the positions are
	# close together, so a fast lerp looks smooth and hides the discrete steps —
	# especially around wall bounces where the ball reverses direction in one tick.
	if _is_client and _snapshot_count >= 1:
		var blend := clampf(delta * 40.0, 0.0, 1.0)  # ~0.67 per frame at 60fps
		global_position = global_position.lerp(_to_pos, blend)
		rotation = rotation.lerp(_to_rot, blend)

		synced_velocity = _to_lin_vel
		# NOTE: Don't set linear_velocity/angular_velocity on frozen bodies
		# It can trigger physics recalculations and cause spikes

	_last_process_us = Time.get_ticks_usec() - _t0


func receive_state(pos: Vector3, rot: Vector3, lin_vel: Vector3) -> void:
	if is_pocketing:
		return  # Don't update state during pocket animation

	_to_pos = pos
	_to_rot = rot
	_to_lin_vel = lin_vel
	synced_velocity = lin_vel
	_snapshot_count = mini(_snapshot_count + 1, 2)

	# Snap if very far off (teleport, spawn, etc.)
	if global_position.distance_to(pos) > 3.0:
		global_position = pos
		rotation = rot




func start_pocket_animation(pocket_pos: Vector3) -> void:
	is_pocketing = true
	_pocket_center = pocket_pos
	_pocket_timer = 0.0
	# In single-player, freeze the ball so Jolt doesn't fight the visual animation
	if NetworkManager.is_single_player:
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	if fall_sound:
		fall_sound.pitch_scale = randf_range(0.8, 1.1)
		fall_sound.play()


func get_power_ratio() -> float:
	if not is_dragging:
		return 0.0
	var dist := drag_start.distance_to(drag_current)
	return clampf(dist / 5.0, 0.0, 1.0)


func get_launch_direction() -> Vector3:
	var dir := drag_start - drag_current
	dir.y = 0
	return dir.normalized()


func launch(direction: Vector3, power: float) -> void:
	var force := direction * clampf(power, min_power, max_power)
	apply_central_impulse(force)
	ball_launched.emit(self)


func is_moving() -> bool:
	if _is_client:
		return synced_velocity.length() > GameConfig.ball_moving_threshold
	return linear_velocity.length() > GameConfig.ball_moving_threshold


func eliminate() -> void:
	is_alive = false
	if not is_pocketing and fall_sound:
		fall_sound.pitch_scale = randf_range(0.8, 1.1)
		fall_sound.play()
	ball_fell.emit(self)
	# Hide ball after a short delay if pocketing, immediately otherwise
	if is_pocketing:
		get_tree().create_timer(0.3).timeout.connect(func() -> void:
			visible = false
		)
	else:
		visible = false


func play_hit_ball_sound(speed: float) -> void:
	if _sound_cooldown > 0.0 or is_pocketing:
		return
	_sound_cooldown = 0.08
	if hit_ball_sound:
		hit_ball_sound.volume_db = lerpf(-25.0, 5.0, clampf(speed / 8.0, 0.0, 1.0))
		hit_ball_sound.pitch_scale = randf_range(0.9, 1.15)
		hit_ball_sound.play()


func play_hit_wall_sound(speed: float) -> void:
	if _sound_cooldown > 0.0 or is_pocketing:
		return
	_sound_cooldown = 0.08
	if hit_wall_sound:
		hit_wall_sound.volume_db = lerpf(-25.0, 3.0, clampf(speed / 8.0, 0.0, 1.0))
		hit_wall_sound.pitch_scale = randf_range(0.85, 1.1)
		hit_wall_sound.play()


func _on_body_entered(body: Node) -> void:
	var speed := linear_velocity.length()
	if body is PoolBall:
		play_hit_ball_sound(speed)
	else:
		play_hit_wall_sound(speed)


# --- Procedural sound generation ---

func _generate_ball_hit_sound() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.12
	var samples := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / sample_rate
		var env := exp(-t * 60.0)
		var sig := sin(t * TAU * 3200.0) * 0.5 + sin(t * TAU * 4800.0) * 0.3
		if t < 0.005:
			sig += randf_range(-1.0, 1.0) * 0.8
		sig *= env
		var sample := int(clampf(sig, -1.0, 1.0) * 32767.0)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_wall_hit_sound() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.15
	var samples := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / sample_rate
		var env := exp(-t * 35.0)
		var sig := sin(t * TAU * 800.0) * 0.6 + sin(t * TAU * 1200.0) * 0.3
		if t < 0.008:
			sig += randf_range(-1.0, 1.0) * 0.5
		sig *= env
		var sample := int(clampf(sig, -1.0, 1.0) * 32767.0)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_fall_sound() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.5
	var samples := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / sample_rate
		var env := exp(-t * 4.0)
		var freq := lerpf(600.0, 120.0, t / duration)
		var sig := sin(t * TAU * freq) * 0.5
		sig += randf_range(-1.0, 1.0) * 0.15 * env
		sig *= env
		var sample := int(clampf(sig, -1.0, 1.0) * 32767.0)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
