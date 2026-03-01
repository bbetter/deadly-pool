extends Node3D
class_name ComicBurst
## Comic-book style impact burst. Uses a static pool of 3 pre-created nodes
## that are activated/deactivated rather than created/destroyed each time.
## This avoids WebGL VBO alloc/dealloc cycles that cause JS GC pauses on web.

static var _mat_template: StandardMaterial3D
static var _pool: Array = []  # Array[ComicBurst] — untyped to avoid WASM typed-array issues

var _mesh_node: MeshInstance3D
var _mesh: ImmediateMesh
var _timer: float = 0.0
var _lifetime: float = 0.4
var _burst_color: Color = Color.WHITE
var _burst_size: float = 1.0
var _active: bool = false


static func init_pool(parent: Node) -> void:
	if _pool.size() > 0:
		return
	if _mat_template == null:
		_mat_template = StandardMaterial3D.new()
		_mat_template.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat_template.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat_template.vertex_color_use_as_albedo = true
		_mat_template.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 8:
		var b := ComicBurst.new()
		parent.add_child(b)
		_pool.append(b)


static func fire(pos: Vector3, color: Color, intensity: float) -> void:
	for burst in _pool:
		if not burst._active:
			burst._activate(pos, color, intensity)
			return
	# All 8 slots busy — skip this burst


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	_mesh_node = MeshInstance3D.new()
	_mesh_node.mesh = _mesh
	_mesh_node.material_override = _mat_template.duplicate()
	add_child(_mesh_node)
	visible = false
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_pool.erase(self)


func _activate(pos: Vector3, color: Color, intensity: float) -> void:
	_active = true
	position = pos
	_burst_color = color
	_burst_size = lerpf(0.5, 2.0, clampf(intensity, 0.0, 1.0))
	_lifetime = lerpf(0.3, 0.6, clampf(intensity, 0.0, 1.0))
	_timer = 0.0
	scale = Vector3.ONE
	visible = true
	if OS.get_name() != "Web":
		add_to_group("bursts")
	_build_starburst()
	set_process(true)


func _deactivate() -> void:
	_active = false
	visible = false
	if OS.get_name() != "Web":
		remove_from_group("bursts")
	set_process(false)


func _build_starburst() -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var spike_count := randi_range(8, 14)
	var inner_r := _burst_size * 0.15
	var outer_r := _burst_size * 0.5

	for i in spike_count:
		var angle := float(i) / float(spike_count) * TAU
		var next_angle := float(i + 1) / float(spike_count) * TAU
		var mid_angle := (angle + next_angle) * 0.5

		var spike_r := outer_r * randf_range(0.7, 1.0)
		var valley_r := inner_r * randf_range(0.8, 1.2)

		var spike_pt := Vector3(cos(mid_angle) * spike_r, 0, sin(mid_angle) * spike_r)
		var left_pt := Vector3(cos(angle) * valley_r, 0, sin(angle) * valley_r)
		var right_pt := Vector3(cos(next_angle) * valley_r, 0, sin(next_angle) * valley_r)

		var center_color := Color(
			minf(_burst_color.r + 0.5, 1.0),
			minf(_burst_color.g + 0.5, 1.0),
			minf(_burst_color.b + 0.5, 1.0),
			0.95)
		var edge_color := Color(_burst_color.r, _burst_color.g, _burst_color.b, 0.85)

		_mesh.surface_set_color(center_color)
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_set_color(edge_color)
		_mesh.surface_add_vertex(left_pt)
		_mesh.surface_set_color(edge_color)
		_mesh.surface_add_vertex(spike_pt)

		_mesh.surface_set_color(center_color)
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_set_color(edge_color)
		_mesh.surface_add_vertex(spike_pt)
		_mesh.surface_set_color(edge_color)
		_mesh.surface_add_vertex(right_pt)

	_mesh.surface_end()


func _process(delta: float) -> void:
	_timer += delta
	var t := clampf(_timer / _lifetime, 0.0, 1.0)

	var scale_curve: float
	if t < 0.15:
		scale_curve = lerpf(0.0, 1.4, t / 0.15)
	elif t < 0.3:
		scale_curve = lerpf(1.4, 1.0, (t - 0.15) / 0.15)
	else:
		scale_curve = lerpf(1.0, 0.2, (t - 0.3) / 0.7)

	scale = Vector3.ONE * scale_curve

	var alpha := 1.0 if t < 0.25 else lerpf(1.0, 0.0, (t - 0.25) / 0.75)
	(_mesh_node.material_override as StandardMaterial3D).albedo_color.a = alpha

	if _timer >= _lifetime:
		_deactivate()
