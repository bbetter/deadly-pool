extends RefCounted
class_name AimVisuals
## Manages slingshot bands, trajectory dots, and enemy aim line rendering.
## Instantiated by GameManager; RPCs stay on GameManager.

var gm: Node  # GameManager reference

# Sling bands (own ball aiming)
var bands_node: MeshInstance3D
var bands_mesh: ImmediateMesh
var bands_mat: StandardMaterial3D
var dots_node: MeshInstance3D
var dots_mesh: ImmediateMesh
var dots_mat: StandardMaterial3D

# Enemy aim indicators
var enemy_lines: Dictionary = {}   # slot -> MeshInstance3D
var enemy_meshes: Dictionary = {}  # slot -> ImmediateMesh
var enemy_data: Dictionary = {}    # slot -> { "dir": Vector3, "power": float }

var broadcast_timer: float = 0.0
const BROADCAST_INTERVAL := 0.05  # 20Hz aim updates


func _init(game_manager: Node) -> void:
	gm = game_manager


func create(parent: Node3D) -> void:
	# Sling bands (V-shaped rubber bands from ball to drag point)
	bands_mat = StandardMaterial3D.new()
	bands_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bands_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bands_mat.vertex_color_use_as_albedo = true
	bands_mat.no_depth_test = true

	bands_mesh = ImmediateMesh.new()
	bands_node = MeshInstance3D.new()
	bands_node.mesh = bands_mesh
	bands_node.material_override = bands_mat
	bands_node.visible = false
	parent.add_child(bands_node)

	# Trajectory dots (forward direction preview)
	dots_mat = StandardMaterial3D.new()
	dots_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dots_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dots_mat.vertex_color_use_as_albedo = true
	dots_mat.no_depth_test = true

	dots_mesh = ImmediateMesh.new()
	dots_node = MeshInstance3D.new()
	dots_node.mesh = dots_mesh
	dots_node.material_override = dots_mat
	dots_node.visible = false
	parent.add_child(dots_node)


func show() -> void:
	if bands_node:
		bands_node.visible = true
		dots_node.visible = true


func hide() -> void:
	if bands_node:
		bands_node.visible = false
		dots_node.visible = false


# --- Own aim (slingshot + trajectory dots) ---

func update(ball: Node3D, direction: Vector3, power_ratio: float) -> void:
	if bands_node == null:
		return

	if direction.length() < 0.01:
		bands_node.visible = false
		dots_node.visible = false
		return

	var ball_pos := ball.global_position
	var drag_pos: Vector3 = ball.drag_current
	var right := direction.cross(Vector3.UP).normalized()
	var my_slot := NetworkManager.my_slot
	var pcolor: Color = gm.player_colors[my_slot] if my_slot >= 0 and my_slot < gm.player_colors.size() else Color.WHITE

	# --- Sling bands ---
	bands_node.visible = true
	bands_mesh.clear_surfaces()

	var band_y := 0.12
	var left_anchor := ball_pos + right * 0.35 + Vector3(0, band_y, 0)
	var right_anchor := ball_pos - right * 0.35 + Vector3(0, band_y, 0)
	var pull_point: Vector3 = drag_pos + Vector3(0, band_y, 0)

	var band_alpha := lerpf(0.4, 0.95, power_ratio)
	var band_width_anchor := lerpf(0.03, 0.07, power_ratio)
	var band_width_pull := lerpf(0.015, 0.035, power_ratio)
	var band_color := Color(pcolor.r, pcolor.g, pcolor.b, band_alpha)
	var band_color_bright := Color(
		minf(pcolor.r + 0.3, 1.0), minf(pcolor.g + 0.3, 1.0), minf(pcolor.b + 0.3, 1.0),
		band_alpha)

	var _band_anchors: Array[Vector3] = [left_anchor, right_anchor]
	for anchor: Vector3 in _band_anchors:
		var band_vec: Vector3 = pull_point - anchor
		if band_vec.length_squared() < 0.001:
			continue
		bands_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		var band_dir: Vector3 = band_vec.normalized()
		var band_right: Vector3 = band_dir.cross(Vector3.UP).normalized()
		var steps := 6
		for i in (steps + 1):
			var t := float(i) / float(steps)
			var pos: Vector3 = anchor.lerp(pull_point, t)
			var w := lerpf(band_width_anchor, band_width_pull, t)
			var c: Color = band_color_bright.lerp(band_color, t)
			bands_mesh.surface_set_color(c)
			bands_mesh.surface_add_vertex(pos + band_right * w)
			bands_mesh.surface_add_vertex(pos - band_right * w)
		bands_mesh.surface_end()

	# --- Trajectory dots ---
	dots_node.visible = true
	dots_mesh.clear_surfaces()

	var dot_count := 6
	var total_length := (0.8 + power_ratio * 2.0)
	var dot_spacing := total_length / float(dot_count)
	var dot_start := ball_pos + direction * 0.4 + Vector3(0, band_y, 0)
	var dot_color := Color(pcolor.r * 0.5 + 0.5, pcolor.g * 0.5 + 0.5, pcolor.b * 0.5 + 0.5)

	for i in dot_count:
		var t := float(i) / float(dot_count - 1) if dot_count > 1 else 0.0
		var alpha := lerpf(0.7, 0.15, t) * power_ratio
		var dot_size := lerpf(0.06, 0.03, t)
		var center := dot_start + direction * (dot_spacing * i)
		var c := Color(dot_color.r, dot_color.g, dot_color.b, alpha)

		var fwd := direction * dot_size
		var r := right * dot_size
		dots_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		dots_mesh.surface_set_color(c)
		dots_mesh.surface_add_vertex(center - fwd)
		dots_mesh.surface_add_vertex(center + r)
		dots_mesh.surface_add_vertex(center - r)
		dots_mesh.surface_add_vertex(center + fwd)
		dots_mesh.surface_end()


# --- Enemy aim lines ---

func get_or_create_enemy_line(slot: int) -> MeshInstance3D:
	if slot in enemy_lines:
		return enemy_lines[slot]

	var im := ImmediateMesh.new()
	var line := MeshInstance3D.new()
	line.mesh = im
	line.visible = false

	var mat := StandardMaterial3D.new()
	var color: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
	mat.albedo_color = Color(color.r, color.g, color.b, 0.5)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line.material_override = mat

	gm.add_child(line)
	enemy_lines[slot] = line
	enemy_meshes[slot] = im
	return line


func on_aim_received(slot: int, direction: Vector3, power: float) -> void:
	if power < 0.01 or direction.length() < 0.01:
		enemy_data.erase(slot)
	else:
		enemy_data[slot] = {"dir": direction, "power": power}


func update_enemy_lines() -> void:
	var my_slot := NetworkManager.my_slot

	# Hide lines for slots no longer aiming
	for slot: int in enemy_lines:
		if slot not in enemy_data:
			enemy_lines[slot].visible = false

	# Draw lines for enemies currently aiming
	for slot: int in enemy_data:
		if slot == my_slot:
			continue
		if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null or not gm.balls[slot].is_alive:
			continue

		var data: Dictionary = enemy_data[slot]
		var dir: Vector3 = data["dir"]
		var power: float = data["power"]

		var line := get_or_create_enemy_line(slot)
		line.visible = true
		var im: ImmediateMesh = enemy_meshes[slot]

		var ball_pos: Vector3 = gm.balls[slot].global_position
		var start := ball_pos + Vector3(0, 0.05, 0)
		var line_length := 1.0 + power * 3.5
		var end: Vector3 = start + dir * line_length

		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

		var right := dir.cross(Vector3.UP).normalized() * 0.05
		var steps := 8
		for i in (steps + 1):
			var t := float(i) / float(steps)
			var pos: Vector3 = start.lerp(end, t)
			var alpha := 0.5 if fmod(t * steps, 2.0) < 1.0 else 0.2
			im.surface_set_color(Color(1, 1, 1, alpha))
			im.surface_add_vertex(pos + right)
			im.surface_add_vertex(pos - right)

		im.surface_end()
