extends Node3D
class_name ComicBurst
## Comic-book style impact burst. Spawns a starburst effect,
## scales up, then fades out and self-destructs.
## Label3D text removed for web performance.

# Static template — configured once, duplicated per burst (skips 5 property setters + shader lookup)
static var _mat_template: StandardMaterial3D

var _mesh_node: MeshInstance3D
var _mesh: ImmediateMesh
var _timer: float = 0.0
var _lifetime: float = 0.4
var _burst_color: Color = Color.WHITE
var _burst_size: float = 1.0


static func create(pos: Vector3, color: Color, intensity: float) -> ComicBurst:
	# Cap simultaneous bursts — each adds a transparent draw pass on WebGL2
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.get_node_count_in_group("bursts") >= 3:
		return null
	var burst := ComicBurst.new()
	burst.position = pos
	burst._burst_color = color
	burst._burst_size = lerpf(0.5, 2.0, clampf(intensity, 0.0, 1.0))
	# Label3D removed for web performance - text effects are expensive
	burst._lifetime = lerpf(0.3, 0.6, clampf(intensity, 0.0, 1.0))
	burst.add_to_group("bursts")
	return burst


func _ready() -> void:
	if _mat_template == null:
		_mat_template = StandardMaterial3D.new()
		_mat_template.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat_template.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat_template.vertex_color_use_as_albedo = true
		_mat_template.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh = ImmediateMesh.new()
	_mesh_node = MeshInstance3D.new()
	_mesh_node.mesh = _mesh
	# Duplicate per burst so we can fade albedo_color.a independently.
	# MeshInstance3D has no `modulate` (that's CanvasItem/2D only); albedo_color.a
	# multiplies vertex-color alpha so fade works with vertex_color_use_as_albedo = true.
	_mesh_node.material_override = _mat_template.duplicate()
	add_child(_mesh_node)

	_build_starburst()

	# Label3D removed for web performance - text effects are expensive
	# (saves draw calls, font rendering overhead, and memory)


func _build_starburst() -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var spike_count := randi_range(8, 14)
	var inner_r := _burst_size * 0.15
	var outer_r := _burst_size * 0.5

	# Draw on XZ plane (Y=0) so it's visible from the isometric camera
	for i in spike_count:
		var angle := float(i) / float(spike_count) * TAU
		var next_angle := float(i + 1) / float(spike_count) * TAU
		var mid_angle := (angle + next_angle) * 0.5

		var spike_r := outer_r * randf_range(0.7, 1.0)
		var valley_r := inner_r * randf_range(0.8, 1.2)

		# XZ plane: x = cos, z = sin, y = 0
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

	# Quick pop-in, then fade out
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

	# Label3D removed for web performance

	if _timer >= _lifetime:
		queue_free()
