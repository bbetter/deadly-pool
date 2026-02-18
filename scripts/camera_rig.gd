extends Node3D

@export var rotate_speed: float = 0.005
@export var min_pitch: float = 15.0
@export var max_pitch: float = 85.0

@onready var camera: Camera3D = $Camera3D

# Fixed zoom to show entire 20x20 arena
const FIXED_ZOOM: float = 22.0

var yaw: float = 0.0
var pitch: float = 55.0
var target_yaw: float = 0.0
var target_pitch: float = 55.0

var is_rotating: bool = false


func _ready() -> void:
	_apply_camera()


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


func _process(delta: float) -> void:
	yaw = lerpf(yaw, target_yaw, delta * 8.0)
	pitch = lerpf(pitch, target_pitch, delta * 8.0)
	_apply_camera()


func _apply_camera() -> void:
	var yaw_rad := deg_to_rad(yaw)
	var pitch_rad := deg_to_rad(pitch)

	var offset := Vector3(
		FIXED_ZOOM * cos(pitch_rad) * sin(yaw_rad),
		FIXED_ZOOM * sin(pitch_rad),
		FIXED_ZOOM * cos(pitch_rad) * cos(yaw_rad),
	)

	camera.position = offset
	camera.look_at(Vector3.ZERO, Vector3.UP)
