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
var bomb_radius: float = 12.0
var shield_duration: float = 3.0
var shield_knockback: float = 8.0
var shield_mass: float = 100.0  # Very heavy when shield active
var powerup_armed_timeout: float = 6.0  # Seconds before armed powerup auto-triggers/expires

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
		"shield_duration": shield_duration,
		"shield_knockback": shield_knockback,
		"shield_mass": shield_mass,
		"powerup_armed_timeout": powerup_armed_timeout,
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
