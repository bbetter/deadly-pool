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

# Pocket center positions (XZ plane)
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

	# North wall (z = -half): 2 segments with corner gaps + mid-pocket gap
	# Segment 1: from x = -(half - CORNER_GAP) to x = -MID_GAP
	var n_seg1_start := -(half - CORNER_GAP)
	var n_seg1_end := -MID_GAP
	var n_seg1_len := n_seg1_end - n_seg1_start
	var n_seg1_center := (n_seg1_start + n_seg1_end) / 2.0
	_add_wall_segment(Vector3(n_seg1_center, EDGE_HEIGHT / 2.0, -half),
		Vector3(n_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS), cushion_mat)

	# Segment 2: from x = MID_GAP to x = (half - CORNER_GAP)
	var n_seg2_start := MID_GAP
	var n_seg2_end := half - CORNER_GAP
	var n_seg2_len := n_seg2_end - n_seg2_start
	var n_seg2_center := (n_seg2_start + n_seg2_end) / 2.0
	_add_wall_segment(Vector3(n_seg2_center, EDGE_HEIGHT / 2.0, -half),
		Vector3(n_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS), cushion_mat)

	# South wall (z = +half): same pattern
	_add_wall_segment(Vector3(n_seg1_center, EDGE_HEIGHT / 2.0, half),
		Vector3(n_seg1_len, EDGE_HEIGHT, EDGE_THICKNESS), cushion_mat)
	_add_wall_segment(Vector3(n_seg2_center, EDGE_HEIGHT / 2.0, half),
		Vector3(n_seg2_len, EDGE_HEIGHT, EDGE_THICKNESS), cushion_mat)

	# East wall (x = +half): 1 segment, corner gaps only (no mid-pocket)
	var e_seg_start := -(half - CORNER_GAP)
	var e_seg_end := half - CORNER_GAP
	var e_seg_len := e_seg_end - e_seg_start
	var e_seg_center := (e_seg_start + e_seg_end) / 2.0
	_add_wall_segment(Vector3(half, EDGE_HEIGHT / 2.0, e_seg_center),
		Vector3(EDGE_THICKNESS, EDGE_HEIGHT, e_seg_len), cushion_mat)

	# West wall (x = -half): same as East
	_add_wall_segment(Vector3(-half, EDGE_HEIGHT / 2.0, e_seg_center),
		Vector3(EDGE_THICKNESS, EDGE_HEIGHT, e_seg_len), cushion_mat)


func _add_wall_segment(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var body := StaticBody3D.new()
	body.position = pos

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh
	mesh_inst.set_surface_override_material(0, mat)
	body.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	$EdgeWalls.add_child(body)


func _create_pocket_visuals() -> void:
	var half := ARENA_SIZE / 2.0

	# Pocket positions: 4 corners + 2 mid-sides
	pocket_positions = [
		Vector3(-half, 0, -half),  # top-left corner
		Vector3(half, 0, -half),   # top-right corner
		Vector3(-half, 0, half),   # bottom-left corner
		Vector3(half, 0, half),    # bottom-right corner
		Vector3(0, 0, -half),      # north mid-side
		Vector3(0, 0, half),       # south mid-side
	]

	var pocket_mat := StandardMaterial3D.new()
	pocket_mat.albedo_color = Color(0.02, 0.02, 0.02)
	pocket_mat.roughness = 1.0

	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.25, 0.15, 0.08)
	rim_mat.roughness = 0.6
	rim_mat.metallic = 0.2

	for i in pocket_positions.size():
		var pos := pocket_positions[i]
		var is_corner := i < 4
		var radius: float = CORNER_POCKET_RADIUS if is_corner else MID_POCKET_RADIUS

		# Dark pocket hole (flat disc slightly above table surface)
		var hole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = 0.02
		cyl.radial_segments = 24
		hole.mesh = cyl
		hole.set_surface_override_material(0, pocket_mat)
		hole.position = Vector3(pos.x, 0.011, pos.z)
		add_child(hole)

		# Pocket rim ring (slightly larger, slightly raised)
		var rim := MeshInstance3D.new()
		var rim_cyl := CylinderMesh.new()
		rim_cyl.top_radius = radius + 0.15
		rim_cyl.bottom_radius = radius + 0.15
		rim_cyl.height = 0.03
		rim_cyl.radial_segments = 24
		rim.mesh = rim_cyl
		rim.set_surface_override_material(0, rim_mat)
		rim.position = Vector3(pos.x, 0.005, pos.z)
		add_child(rim)

		# Inner dark ring (the "throat" of the pocket, slightly smaller)
		var inner := MeshInstance3D.new()
		var inner_cyl := CylinderMesh.new()
		inner_cyl.top_radius = radius * 0.7
		inner_cyl.bottom_radius = radius * 0.7
		inner_cyl.height = 0.025
		inner_cyl.radial_segments = 24
		inner.mesh = inner_cyl
		inner.set_surface_override_material(0, pocket_mat)
		inner.position = Vector3(pos.x, 0.012, pos.z)
		add_child(inner)


func _create_outer_rail() -> void:
	# Decorative outer rail frame around the table
	var half := ARENA_SIZE / 2.0
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.35, 0.2, 0.1)
	rail_mat.roughness = 0.5
	rail_mat.metallic = 0.1

	var outer_offset := EDGE_THICKNESS / 2.0 + RAIL_THICKNESS / 2.0

	# North rail
	_add_rail(Vector3(0, RAIL_HEIGHT / 2.0, -(half + outer_offset)),
		Vector3(ARENA_SIZE + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS, RAIL_HEIGHT, RAIL_THICKNESS), rail_mat)
	# South rail
	_add_rail(Vector3(0, RAIL_HEIGHT / 2.0, half + outer_offset),
		Vector3(ARENA_SIZE + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS, RAIL_HEIGHT, RAIL_THICKNESS), rail_mat)
	# East rail
	_add_rail(Vector3(half + outer_offset, RAIL_HEIGHT / 2.0, 0),
		Vector3(RAIL_THICKNESS, RAIL_HEIGHT, ARENA_SIZE + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS), rail_mat)
	# West rail
	_add_rail(Vector3(-(half + outer_offset), RAIL_HEIGHT / 2.0, 0),
		Vector3(RAIL_THICKNESS, RAIL_HEIGHT, ARENA_SIZE + RAIL_THICKNESS * 2.0 + EDGE_THICKNESS), rail_mat)


func _add_rail(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh
	mesh_inst.set_surface_override_material(0, mat)
	mesh_inst.position = pos
	add_child(mesh_inst)
