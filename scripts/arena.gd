extends StaticBody3D

const ARENA_WIDTH := 28.0   # Long axis (X)
const ARENA_HEIGHT := 16.0  # Short axis (Z)
const EDGE_HEIGHT := 0.6
const EDGE_THICKNESS := 0.4
const RAIL_HEIGHT := 0.15
const RAIL_THICKNESS := 0.5

# Pocket dimensions (billiard-style: 4 corners + 2 mid-side)
const CORNER_POCKET_RADIUS := 1.0
const MID_POCKET_RADIUS := 0.85
# How far walls stop short of corners to leave pocket openings
const CORNER_GAP := 1.5
# Half-width of mid-pocket opening in the wall
const MID_GAP := 0.6
# Thin border ring drawn around each pocket hole (in shader units)
const POCKET_BORDER := 0.13

var pocket_positions: Array[Vector3] = []


func _ready() -> void:
	_create_cushion_walls()
	_setup_table_pockets()
	_create_outer_rail()


func get_pocket_positions() -> Array[Vector3]:
	return pocket_positions


func _create_cushion_walls() -> void:
	var half_w := ARENA_WIDTH / 2.0   # 14.0 — long axis (X)
	var half_h := ARENA_HEIGHT / 2.0  # 8.0  — short axis (Z)

	var cushion_mat := StandardMaterial3D.new()
	cushion_mat.albedo_color = Color(0.15, 0.45, 0.2)
	cushion_mat.roughness = 0.7

	# North/South walls (z = ±half_h): long walls, split by mid pocket at x=0
	var ns_seg1_start := -(half_w - CORNER_GAP)
	var ns_seg1_end := -MID_GAP
	var ns_seg1_len := ns_seg1_end - ns_seg1_start
	var ns_seg1_center := (ns_seg1_start + ns_seg1_end) / 2.0

	var ns_seg2_start := MID_GAP
	var ns_seg2_end := half_w - CORNER_GAP
	var ns_seg2_len := ns_seg2_end - ns_seg2_start
	var ns_seg2_center := (ns_seg2_start + ns_seg2_end) / 2.0

	# East/West walls (x = ±half_w): short walls, no mid pocket
	var ew_seg_start := -(half_h - CORNER_GAP)
	var ew_seg_end := half_h - CORNER_GAP
	var ew_seg_len := ew_seg_end - ew_seg_start
	var ew_seg_center := (ew_seg_start + ew_seg_end) / 2.0

	# All wall segments as [position, size] pairs
	var segments: Array = [
		[Vector3(ns_seg1_center, EDGE_HEIGHT / 2.0, -half_h), Vector3(ns_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(ns_seg2_center, EDGE_HEIGHT / 2.0, -half_h), Vector3(ns_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(ns_seg1_center, EDGE_HEIGHT / 2.0,  half_h), Vector3(ns_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(ns_seg2_center, EDGE_HEIGHT / 2.0,  half_h), Vector3(ns_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3( half_w, EDGE_HEIGHT / 2.0, ew_seg_center), Vector3(EDGE_THICKNESS, EDGE_HEIGHT, ew_seg_len)],
		[Vector3(-half_w, EDGE_HEIGHT / 2.0, ew_seg_center), Vector3(EDGE_THICKNESS, EDGE_HEIGHT, ew_seg_len)],
	]

	# Merge all wall visuals into one draw call
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for seg in segments:
		var box := BoxMesh.new()
		box.size = seg[1]
		st.append_from(box, 0, Transform3D(Basis(), seg[0]))

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = st.commit()
	mesh_inst.set_surface_override_material(0, cushion_mat)
	add_child(mesh_inst)

	# Physics stays separate — one StaticBody3D per segment
	for seg in segments:
		_add_wall_collision(seg[0], seg[1])


func _add_wall_collision(pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	$EdgeWalls.add_child(body)



func _setup_table_pockets() -> void:
	var half_w := ARENA_WIDTH / 2.0
	var half_h := ARENA_HEIGHT / 2.0

	pocket_positions = [
		Vector3(-half_w, 0, -half_h),  # top-left corner
		Vector3( half_w, 0, -half_h),  # top-right corner
		Vector3(-half_w, 0,  half_h),  # bottom-left corner
		Vector3( half_w, 0,  half_h),  # bottom-right corner
		Vector3(0, 0, -half_h),        # north mid-side
		Vector3(0, 0,  half_h),        # south mid-side
	]

	# Shader discards fragments inside each pocket circle (true hole in the cloth)
	# and draws a thin border ring around each opening. No extra meshes needed.
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform vec4 felt_color : source_color = vec4(0.1, 0.35, 0.15, 1.0);
uniform vec4 border_color : source_color = vec4(0.25, 0.13, 0.04, 1.0);
uniform float corner_radius = 1.0;
uniform float mid_radius = 0.85;
uniform float border_width = 0.13;

varying vec2 tpos;

void vertex() {
	tpos = VERTEX.xz;
}

void fragment() {
	float d = 1e9;
	d = min(d, length(tpos - vec2(-14.0, -8.0)) - corner_radius);
	d = min(d, length(tpos - vec2( 14.0, -8.0)) - corner_radius);
	d = min(d, length(tpos - vec2(-14.0,  8.0)) - corner_radius);
	d = min(d, length(tpos - vec2( 14.0,  8.0)) - corner_radius);
	d = min(d, length(tpos - vec2(  0.0, -8.0)) - mid_radius);
	d = min(d, length(tpos - vec2(  0.0,  8.0)) - mid_radius);

	if (d < 0.0) {
		discard;
	} else if (d < border_width) {
		ALBEDO = border_color.rgb;
		ROUGHNESS = 0.85;
	} else {
		ALBEDO = felt_color.rgb;
		ROUGHNESS = 0.9;
	}
}
"""

	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("corner_radius", CORNER_POCKET_RADIUS)
	mat.set_shader_parameter("mid_radius", MID_POCKET_RADIUS)
	mat.set_shader_parameter("border_width", POCKET_BORDER)

	var arena_mesh := $ArenaMesh as MeshInstance3D
	arena_mesh.set_surface_override_material(0, mat)


func _create_outer_rail() -> void:
	var half_w := ARENA_WIDTH / 2.0
	var half_h := ARENA_HEIGHT / 2.0
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.35, 0.2, 0.1)
	rail_mat.roughness = 0.5
	rail_mat.metallic = 0.1

	var outer_offset := EDGE_THICKNESS / 2.0 + RAIL_THICKNESS / 2.0
	var rail_x_w := ARENA_WIDTH + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS
	var rail_z_w := ARENA_HEIGHT + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS

	var rails: Array = [
		[Vector3(0, RAIL_HEIGHT / 2.0, -(half_h + outer_offset)), Vector3(rail_x_w, RAIL_HEIGHT, RAIL_THICKNESS)],
		[Vector3(0, RAIL_HEIGHT / 2.0,   half_h + outer_offset),  Vector3(rail_x_w, RAIL_HEIGHT, RAIL_THICKNESS)],
		[Vector3( half_w + outer_offset, RAIL_HEIGHT / 2.0, 0), Vector3(RAIL_THICKNESS, RAIL_HEIGHT, rail_z_w)],
		[Vector3(-(half_w + outer_offset), RAIL_HEIGHT / 2.0, 0), Vector3(RAIL_THICKNESS, RAIL_HEIGHT, rail_z_w)],
	]

	# Merge all rails into one draw call
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rail in rails:
		var box := BoxMesh.new()
		box.size = rail[1]
		st.append_from(box, 0, Transform3D(Basis(), rail[0]))

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = st.commit()
	mesh_inst.set_surface_override_material(0, rail_mat)
	add_child(mesh_inst)
