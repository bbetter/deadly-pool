extends Node3D

signal two_finger_started

@export var rotate_speed: float = 0.005
@export var min_pitch: float = 15.0
@export var max_pitch: float = 85.0

@onready var camera: Camera3D = $Camera3D

const FIXED_ZOOM: float = 22.0

var yaw: float = 0.0
var pitch: float = 55.0
var target_yaw: float = 0.0
var target_pitch: float = 55.0

var is_rotating: bool = false
var _prev_yaw: float = -INF   # sentinel so first frame always applies
var _prev_pitch: float = -INF

# Touch-based camera rotation (two-finger drag)
var _touch_points: Dictionary = {}  # index → Vector2
var _touch_mid: Vector2 = Vector2.ZERO

# Death-cam focus
var _look_target: Vector3 = Vector3.ZERO    # desired look-at point
var _look_pos: Vector3 = Vector3.ZERO       # current interpolated look-at point
var _zoom_target: float = FIXED_ZOOM        # desired zoom distance
var _current_zoom: float = FIXED_ZOOM       # current interpolated zoom
var _prev_look_pos: Vector3 = Vector3(INF, INF, INF)
var _prev_zoom: float = -1.0

func is_two_finger() -> bool:
	return _touch_points.size() >= 2

func _get_touch_mid() -> Vector2:
	var sum := Vector2.ZERO
	for pos in _touch_points.values():
		sum += pos
	return sum / _touch_points.size()


func _ready() -> void:
	_apply_camera()


func focus_on(target: Vector3, zoom: float, duration: float) -> void:
	_look_target = target
	_zoom_target = zoom
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_return_to_normal)


func _return_to_normal() -> void:
	_look_target = Vector3.ZERO
	_zoom_target = FIXED_ZOOM


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_MIDDLE:
				is_rotating = mb.pressed
			MOUSE_BUTTON_RIGHT:
				is_rotating = mb.pressed

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if is_rotating:
			target_yaw -= motion.relative.x * rotate_speed * 100.0
			target_pitch -= motion.relative.y * rotate_speed * 100.0
			target_pitch = clampf(target_pitch, min_pitch, max_pitch)

	elif event is InputEventScreenTouch:
		if event.pressed:
			_touch_points[event.index] = event.position
			if _touch_points.size() == 2:
				_touch_mid = _get_touch_mid()
				is_rotating = true
				two_finger_started.emit()
		else:
			_touch_points.erase(event.index)
			if _touch_points.size() < 2:
				is_rotating = false

	elif event is InputEventScreenDrag:
		_touch_points[event.index] = event.position
		if _touch_points.size() >= 2:
			var mid := _get_touch_mid()
			var delta := mid - _touch_mid
			_touch_mid = mid
			target_yaw  -= delta.x * rotate_speed * 100.0
			target_pitch -= delta.y * rotate_speed * 100.0
			target_pitch = clampf(target_pitch, min_pitch, max_pitch)


func _process(delta: float) -> void:
	yaw = lerpf(yaw, target_yaw, delta * 8.0)
	pitch = lerpf(pitch, target_pitch, delta * 8.0)

	# Snap to target once close enough — stops asymptotic drift causing per-frame updates
	if absf(yaw - target_yaw) < 0.001:
		yaw = target_yaw
	if absf(pitch - target_pitch) < 0.001:
		pitch = target_pitch

	_look_pos = _look_pos.lerp(_look_target, delta * 5.0)
	_current_zoom = lerpf(_current_zoom, _zoom_target, delta * 5.0)
	if _look_pos.distance_squared_to(_look_target) < 0.0001:
		_look_pos = _look_target
	if absf(_current_zoom - _zoom_target) < 0.01:
		_current_zoom = _zoom_target

	var look_changed := _look_pos.distance_squared_to(_prev_look_pos) > 0.000001
	var zoom_changed := absf(_current_zoom - _prev_zoom) > 0.001

	# Skip the trig + look_at() call when nothing has changed
	if yaw == _prev_yaw and pitch == _prev_pitch and not look_changed and not zoom_changed:
		return

	_prev_yaw = yaw
	_prev_pitch = pitch
	_prev_look_pos = _look_pos
	_prev_zoom = _current_zoom
	_apply_camera()


func _apply_camera() -> void:
	var yaw_rad := deg_to_rad(yaw)
	var pitch_rad := deg_to_rad(pitch)

	var offset := Vector3(
		_current_zoom * cos(pitch_rad) * sin(yaw_rad),
		_current_zoom * sin(pitch_rad),
		_current_zoom * cos(pitch_rad) * cos(yaw_rad),
	)

	camera.position = _look_pos + offset
	camera.look_at(_look_pos, Vector3.UP)
