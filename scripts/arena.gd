extends StaticBody3D

const ARENA_SIZE := 20.0
const EDGE_HEIGHT := 0.6
const EDGE_THICKNESS := 0.4
const RAIL_HEIGHT := 0.15
const RAIL_THICKNESS := 0.5

# Pocket dimensions (billiard-style: 4 corners + 2 mid-side)
const CORNER_POCKET_RADIUS := 1.3
const MID_POCKET_RADIUS := 1.0
# How far walls stop short of corners to leave pocket openings
const CORNER_GAP := 1.5
# Half-width of mid-pocket opening in the wall
const MID_GAP := 0.6

# Reduced from 24 — saves triangle count, imperceptible at game camera distance
const POCKET_SEGMENTS := 16

var pocket_positions: Array[Vector3] = []


func _ready() -> void:
	_create_cushion_walls()
	_create_pocket_visuals()
	_create_outer_rail()


func get_pocket_positions() -> Array[Vector3]:
	return pocket_positions


func _create_cushion_walls() -> void:
	var half := ARENA_SIZE / 2.0

	var cushion_mat := StandardMaterial3D.new()
	cushion_mat.albedo_color = Color(0.15, 0.45, 0.2)
	cushion_mat.roughness = 0.7

	var n_seg1_start := -(half - CORNER_GAP)
	var n_seg1_end := -MID_GAP
	var n_seg1_len := n_seg1_end - n_seg1_start
	var n_seg1_center := (n_seg1_start + n_seg1_end) / 2.0

	var n_seg2_start := MID_GAP
	var n_seg2_end := half - CORNER_GAP
	var n_seg2_len := n_seg2_end - n_seg2_start
	var n_seg2_center := (n_seg2_start + n_seg2_end) / 2.0

	var e_seg_start := -(half - CORNER_GAP)
	var e_seg_end := half - CORNER_GAP
	var e_seg_len := e_seg_end - e_seg_start
	var e_seg_center := (e_seg_start + e_seg_end) / 2.0

	# All wall segments as [position, size] pairs
	var segments: Array = [
		[Vector3(n_seg1_center, EDGE_HEIGHT / 2.0, -half), Vector3(n_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(n_seg2_center, EDGE_HEIGHT / 2.0, -half), Vector3(n_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(n_seg1_center, EDGE_HEIGHT / 2.0,  half), Vector3(n_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3(n_seg2_center, EDGE_HEIGHT / 2.0,  half), Vector3(n_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS)],
		[Vector3( half, EDGE_HEIGHT / 2.0, e_seg_center), Vector3(EDGE_THICKNESS, EDGE_HEIGHT, e_seg_len)],
		[Vector3(-half, EDGE_HEIGHT / 2.0, e_seg_center), Vector3(EDGE_THICKNESS, EDGE_HEIGHT, e_seg_len)],
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


func _create_pocket_visuals() -> void:
	var half := ARENA_SIZE / 2.0

	pocket_positions = [
		Vector3(-half, 0, -half),  # top-left corner
		Vector3( half, 0, -half),  # top-right corner
		Vector3(-half, 0,  half),  # bottom-left corner
		Vector3( half, 0,  half),  # bottom-right corner
		Vector3(0, 0, -half),      # north mid-side
		Vector3(0, 0,  half),      # south mid-side
	]

	var pocket_mat := StandardMaterial3D.new()
	pocket_mat.albedo_color = Color(0.02, 0.02, 0.02)
	pocket_mat.roughness = 1.0

	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.25, 0.15, 0.08)
	rim_mat.roughness = 0.6
	rim_mat.metallic = 0.2

	# Merge all pocket dark surfaces (holes + inner rings) into one draw call
	var st_pocket := SurfaceTool.new()
	st_pocket.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Merge all rim surfaces into one draw call
	var st_rim := SurfaceTool.new()
	st_rim.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in pocket_positions.size():
		var pos := pocket_positions[i]
		var is_corner := i < 4
		var radius: float = CORNER_POCKET_RADIUS if is_corner else MID_POCKET_RADIUS

		var hole_cyl := CylinderMesh.new()
		hole_cyl.top_radius = radius
		hole_cyl.bottom_radius = radius
		hole_cyl.height = 0.02
		hole_cyl.radial_segments = POCKET_SEGMENTS
		st_pocket.append_from(hole_cyl, 0, Transform3D(Basis(), Vector3(pos.x, 0.011, pos.z)))

		var inner_cyl := CylinderMesh.new()
		inner_cyl.top_radius = radius * 0.7
		inner_cyl.bottom_radius = radius * 0.7
		inner_cyl.height = 0.025
		inner_cyl.radial_segments = POCKET_SEGMENTS
		st_pocket.append_from(inner_cyl, 0, Transform3D(Basis(), Vector3(pos.x, 0.012, pos.z)))

		var rim_cyl := CylinderMesh.new()
		rim_cyl.top_radius = radius + 0.15
		rim_cyl.bottom_radius = radius + 0.15
		rim_cyl.height = 0.03
		rim_cyl.radial_segments = POCKET_SEGMENTS
		st_rim.append_from(rim_cyl, 0, Transform3D(Basis(), Vector3(pos.x, 0.005, pos.z)))

	var pocket_inst := MeshInstance3D.new()
	pocket_inst.mesh = st_pocket.commit()
	pocket_inst.set_surface_override_material(0, pocket_mat)
	add_child(pocket_inst)

	var rim_inst := MeshInstance3D.new()
	rim_inst.mesh = st_rim.commit()
	rim_inst.set_surface_override_material(0, rim_mat)
	add_child(rim_inst)


func _create_outer_rail() -> void:
	var half := ARENA_SIZE / 2.0
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.35, 0.2, 0.1)
	rail_mat.roughness = 0.5
	rail_mat.metallic = 0.1

	var outer_offset := EDGE_THICKNESS / 2.0 + RAIL_THICKNESS / 2.0
	var rail_w := ARENA_SIZE + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS

	var rails: Array = [
		[Vector3(0, RAIL_HEIGHT / 2.0, -(half + outer_offset)), Vector3(rail_w, RAIL_HEIGHT, RAIL_THICKNESS)],
		[Vector3(0, RAIL_HEIGHT / 2.0,   half + outer_offset),  Vector3(rail_w, RAIL_HEIGHT, RAIL_THICKNESS)],
		[Vector3( half + outer_offset, RAIL_HEIGHT / 2.0, 0), Vector3(RAIL_THICKNESS, RAIL_HEIGHT, rail_w)],
		[Vector3(-(half + outer_offset), RAIL_HEIGHT / 2.0, 0), Vector3(RAIL_THICKNESS, RAIL_HEIGHT, rail_w)],
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
