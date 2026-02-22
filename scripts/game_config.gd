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
var speed_boost_multiplier: float = 1.5
var bomb_force: float = 12.0
var bomb_radius: float = 6.0
var freeze_duration: float = 2.0  # How long ball stays frozen (acts as wall)
var powerup_armed_timeout: float = 6.0  # Seconds before armed powerup auto-triggers/expires
var powerup_expiring_threshold: float = 1.25  # Show EXPIRING visuals below this time
var speed_boost_expiry_bonus_pct: float = 0.2  # Expired speed boost: +20% power next launch
var bomb_fizzle_force_scale: float = 0.45  # Expired bomb: mini-pop force multiplier
var bomb_fizzle_radius_scale: float = 0.6  # Expired bomb: mini-pop radius multiplier
var anchor_trap_duration: float = 7.0
var anchor_trap_radius: float = 1.6
var anchor_trap_mass_mult: float = 2.8
var anchor_trap_linear_damp_mult: float = 2.0
var anchor_trap_debuff_duration: float = 2.2
var anchor_trap_max_on_table_per_room: int = 1
var deflector_impulse_scale: float = 1.25
var deflector_min_trigger_speed: float = 1.0
var deflector_self_knockback_scale: float = 0.25

# --- Bot AI ---
var bot_min_delay: float = 1.0
var bot_max_delay: float = 2.5
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
		"speed_boost_multiplier": speed_boost_multiplier,
		"bomb_force": bomb_force,
		"bomb_radius": bomb_radius,
		"freeze_duration": freeze_duration,
		"powerup_armed_timeout": powerup_armed_timeout,
		"powerup_expiring_threshold": powerup_expiring_threshold,
		"speed_boost_expiry_bonus_pct": speed_boost_expiry_bonus_pct,
		"bomb_fizzle_force_scale": bomb_fizzle_force_scale,
		"bomb_fizzle_radius_scale": bomb_fizzle_radius_scale,
		"anchor_trap_duration": anchor_trap_duration,
		"anchor_trap_radius": anchor_trap_radius,
			"anchor_trap_mass_mult": anchor_trap_mass_mult,
			"anchor_trap_linear_damp_mult": anchor_trap_linear_damp_mult,
			"anchor_trap_debuff_duration": anchor_trap_debuff_duration,
			"anchor_trap_max_on_table_per_room": anchor_trap_max_on_table_per_room,
		"deflector_impulse_scale": deflector_impulse_scale,
		"deflector_min_trigger_speed": deflector_min_trigger_speed,
		"deflector_self_knockback_scale": deflector_self_knockback_scale,
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
