extends Node3D
class_name ComicBurst
## Comic-book style impact burst. Spawns a starburst + optional text,
## scales up, then fades out and self-destructs.

var _mesh_node: MeshInstance3D
var _mesh: ImmediateMesh
var _mat: StandardMaterial3D
var _label: Label3D
var _timer: float = 0.0
var _lifetime: float = 0.4
var _burst_color: Color = Color.WHITE
var _burst_size: float = 1.0
var _show_text: bool = true

const IMPACT_WORDS: Array[String] = ["POW", "BAM", "WHAM", "CRACK", "BANG", "SMACK"]


static func create(pos: Vector3, color: Color, intensity: float, with_text: bool = true) -> ComicBurst:
	var burst := ComicBurst.new()
	burst.position = pos
	burst._burst_color = color
	burst._burst_size = lerpf(0.5, 2.0, clampf(intensity, 0.0, 1.0))
	burst._show_text = with_text
	burst._lifetime = lerpf(0.3, 0.6, clampf(intensity, 0.0, 1.0))
	return burst


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.vertex_color_use_as_albedo = true
	_mat.no_depth_test = true
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_mesh = ImmediateMesh.new()
	_mesh_node = MeshInstance3D.new()
	_mesh_node.mesh = _mesh
	_mesh_node.material_override = _mat
	add_child(_mesh_node)

	_build_starburst()

	if _show_text:
		_label = Label3D.new()
		_label.text = IMPACT_WORDS[randi() % IMPACT_WORDS.size()]
		_label.font_size = int(lerpf(64, 128, clampf(_burst_size / 2.0, 0.0, 1.0)))
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.shaded = false
		_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
		_label.outline_modulate = Color(
			_burst_color.r * 0.3, _burst_color.g * 0.3, _burst_color.b * 0.3, 1.0)
		_label.outline_size = 16
		_label.position = Vector3(0, 0.5, 0)
		_label.scale = Vector3.ZERO
		add_child(_label)


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
	_mat.albedo_color = Color(1, 1, 1, alpha)

	if _label:
		var text_t := clampf((_timer - 0.02) / (_lifetime - 0.02), 0.0, 1.0)
		var text_scale: float
		if text_t < 0.12:
			text_scale = lerpf(0.0, 1.5, text_t / 0.12)
		elif text_t < 0.25:
			text_scale = lerpf(1.5, 1.0, (text_t - 0.12) / 0.13)
		else:
			text_scale = lerpf(1.0, 0.4, (text_t - 0.25) / 0.75)
		_label.scale = Vector3.ONE * text_scale * 0.015
		_label.modulate.a = alpha

	if _timer >= _lifetime:
		queue_free()
