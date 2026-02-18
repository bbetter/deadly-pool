extends RefCounted
class_name Powerup

enum Type {
	NONE = 0,
	SPEED_BOOST = 1,   # Arm with SPACE - 1.5x power on next shot
	BOMB = 2,          # Arm with SPACE - explodes on collision
	SHIELD = 3,        # Arm with SPACE - blocks one hit
}

const META := {
	1: {"name": "Speed Boost", "symbol": ">>", "color": Color(0.2, 0.9, 0.9), "desc": "SPACE to arm - 1.5x power on next shot"},
	2: {"name": "Bomb", "symbol": "(*)", "color": Color(1.0, 0.3, 0.1), "desc": "SPACE to arm - explode on hit"},
	3: {"name": "Shield", "symbol": "(O)", "color": Color(0.3, 0.5, 1.0), "desc": "SPACE to arm - block one hit"},
}

static func get_name(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["name"]
	return "(type%d)" % t

static func get_symbol(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["symbol"]
	return "?"

static func get_color(type: int) -> Color:
	var t := int(type)
	if META.has(t):
		return META[t]["color"]
	return Color.WHITE

static func get_desc(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["desc"]
	return ""

static func random_type() -> int:
	var types := [Type.SPEED_BOOST, Type.BOMB, Type.SHIELD]
	return types[randi() % types.size()]


class PowerupItem extends Node3D:
	var powerup_id: int = -1
	var powerup_type: int = Type.NONE
	var _base_y: float = 0.45
	var _timer: float = 0.0

	static func create(id: int, type: int, pos: Vector3) -> PowerupItem:
		var item := PowerupItem.new()
		item.powerup_id = id
		item.powerup_type = type
		item.position = Vector3(pos.x, item._base_y, pos.z)

		var color: Color = Powerup.get_color(type)

		# Glowing cylinder
		var mesh_inst := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.25
		cyl.bottom_radius = 0.25
		cyl.height = 0.15
		mesh_inst.mesh = cyl

		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.0
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.85
		mesh_inst.material_override = mat
		item.add_child(mesh_inst)

		# Symbol label
		var label := Label3D.new()
		label.text = Powerup.get_symbol(type)
		label.font_size = 72
		label.position = Vector3(0, 0.12, 0)
		label.rotation_degrees.x = -90
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.modulate = Color(1, 1, 1, 0.95)
		label.outline_size = 8
		label.outline_modulate = Color(0, 0, 0, 0.7)
		item.add_child(label)

		return item

	func _process(delta: float) -> void:
		_timer += delta
		rotation.y = _timer * 2.0
		position.y = _base_y + sin(_timer * 3.0) * 0.08
