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


const LEG_HEIGHT := 4.5
const LEG_RADIUS := 0.18


func _ready() -> void:
	_create_cushion_walls()
	_setup_table_pockets()
	_create_outer_rail()
	_create_table_legs()
	# Deferred so Main is done setting up its children tree before we add_child to it
	_create_atmosphere.call_deferred()


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


func _create_table_legs() -> void:
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.28, 0.14, 0.05)
	wood_mat.roughness = 0.85

	# Legs — slightly tapered cylinders at the four corners
	var leg_mesh := CylinderMesh.new()
	leg_mesh.top_radius = LEG_RADIUS
	leg_mesh.bottom_radius = LEG_RADIUS * 1.25
	leg_mesh.height = LEG_HEIGHT
	leg_mesh.radial_segments = 10

	var leg_top_y := -0.12
	var leg_center_y := leg_top_y - LEG_HEIGHT / 2.0
	var lx := ARENA_WIDTH / 2.0 - 1.4   # 12.6 — inset from outer rail corners
	var lz := ARENA_HEIGHT / 2.0 - 0.8  # 7.2

	for lp in [Vector3(-lx, leg_center_y, -lz), Vector3(lx, leg_center_y, -lz),
			   Vector3(-lx, leg_center_y,  lz), Vector3(lx, leg_center_y,  lz)]:
		var inst := MeshInstance3D.new()
		inst.mesh = leg_mesh
		inst.position = lp
		inst.set_surface_override_material(0, wood_mat)
		add_child(inst)

	# Apron boards — thin horizontal frames connecting the legs just below the table
	var apron_y := leg_top_y - 0.08
	var apron_h := 0.28
	var apron_t := 0.10

	# Long aprons along X (front + back)
	for sz in [-1.0, 1.0]:
		var bm := BoxMesh.new()
		bm.size = Vector3(lx * 2.0 - LEG_RADIUS * 2.2, apron_h, apron_t)
		var inst := MeshInstance3D.new()
		inst.mesh = bm
		inst.position = Vector3(0, apron_y - apron_h / 2.0, sz * lz)
		inst.set_surface_override_material(0, wood_mat)
		add_child(inst)

	# Short aprons along Z (left + right ends)
	for sx in [-1.0, 1.0]:
		var bm := BoxMesh.new()
		bm.size = Vector3(apron_t, apron_h, lz * 2.0 - LEG_RADIUS * 2.2)
		var inst := MeshInstance3D.new()
		inst.mesh = bm
		inst.position = Vector3(sx * lx, apron_y - apron_h / 2.0, 0)
		inst.set_surface_override_material(0, wood_mat)
		add_child(inst)


func _create_atmosphere() -> void:
	var root := get_parent()

	# Dim directional lights — only if not already dimmed (guard against round-reset re-entry)
	for child in root.get_children():
		if child is DirectionalLight3D and child.light_energy > 0.5:
			child.light_energy *= 0.20

	# Near-black floor — only lit by neon spill
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.05, 0.03, 0.07)
	floor_mat.roughness = 0.95
	var floor_inst := MeshInstance3D.new()
	var floor_plane := PlaneMesh.new()
	floor_plane.size = Vector2(100, 100)
	floor_inst.mesh = floor_plane
	floor_inst.position = Vector3(0, -(LEG_HEIGHT + 0.15), 0)
	floor_inst.set_surface_override_material(0, floor_mat)
	root.add_child(floor_inst)

	# Overhead warm pool lamp
	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0, 14, 0)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.light_color = Color(1.0, 0.88, 0.62)
	lamp.light_energy = 4.5
	lamp.spot_angle = 50.0
	lamp.spot_attenuation = 0.4
	lamp.shadow_enabled = true
	root.add_child(lamp)

	# Neon tube meshes — actual visible glowing geometry on top of the outer rails
	var outer_offset := EDGE_THICKNESS / 2.0 + RAIL_THICKNESS / 2.0
	var half_w := ARENA_WIDTH / 2.0
	var half_h := ARENA_HEIGHT / 2.0
	var tube_y := RAIL_HEIGHT + 0.06
	var tube_r := 0.055
	var long_len := ARENA_WIDTH + (RAIL_THICKNESS + EDGE_THICKNESS) * 2.0
	var short_len := ARENA_HEIGHT + (RAIL_THICKNESS + EDGE_THICKNESS) * 2.0

	var cyan_mat := StandardMaterial3D.new()
	cyan_mat.albedo_color = Color(0.0, 0.9, 1.0)
	cyan_mat.emission_enabled = true
	cyan_mat.emission = Color(0.0, 0.9, 1.0)
	cyan_mat.emission_energy_multiplier = 10.0

	var pink_mat := StandardMaterial3D.new()
	pink_mat.albedo_color = Color(1.0, 0.1, 0.6)
	pink_mat.emission_enabled = true
	pink_mat.emission = Color(1.0, 0.1, 0.6)
	pink_mat.emission_energy_multiplier = 10.0

	var long_tube_mesh := CylinderMesh.new()
	long_tube_mesh.top_radius = tube_r
	long_tube_mesh.bottom_radius = tube_r
	long_tube_mesh.height = long_len
	long_tube_mesh.radial_segments = 8

	var short_tube_mesh := CylinderMesh.new()
	short_tube_mesh.top_radius = tube_r
	short_tube_mesh.bottom_radius = tube_r
	short_tube_mesh.height = short_len
	short_tube_mesh.radial_segments = 8

	# North + South cyan tubes (along X axis)
	for sign_z in [-1, 1]:
		var tube := MeshInstance3D.new()
		tube.mesh = long_tube_mesh
		tube.position = Vector3(0, tube_y, sign_z * (half_h + outer_offset))
		tube.rotation_degrees = Vector3(0, 0, 90)
		tube.set_surface_override_material(0, cyan_mat)
		add_child(tube)

	# East + West pink tubes (along Z axis)
	for sign_x in [-1, 1]:
		var tube := MeshInstance3D.new()
		tube.mesh = short_tube_mesh
		tube.position = Vector3(sign_x * (half_w + outer_offset), tube_y, 0)
		tube.rotation_degrees = Vector3(90, 0, 0)
		tube.set_surface_override_material(0, pink_mat)
		add_child(tube)

	# OmniLights paired with each tube — boosted so they splash color on dark walls
	var neon_lights: Array = [
		[Vector3(0, 0.8, -(half_h + outer_offset)), Color(0.0, 0.9, 1.0), 5.0, 28.0],
		[Vector3(0, 0.8,  (half_h + outer_offset)), Color(0.0, 0.9, 1.0), 5.0, 28.0],
		[Vector3(-(half_w + outer_offset), 0.8, 0), Color(1.0, 0.1, 0.6), 4.0, 22.0],
		[Vector3( (half_w + outer_offset), 0.8, 0), Color(1.0, 0.1, 0.6), 4.0, 22.0],
	]
	for n in neon_lights:
		var light := OmniLight3D.new()
		light.position = n[0]
		light.light_color = n[1]
		light.light_energy = n[2]
		light.omni_range = n[3]
		light.omni_attenuation = 1.5
		root.add_child(light)

	# Room walls — PlaneMesh with normals rotated to face INWARD.
	# CULL_DISABLED and SHADING_MODE_UNSHADED are unreliable in WebGL Compatibility.
	# Instead: warm brown material lit by fill OmniLights from inside the room.
	var room_r := 26.0
	var room_top := 24.0
	var room_d := room_r * 2.0
	var floor_y: float = -(LEG_HEIGHT + 0.15)
	var total_h: float = room_top - floor_y  # extends from floor all the way to ceiling
	var wall_cy: float = floor_y + total_h / 2.0

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.07, 0.05, 0.10)  # near-black with dark purple tint
	wall_mat.roughness = 0.9

	# [pos, rotation_degrees, size]  — normal always points toward room interior
	var walls_data: Array = [
		[Vector3(0,       wall_cy, -room_r), Vector3( 90,   0,   0), Vector2(room_d, total_h)], # north  normal=+Z
		[Vector3(0,       wall_cy,  room_r), Vector3(-90,   0,   0), Vector2(room_d, total_h)], # south  normal=-Z
		[Vector3( room_r, wall_cy,       0), Vector3(  0,   0,  90), Vector2(total_h, room_d)], # east   normal=-X
		[Vector3(-room_r, wall_cy,       0), Vector3(  0,   0, -90), Vector2(total_h, room_d)], # west   normal=+X
		[Vector3(0,       room_top,       0), Vector3(180,   0,   0), Vector2(room_d, room_d)],  # ceiling normal=-Y
	]
	for w in walls_data:
		var plane := PlaneMesh.new()
		plane.size = w[2]
		var inst := MeshInstance3D.new()
		inst.mesh = plane
		inst.position = w[0]
		inst.rotation_degrees = w[1]
		inst.set_surface_override_material(0, wall_mat)
		root.add_child(inst)

	# Neon fill lights — colored spill to keep walls from being totally black
	var fill_lights: Array = [
		[Vector3(-10, 4,  14), Color(1.0, 0.1, 0.6), 1.5, 30.0],  # pink — south/west
		[Vector3( 10, 4, -14), Color(0.0, 0.9, 1.0), 1.5, 30.0],  # cyan — north/east
	]
	for f in fill_lights:
		var fl := OmniLight3D.new()
		fl.position = f[0]
		fl.light_color = f[1]
		fl.light_energy = f[2]
		fl.omni_range = f[3]
		root.add_child(fl)

	# Subtle WorldEnvironment: gentle neon glow + light smoky haze
	var env := Environment.new()
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_strength = 0.8
	env.glow_bloom = 0.10
	env.glow_hdr_threshold = 1.2
	env.glow_hdr_scale = 1.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.fog_enabled = true
	env.fog_density = 0.003
	env.fog_light_color = Color(0.55, 0.40, 0.60)  # muted warm-purple
	env.fog_light_energy = 0.4

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)

	_populate_room(root)


func _populate_room(root: Node3D) -> void:
	var fy := -(LEG_HEIGHT + 0.15)  # floor Y level
	# Scale reference: LEG_HEIGHT=4.5 ≈ 81cm real table legs → 1 unit ≈ 18cm

	var m_dark  := _mat(Color(0.18, 0.09, 0.03), 0.85)
	var m_warm  := _mat(Color(0.42, 0.26, 0.10), 0.80)
	var m_metal := StandardMaterial3D.new()
	m_metal.albedo_color = Color(0.52, 0.52, 0.58)
	m_metal.metallic = 0.80
	m_metal.roughness = 0.30
	var m_seat  := _mat(Color(0.55, 0.10, 0.08), 0.85)  # dark-red vinyl

	# --- Bar counter — east wall ---
	var bx := 22.0
	var b_thick := 1.5       # body depth toward room
	var b_len := 22.0
	var b_h := 6.0           # ~108cm: proper bar counter height
	var b_top := fy + b_h
	# Counter body
	root.add_child(_box_node(Vector3(b_thick, b_h, b_len),
			Vector3(bx, fy + b_h * 0.5, 0), m_dark))
	# Counter top overhang
	root.add_child(_box_node(Vector3(b_thick + 0.8, 0.22, b_len + 0.3),
			Vector3(bx - 0.45, b_top + 0.11, 0), m_warm))
	# Foot rail
	root.add_child(_cyl_node(0.08, 0.08, b_len,
			Vector3(bx - b_thick * 0.5 - 0.15, fy + 2.5, 0), m_metal))
	# Back shelf against east wall
	root.add_child(_box_node(Vector3(0.5, 0.14, b_len * 0.7),
			Vector3(25.2, b_top + 2.5, 0), m_warm))
	# Shelf brackets
	for bsz in [-7.0, 0.0, 7.0]:
		root.add_child(_box_node(Vector3(0.12, 1.8, 0.12),
				Vector3(25.0, b_top + 1.5, bsz), m_dark))
	# Bar warm light
	var blight := OmniLight3D.new()
	blight.position = Vector3(bx - 4.0, b_top + 2.5, 0)
	blight.light_color = Color(1.0, 0.70, 0.35)
	blight.light_energy = 1.8
	blight.omni_range = 22.0
	root.add_child(blight)

	# Bar stools (5) — seat at ~4.8u from floor (~86cm, typical bar stool)
	var stool_x := bx - b_thick * 0.5 - 1.8
	var stool_h := b_h - 1.2
	for i in range(5):
		var sz := -9.0 + i * 4.5
		root.add_child(_cyl_node(0.08, 0.08, stool_h,
				Vector3(stool_x, fy + stool_h * 0.5, sz), m_metal))
		root.add_child(_cyl_node(0.55, 0.55, 0.14,
				Vector3(stool_x, fy + stool_h + 0.07, sz), m_seat))
		root.add_child(_cyl_node(0.40, 0.40, 0.07,
				Vector3(stool_x, fy + stool_h * 0.38, sz), m_metal))

	# --- Small round tables + chairs — west side ---
	# t_h=4.2u (~76cm), chair seat at 2.5u from floor (~45cm)
	var t_h := 4.2
	var chair_dist := 2.6    # table-center to chair-center
	var seat_h_val := 2.5    # chair seat height above floor
	var table_spots: Array = [
		Vector3(-20.5, 0, -9.5),
		Vector3(-21.0, 0,  5.0),
		Vector3(-20.0, 0, 16.5),
	]
	for tp in table_spots:
		var tx: float = tp.x
		var tz: float = tp.z
		var t_top := fy + t_h
		# Pedestal + table top
		root.add_child(_cyl_node(0.15, 0.30, t_h,
				Vector3(tx, fy + t_h * 0.5, tz), m_dark))
		root.add_child(_cyl_node(1.8, 1.8, 0.14,
				Vector3(tx, t_top + 0.07, tz), m_warm))
		# Three chairs: west (toward wall), +z, -z
		var chair_offsets: Array = [
			[-chair_dist, 0.0],
			[0.0,  chair_dist],
			[0.0, -chair_dist],
		]
		for chair_off in chair_offsets:
			var cdx: float = chair_off[0]
			var cdz: float = chair_off[1]
			var cx: float = tx + cdx
			var cz: float = tz + cdz
			var seat_y: float = fy + seat_h_val
			# Seat cushion
			root.add_child(_box_node(Vector3(2.4, 0.22, 2.4),
					Vector3(cx, seat_y + 0.11, cz), m_seat))
			# Chair back on far side from table
			var bk_dx: float = sign(cdx) * 1.1 if cdx != 0.0 else 0.0
			var bk_dz: float = sign(cdz) * 1.1 if cdz != 0.0 else 0.0
			var back_sz := Vector3(0.22, 2.8, 2.4) if cdx != 0.0 else Vector3(2.4, 2.8, 0.22)
			root.add_child(_box_node(back_sz,
					Vector3(cx + bk_dx, seat_y + 1.5, cz + bk_dz), m_dark))
			# 4 legs
			for co in [Vector3(-0.9,0,-0.9), Vector3(0.9,0,-0.9),
					   Vector3(-0.9,0, 0.9), Vector3(0.9,0, 0.9)]:
				root.add_child(_cyl_node(0.08, 0.08, seat_h_val,
						Vector3(cx + co.x, fy + seat_h_val * 0.5, cz + co.z), m_dark, 6))

	# --- Door frame — south wall (z=+26), off-center ---
	# d_h=11.5u (~207cm), d_w=5.5u (~99cm): human-scale door
	var dz := 25.9
	var dcx := 6.0
	var d_w := 5.5
	var d_h := 11.5
	var d_bot := fy
	var d_top := d_bot + d_h
	var m_frame := _mat(Color(0.24, 0.13, 0.05), 0.80)
	var m_door  := _mat(Color(0.30, 0.17, 0.06), 0.75)
	# Side jambs
	root.add_child(_box_node(Vector3(0.4, d_h, 0.4),
			Vector3(dcx - d_w * 0.5 - 0.20, d_bot + d_h * 0.5, dz - 0.20), m_frame))
	root.add_child(_box_node(Vector3(0.4, d_h, 0.4),
			Vector3(dcx + d_w * 0.5 + 0.20, d_bot + d_h * 0.5, dz - 0.20), m_frame))
	# Header
	root.add_child(_box_node(Vector3(d_w + 0.80, 0.4, 0.4),
			Vector3(dcx, d_top + 0.20, dz - 0.20), m_frame))
	# Door panel
	root.add_child(_box_node(Vector3(d_w - 0.12, d_h - 0.12, 0.18),
			Vector3(dcx, d_bot + d_h * 0.5, dz - 0.09), m_door))
	# Light over door
	var dl := OmniLight3D.new()
	dl.position = Vector3(dcx, d_top + 1.5, dz - 3.0)
	dl.light_color = Color(1.0, 0.80, 0.50)
	dl.light_energy = 1.0
	dl.omni_range = 9.0
	root.add_child(dl)

	# --- Neon signs — north wall (z=-26) ---
	# sign_y=7.0 → 11.65u above floor (~210cm): good wall sign height
	var nz := -25.85
	var sign_y := 7.0
	root.add_child(_box_node(Vector3(5.5, 2.0, 0.12), Vector3(-8.5, sign_y, nz),
			_mat_em(Color(0.0, 0.95, 1.0), Color(0.0, 0.95, 1.0), 3.5)))
	root.add_child(_box_node(Vector3(7.5, 2.0, 0.12), Vector3(7.5, sign_y + 0.5, nz),
			_mat_em(Color(1.0, 0.10, 0.6), Color(1.0, 0.10, 0.6), 3.5)))
	# Glow lights for signs
	for sl_data in [
		[Vector3(-8.5, sign_y, nz + 2.5), Color(0.0, 0.95, 1.0)],
		[Vector3( 7.5, sign_y + 0.5, nz + 2.5), Color(1.0, 0.10, 0.6)],
	]:
		var sl := OmniLight3D.new()
		sl.position = sl_data[0]
		sl.light_color = sl_data[1]
		sl.light_energy = 1.0
		sl.omni_range = 14.0
		root.add_child(sl)


func _mat(col: Color, rough: float = 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


func _mat_em(col: Color, em: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = em
	m.emission_energy_multiplier = energy
	return m


func _box_node(sz: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = sz
	var inst := MeshInstance3D.new()
	inst.mesh = bm
	inst.position = pos
	inst.set_surface_override_material(0, mat)
	return inst


func _cyl_node(r_top: float, r_bot: float, h: float, pos: Vector3,
		mat: StandardMaterial3D, segs: int = 10) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = segs
	var inst := MeshInstance3D.new()
	inst.mesh = cm
	inst.position = pos
	inst.set_surface_override_material(0, mat)
	return inst
