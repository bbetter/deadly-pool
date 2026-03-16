extends Camera3D

## Free-fly spectator camera for testing/previewing the scene.
## WASD   — move horizontally (relative to look direction)
## E / Space — move up
## Q / Shift  — move down
## Ctrl       — 3× speed boost
## Mouse      — look around (always active)

var speed: float = 12.0
var _yaw: float = 0.0
var _pitch: float = -20.0  # start looking slightly down at the table


func _ready() -> void:
	make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	position = Vector3(0, 6, 22)
	rotation.y = _yaw
	rotation.x = deg_to_rad(_pitch)
	print("[SPECTATE] Free-fly camera active. WASD=move  E/Q=up/down  Ctrl=fast")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_yaw   -= (event as InputEventMouseMotion).relative.x * 0.0025
		_pitch -= (event as InputEventMouseMotion).relative.y * 0.0025
		_pitch  = clampf(_pitch, -89.0, 89.0)
		rotation.y = deg_to_rad(_yaw)
		rotation.x = deg_to_rad(_pitch)


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):     dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):     dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):     dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):     dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_SHIFT):
		dir -= Vector3.UP

	if dir.length_squared() > 0.0:
		var cur_speed := speed * (3.0 if Input.is_key_pressed(KEY_CTRL) else 1.0)
		position += dir.normalized() * cur_speed * delta
