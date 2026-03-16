extends Node
## Centralized physics tuning config. Registered as GameConfig autoload.
## All tunable gameplay values live here. Other scripts read GameConfig.xxx.

# --- Ball Physics ---
var ball_mass: float = 0.6
var ball_friction: float = 0.1
var ball_bounce: float = 0.8
var ball_linear_damp: float = 0.5
var ball_angular_damp: float = 0.8
var ball_max_power: float = 18.0
var ball_min_power: float = 0.5
var ball_radius: float = 0.35
var ball_slow_threshold: float = 1.2         # speed below which extra damping kicks in
var ball_extra_damp_factor: float = 4.0      # max extra damping multiplier at low speed
var ball_stop_threshold: float = 0.03        # speed below which ball hard-stops
var ball_moving_threshold: float = 0.25      # speed above which ball counts as "moving"

# --- Powerups ---
var powerup_pickup_radius: float = 1.2
var powerup_max_on_table: int = 3
var powerup_spawn_min_delay: float = 8.0
var powerup_spawn_max_delay: float = 14.0
var bomb_force: float = 12.0
var bomb_radius: float = 6.0
var freeze_duration: float = 2.0  # How long ball stays frozen (acts as wall)
var powerup_armed_timeout: float = 6.0  # Seconds before armed powerup auto-triggers/expires
var powerup_expiring_threshold: float = 1.25  # Show EXPIRING visuals below this time
var bomb_fizzle_force_scale: float = 0.45  # Expired bomb: mini-pop force multiplier
var bomb_fizzle_radius_scale: float = 0.6  # Expired bomb: mini-pop radius multiplier
var portal_trap_duration: float = 10.0         # Seconds both portals stay active
var portal_trap_placement_radius: float = 8.0  # Max distance from ball to place a portal
var portal_trap_detection_radius: float = 0.8  # Radius for ball→portal collision
var portal_trap_pocket_exclusion: float = 2.5  # Min distance from pocket centers
var portal_trap_ball_exclusion: float = 1.5    # Min distance from any ball
var portal_trap_min_portal_dist: float = 3.0   # Min distance between blue and orange portals
var portal_trap_reentry_cooldown: float = 0.5  # Per-ball cooldown after transiting
var gravity_well_duration: float = 6.0
var gravity_well_radius: float = 2.6
var gravity_well_pull_strength: float = 2.2
var gravity_well_max_speed: float = 12.0
var gravity_well_pocket_exclusion: float = 2.4

# --- Powerup Spawn Weights ---
# Relative chance each type appears. 0 = disabled, 2 = twice as likely as 1.
var powerup_weight_bomb: float = 1.0
var powerup_weight_freeze: float = 1.0
var powerup_weight_portal_trap: float = 1.0
var powerup_weight_swap: float = 1.0
var powerup_weight_gravity_well: float = 1.0
var swap_cursor_snap_radius: float = 2.0  # Max cursor distance to snap to a target ball

# --- Bot AI ---
var bot_min_delay: float = 0.6
var bot_max_delay: float = 1.4
var bot_power_min_pct: float = 0.45
var bot_power_max_pct: float = 0.85
var bot_scatter_angle: float = 0.35          # radians (±20 degrees) - base scatter
var bot_accuracy_easy: float = 1.5            # Scatter multiplier for easy shots (close range)
var bot_accuracy_hard: float = 0.6            # Scatter multiplier for hard shots (far range)
var bot_distance_factor: float = 0.08         # How much scatter increases per meter of distance
var bot_power_variance: float = 0.15          # Additional power variance for unpredictability
var bot_smart_targeting: bool = true          # Prioritize closer/easier targets
var bot_min_power_for_distance: float = 0.3   # Minimum power % based on distance to target

# --- Game Timing ---
var launch_cooldown: float = 0.4
var disconnect_grace_period: float = 3.0

# --- Input Feel ---
var input_drag_max_distance: float = 5.0      # World-space drag distance for 100% power
var input_deadzone_ratio: float = 0.06        # 0..1 power deadzone to ignore tiny pulls
var input_power_curve: float = 1.35           # >1 = finer low-power control, <1 = snappier
var input_aim_snap_degrees: float = 2.5       # 0 disables aim-angle snapping
var input_aim_snap_min_power: float = 0.08    # Only snap when pull exceeds this power ratio
var input_full_power_edge_ratio: float = 0.45  # 0..1 of edge distance needed for 100% power


# Store defaults so reset works
var _defaults: Dictionary = {}


func _ready() -> void:
	# Only needed on server (admin dashboard reset_defaults). Skip on web clients.
	if not OS.get_name() == "Web":
		_defaults = to_dict()


func reset_defaults() -> void:
	from_dict(_defaults)


func to_dict() -> Dictionary:
	return {
		"ball_mass": ball_mass,
		"ball_friction": ball_friction,
		"ball_bounce": ball_bounce,
		"ball_linear_damp": ball_linear_damp,
		"ball_angular_damp": ball_angular_damp,
		"ball_max_power": ball_max_power,
		"ball_min_power": ball_min_power,
		"ball_radius": ball_radius,
		"ball_slow_threshold": ball_slow_threshold,
		"ball_extra_damp_factor": ball_extra_damp_factor,
		"ball_stop_threshold": ball_stop_threshold,
		"ball_moving_threshold": ball_moving_threshold,
		"powerup_pickup_radius": powerup_pickup_radius,
		"powerup_max_on_table": powerup_max_on_table,
		"powerup_spawn_min_delay": powerup_spawn_min_delay,
		"powerup_spawn_max_delay": powerup_spawn_max_delay,
		"bomb_force": bomb_force,
		"bomb_radius": bomb_radius,
		"freeze_duration": freeze_duration,
		"powerup_armed_timeout": powerup_armed_timeout,
		"powerup_expiring_threshold": powerup_expiring_threshold,
		"bomb_fizzle_force_scale": bomb_fizzle_force_scale,
		"bomb_fizzle_radius_scale": bomb_fizzle_radius_scale,
		"portal_trap_duration": portal_trap_duration,
		"portal_trap_placement_radius": portal_trap_placement_radius,
		"portal_trap_detection_radius": portal_trap_detection_radius,
		"portal_trap_pocket_exclusion": portal_trap_pocket_exclusion,
		"portal_trap_ball_exclusion": portal_trap_ball_exclusion,
		"portal_trap_min_portal_dist": portal_trap_min_portal_dist,
		"portal_trap_reentry_cooldown": portal_trap_reentry_cooldown,
		"gravity_well_duration": gravity_well_duration,
		"gravity_well_radius": gravity_well_radius,
		"gravity_well_pull_strength": gravity_well_pull_strength,
		"gravity_well_max_speed": gravity_well_max_speed,
		"gravity_well_pocket_exclusion": gravity_well_pocket_exclusion,
		"powerup_weight_bomb": powerup_weight_bomb,
		"powerup_weight_freeze": powerup_weight_freeze,
		"powerup_weight_portal_trap": powerup_weight_portal_trap,
		"powerup_weight_swap": powerup_weight_swap,
		"powerup_weight_gravity_well": powerup_weight_gravity_well,
		"swap_cursor_snap_radius": swap_cursor_snap_radius,
		"bot_min_delay": bot_min_delay,
		"bot_max_delay": bot_max_delay,
		"bot_power_min_pct": bot_power_min_pct,
		"bot_power_max_pct": bot_power_max_pct,
		"bot_scatter_angle": bot_scatter_angle,
		"bot_accuracy_easy": bot_accuracy_easy,
		"bot_accuracy_hard": bot_accuracy_hard,
		"bot_distance_factor": bot_distance_factor,
		"bot_power_variance": bot_power_variance,
		"bot_smart_targeting": bot_smart_targeting,
		"bot_min_power_for_distance": bot_min_power_for_distance,
		"launch_cooldown": launch_cooldown,
		"disconnect_grace_period": disconnect_grace_period,
		"input_drag_max_distance": input_drag_max_distance,
		"input_deadzone_ratio": input_deadzone_ratio,
		"input_power_curve": input_power_curve,
		"input_aim_snap_degrees": input_aim_snap_degrees,
		"input_aim_snap_min_power": input_aim_snap_min_power,
		"input_full_power_edge_ratio": input_full_power_edge_ratio,
	}


func from_dict(d: Dictionary) -> void:
	for key: String in d:
		if key in self:
			var val = d[key]
			var current = get(key)
			if current is bool:
				set(key, bool(val))
			elif current is float:
				set(key, float(val))
			elif current is int:
				set(key, int(val))
