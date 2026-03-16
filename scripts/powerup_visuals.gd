extends RefCounted
class_name PowerupVisuals
## All client-side visual rendering for powerups: HUD panel, portal rings,
## gravity well meshes, swap targeting rings, shockwave/swap effects.
## Extracted from PowerupSystem to separate visual logic from game logic.

var _gm: Node          # GameManager
var _ps: PowerupSystem # Read-only: portal_states, gravity_wells, player_powerups, balls

# Portal visual nodes: slot -> { "blue": Node3D, "orange": Node3D, "blue_arrow": Node3D, "orange_arrow": Node3D }
var _portal_visual_nodes: Dictionary = {}
var _portal_ring: MeshInstance3D = null
var _portal_preview_root: Node3D = null
var _portal_preview_ring: MeshInstance3D = null
var _portal_preview_arrow: Node3D = null
var _portal_preview_yaw: float = 0.0
var _portal_hint_shown: bool = false

# Gravity well and swap ring visuals
var _gravity_well_visual_nodes: Dictionary = {}  # slot -> Node3D
var _swap_highlight_rings: Dictionary = {}         # enemy_slot -> MeshInstance3D
var _swap_target_ring: MeshInstance3D = null

# Powerup HUD panel (bottom-center, shows held powerup)
var hud_panel: PanelContainer
var hud_label: RichTextLabel


func _init(gm_ref: Node, ps_ref: PowerupSystem) -> void:
	_gm = gm_ref
	_ps = ps_ref


func reset() -> void:
	for slot in _portal_visual_nodes:
		_remove_portal_visual_nodes(slot)
	_portal_visual_nodes.clear()
	for slot in _gravity_well_visual_nodes:
		var gw_node: Node3D = _gravity_well_visual_nodes[slot]
		if gw_node != null and is_instance_valid(gw_node):
			gw_node.queue_free()
	_gravity_well_visual_nodes.clear()
	if _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
	_portal_ring = null
	if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
		_portal_preview_root.queue_free()
	_portal_preview_root = null
	_portal_preview_ring = null
	_portal_preview_arrow = null
	_portal_preview_yaw = 0.0
	_portal_hint_shown = false
	_clear_swap_rings()
	update_hud()


# --- Mesh / material factories ---

func _make_emissive_mat(color: Color, alpha: float, emission_mult: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = emission_mult
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _make_torus_ring(inner_r: float, outer_r: float, color: Color, alpha: float,
		emission_mult: float) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner_r
	torus.outer_radius = outer_r
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.material_override = _make_emissive_mat(color, alpha, emission_mult)
	return ring


# --- Portal preview helpers ---

func rotate_portal_preview(step_deg: float) -> void:
	_portal_preview_yaw = wrapf(_portal_preview_yaw + deg_to_rad(step_deg), -PI, PI)


func get_portal_preview_yaw() -> float:
	return _portal_preview_yaw


func _is_valid_cursor_pos(cursor_world_pos: Vector3) -> bool:
	return is_finite(cursor_world_pos.x) and is_finite(cursor_world_pos.z) and abs(cursor_world_pos.x) < 10000.0


func _build_portal_arrow_node(color: Color, alpha: float = 0.95) -> Node3D:
	var root := Node3D.new()
	var shaft := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.5, 0.03, 0.09)
	shaft.mesh = shaft_mesh
	shaft.position = Vector3(0.22, 0.14, 0.0)
	var shaft_mat := _make_emissive_mat(color, alpha, 2.0)
	shaft.material_override = shaft_mat
	root.add_child(shaft)
	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.09
	tip_mesh.height = 0.14
	tip.mesh = tip_mesh
	tip.position = Vector3(0.52, 0.14, 0.0)
	tip.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	tip.material_override = shaft_mat.duplicate()
	root.add_child(tip)
	return root


func _ensure_portal_preview_nodes() -> void:
	if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
		return
	_portal_preview_root = Node3D.new()
	_portal_preview_root.name = "PortalPreview"
	_gm.add_child(_portal_preview_root)
	var det_r: float = GameConfig.portal_trap_detection_radius
	_portal_preview_ring = _make_torus_ring(det_r - 0.12, det_r, Color.WHITE, 0.35, 1.8)
	_portal_preview_ring.rotation_degrees.x = 90.0
	_portal_preview_root.add_child(_portal_preview_ring)
	_portal_preview_arrow = _build_portal_arrow_node(Color.WHITE, 0.75)
	_portal_preview_root.add_child(_portal_preview_arrow)


# --- HUD ---

func create_hud(parent: CanvasLayer) -> void:
	hud_panel = PanelContainer.new()
	hud_panel.anchor_left = 0.5
	hud_panel.anchor_top = 1.0
	hud_panel.anchor_right = 0.5
	hud_panel.anchor_bottom = 1.0
	hud_panel.offset_left = -130
	hud_panel.offset_top = -90
	hud_panel.offset_right = 130
	hud_panel.offset_bottom = -55
	hud_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hud_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.12, 0.8)
	style.border_color = Color(1, 0.85, 0.2, 0.4)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	hud_panel.add_theme_stylebox_override("panel", style)
	hud_panel.visible = false
	hud_label = RichTextLabel.new()
	hud_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_label.bbcode_enabled = true
	hud_label.fit_content = true
	hud_label.add_theme_font_size_override("normal_font_size", 17)
	hud_panel.add_child(hud_label)
	parent.add_child(hud_panel)


func update_hud() -> void:
	if hud_panel == null:
		return
	var my_slot := NetworkManager.my_slot
	if my_slot in _ps.player_powerups:
		var pw: Dictionary = _ps.player_powerups[my_slot]
		var ptype: int = pw.get("type", Powerup.Type.NONE)
		if ptype != Powerup.Type.NONE:
			var color := Powerup.get_color(ptype)
			var armed: bool = pw.get("armed", false)
			if armed:
				hud_label.text = "[color=#%s]%s %s[/color]  [color=#ffcc44]ARMED[/color]" % [
					color.to_html(false), Powerup.get_symbol(ptype), Powerup.get_powerup_name(ptype)]
				var style: StyleBoxFlat = hud_panel.get_theme_stylebox("panel")
				style.border_color = Color(1, 0.85, 0.2, 0.8)
				style.border_width_left = 2
				style.border_width_right = 2
				style.border_width_top = 2
				style.border_width_bottom = 2
			else:
				hud_label.text = "[color=#%s]%s %s[/color]  [color=#999999]SPACE[/color]" % [
					color.to_html(false), Powerup.get_symbol(ptype), Powerup.get_powerup_name(ptype)]
				var style: StyleBoxFlat = hud_panel.get_theme_stylebox("panel")
				style.border_color = Color(1, 0.85, 0.2, 0.4)
				style.border_width_left = 1
				style.border_width_right = 1
				style.border_width_top = 1
				style.border_width_bottom = 1
			hud_panel.visible = true
		else:
			hud_panel.visible = false
	else:
		hud_panel.visible = false


func hide_hud() -> void:
	if hud_panel:
		hud_panel.visible = false


# --- Arm visual ---

func spawn_arm_visual(pos: Vector3, color: Color, use_sphere: bool, duration: float, end_scale: float) -> void:
	if OS.get_name() == "Web":
		return
	var node: MeshInstance3D
	if use_sphere:
		node = MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.5
		m.height = 1.0
		node.mesh = m
		node.material_override = _make_emissive_mat(color, 0.6, 3.0)
	else:
		node = _make_torus_ring(0.1, 0.4, color, 0.6, 3.0)
	node.position = pos
	_gm.add_child(node)
	var tween := _gm.create_tween().set_parallel(true)
	tween.tween_property(node, "scale", Vector3.ONE * end_scale, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(node.material_override, "albedo_color:a", 0.0, duration).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(node.queue_free)


# --- Shockwave ---

func create_shockwave_effect(pos_x: float, pos_z: float) -> void:
	var pos := Vector3(pos_x, 0.5, pos_z)
	ComicBurst.fire(pos, Color(1.0, 0.4, 0.0), 1.0)
	if OS.get_name() == "Web":
		return
	var ring := _make_torus_ring(0.1, 0.3, Color(1.0, 0.5, 0.0), 0.9, 4.0)
	ring.position = Vector3(pos_x, 0.15, pos_z)
	ring.rotation_degrees.x = 90.0
	var ring_mat := ring.material_override as StandardMaterial3D
	_gm.add_child(ring)
	var ring_tween := _gm.create_tween()
	ring_tween.set_parallel(true)
	ring_tween.tween_property(ring, "scale", Vector3(25.0, 25.0, 25.0), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	ring_tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.5).set_ease(Tween.EASE_IN)
	ring_tween.chain().tween_callback(ring.queue_free)
	var flash := MeshInstance3D.new()
	var flash_mesh := SphereMesh.new()
	flash_mesh.radius = 0.5
	flash_mesh.height = 1.0
	flash.mesh = flash_mesh
	var flash_mat := _make_emissive_mat(Color(1.0, 0.8, 0.3), 0.8, 6.0)
	flash_mat.albedo_color = Color(1.0, 0.9, 0.6, 0.8)
	flash.material_override = flash_mat
	flash.position = pos
	_gm.add_child(flash)
	var flash_tween := _gm.create_tween()
	flash_tween.set_parallel(true)
	flash_tween.tween_property(flash, "scale", Vector3(4.0, 4.0, 4.0), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	flash_tween.tween_property(flash_mat, "albedo_color:a", 0.0, 0.3).set_ease(Tween.EASE_IN)
	flash_tween.chain().tween_callback(flash.queue_free)


# --- Gravity well ---

func on_gravity_well_placed(placer_slot: int, pos_x: float, pos_z: float, _duration: float = 0.0) -> void:
	_remove_gravity_well_visual(placer_slot)
	var root := Node3D.new()
	root.position = Vector3(pos_x, 0.08, pos_z)
	root.name = "GravityWell_%d" % placer_slot
	var color := Powerup.get_color(Powerup.Type.GRAVITY_WELL)
	var radius: float = GameConfig.gravity_well_radius
	var ring := _make_torus_ring(radius - 0.12, radius, color, 0.4, 2.2)
	ring.rotation_degrees.x = 90.0
	root.add_child(ring)
	var core := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	core.mesh = sphere
	core.position = Vector3(0.0, 0.22, 0.0)
	core.material_override = _make_emissive_mat(color, 0.7, 3.0)
	root.add_child(core)
	_gm.add_child(root)
	_gravity_well_visual_nodes[placer_slot] = root
	ComicBurst.fire(root.position + Vector3(0.0, 0.25, 0.0), color, 0.55)


func on_gravity_well_expired(placer_slot: int) -> void:
	_remove_gravity_well_visual(placer_slot)


func _remove_gravity_well_visual(slot: int) -> void:
	if slot not in _gravity_well_visual_nodes:
		return
	var node: Node3D = _gravity_well_visual_nodes[slot]
	if node != null and is_instance_valid(node):
		node.queue_free()
	_gravity_well_visual_nodes.erase(slot)


# --- Portal ---

func on_portal_placed(placer_slot: int, portal_idx: int, pos_x: float, pos_z: float, yaw: float = 0.0) -> void:
	var pos := Vector3(pos_x, 0.08, pos_z)
	var color := Color(0.2, 0.6, 1.0) if portal_idx == 0 else Color(1.0, 0.5, 0.05)
	var det_r: float = GameConfig.portal_trap_detection_radius
	var ring_node := _make_torus_ring(det_r - 0.12, det_r, color, 0.85, 3.5)
	ring_node.position = pos
	ring_node.rotation_degrees.x = 90.0
	_gm.add_child(ring_node)
	ComicBurst.fire(pos + Vector3(0, 0.3, 0), color, 0.5)
	if placer_slot not in _portal_visual_nodes:
		_portal_visual_nodes[placer_slot] = {"blue": null, "orange": null, "blue_arrow": null, "orange_arrow": null}
	var key := "blue" if portal_idx == 0 else "orange"
	var arrow_key := "blue_arrow" if portal_idx == 0 else "orange_arrow"
	var old: Node3D = _portal_visual_nodes[placer_slot][key]
	if old != null and is_instance_valid(old):
		old.queue_free()
	_portal_visual_nodes[placer_slot][key] = ring_node
	var old_arrow: Node3D = _portal_visual_nodes[placer_slot][arrow_key]
	if old_arrow != null and is_instance_valid(old_arrow):
		old_arrow.queue_free()
	var arrow_node := _build_portal_arrow_node(color, 0.95)
	arrow_node.position = Vector3(pos.x, 0.0, pos.z)
	arrow_node.rotation.y = yaw
	_gm.add_child(arrow_node)
	_portal_visual_nodes[placer_slot][arrow_key] = arrow_node
	if OS.get_name() != "Web":
		var tween := _gm.create_tween().set_loops()
		tween.tween_property(ring_node, "scale", Vector3(1.12, 1.12, 1.12), 0.6).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(ring_node, "scale", Vector3(1.0, 1.0, 1.0), 0.6).set_ease(Tween.EASE_IN_OUT)


func on_portals_expired(placer_slot: int) -> void:
	_remove_portal_visual_nodes(placer_slot)
	_portal_visual_nodes.erase(placer_slot)
	if placer_slot == NetworkManager.my_slot and _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
		_portal_ring = null


func _remove_portal_visual_nodes(slot: int) -> void:
	if slot not in _portal_visual_nodes:
		return
	for key in ["blue", "orange", "blue_arrow", "orange_arrow"]:
		var node: Node3D = _portal_visual_nodes[slot][key]
		if node != null and is_instance_valid(node):
			node.queue_free()


func on_portal_transit(ball_slot: int, from_x: float, from_z: float, to_x: float, to_z: float) -> void:
	ComicBurst.fire(Vector3(from_x, 0.5, from_z), Color(0.2, 0.6, 1.0), 0.6)
	ComicBurst.fire(Vector3(to_x, 0.5, to_z), Color(1.0, 0.5, 0.05), 0.6)
	if ball_slot >= 0 and ball_slot < _gm.balls.size() and _gm.balls[ball_slot] != null:
		var ball: PoolBall = _gm.balls[ball_slot]
		if ball.ball_mesh:
			var bmat := ball.ball_mesh.get_surface_override_material(0)
			if bmat is StandardMaterial3D:
				var orig: Color = ball.ball_color
				bmat.emission = Color(1.0, 0.5, 0.05)
				bmat.emission_energy_multiplier = 6.0
				var btween := _gm.create_tween()
				btween.tween_interval(0.2)
				btween.tween_callback(func() -> void:
					bmat.emission = orig
					bmat.emission_energy_multiplier = 0.0
				)


# --- Swap ---

func create_swap_effect(slot_a: int, old_ax: float, old_az: float, slot_b: int, old_bx: float, old_bz: float) -> void:
	var swap_color := Powerup.get_color(Powerup.Type.SWAP)
	ComicBurst.fire(Vector3(old_ax, 0.5, old_az), swap_color, 0.7)
	ComicBurst.fire(Vector3(old_bx, 0.5, old_bz), swap_color, 0.7)
	for s in [slot_a, slot_b]:
		if s < 0 or s >= _gm.balls.size() or _gm.balls[s] == null:
			continue
		var ball: PoolBall = _gm.balls[s]
		if ball.ball_mesh:
			var bmat := ball.ball_mesh.get_surface_override_material(0)
			if bmat is StandardMaterial3D:
				var orig: Color = ball.ball_color
				bmat.emission = swap_color
				bmat.emission_energy_multiplier = 6.0
				var btween := _gm.create_tween()
				btween.tween_interval(0.25)
				btween.tween_callback(func() -> void:
					bmat.emission = orig
					bmat.emission_energy_multiplier = 0.0
				)


func _clear_swap_rings() -> void:
	for slot in _swap_highlight_rings:
		var ring = _swap_highlight_rings[slot]
		if ring != null and is_instance_valid(ring):
			ring.queue_free()
	_swap_highlight_rings.clear()
	if _swap_target_ring != null and is_instance_valid(_swap_target_ring):
		_swap_target_ring.queue_free()
	_swap_target_ring = null


func _update_swap_rings(my_ball: PoolBall, cursor_world_pos: Vector3) -> void:
	var swap_color := Powerup.get_color(Powerup.Type.SWAP)
	var snap_sq: float = GameConfig.swap_cursor_snap_radius * GameConfig.swap_cursor_snap_radius
	var target_slot := -1
	var target_dist_sq := INF
	for b in _gm.balls:
		if b == null or not b.is_alive or b == my_ball:
			continue
		var dx: float = b.global_position.x - cursor_world_pos.x
		var dz: float = b.global_position.z - cursor_world_pos.z
		var dist_sq := dx * dx + dz * dz
		if dist_sq < snap_sq and dist_sq < target_dist_sq:
			target_dist_sq = dist_sq
			target_slot = b.slot
	# Remove rings for dead balls
	var to_remove: Array = []
	for slot in _swap_highlight_rings:
		if slot >= _gm.balls.size() or _gm.balls[slot] == null or not _gm.balls[slot].is_alive:
			var ring = _swap_highlight_rings[slot]
			if ring != null and is_instance_valid(ring):
				ring.queue_free()
			to_remove.append(slot)
	for slot in to_remove:
		_swap_highlight_rings.erase(slot)
	# Create/update faint rings for all alive enemies
	for b in _gm.balls:
		if b == null or not b.is_alive or b == my_ball:
			continue
		if b.slot not in _swap_highlight_rings:
			var ring := _make_torus_ring(0.32, 0.45, swap_color, 0.28, 1.0)
			ring.rotation_degrees.x = 90.0
			_gm.add_child(ring)
			_swap_highlight_rings[b.slot] = ring
		var faint_ring: MeshInstance3D = _swap_highlight_rings[b.slot]
		if is_instance_valid(faint_ring):
			faint_ring.position = Vector3(b.global_position.x, 0.06, b.global_position.z)
	# Create/update bright target ring
	if target_slot >= 0 and target_slot < _gm.balls.size() and _gm.balls[target_slot] != null:
		var target_ball: PoolBall = _gm.balls[target_slot]
		if _swap_target_ring == null or not is_instance_valid(_swap_target_ring):
			_swap_target_ring = _make_torus_ring(0.32, 0.45, swap_color, 0.95, 4.5)
			_swap_target_ring.rotation_degrees.x = 90.0
			_gm.add_child(_swap_target_ring)
		_swap_target_ring.visible = true
		_swap_target_ring.position = Vector3(target_ball.global_position.x, 0.07, target_ball.global_position.z)
	else:
		if _swap_target_ring != null and is_instance_valid(_swap_target_ring):
			_swap_target_ring.visible = false


# --- Per-frame update (portal preview + gravity well animation + swap rings) ---

func client_update(delta: float, cursor_world_pos: Vector3 = Vector3.ZERO) -> void:
	# Animate gravity wells
	for slot in _gravity_well_visual_nodes:
		var gw: Node3D = _gravity_well_visual_nodes[slot]
		if gw != null and is_instance_valid(gw):
			gw.rotation.y += delta * 1.6
			gw.position.y = 0.08 + sin(Time.get_ticks_msec() / 180.0 + float(slot)) * 0.015

	var my_slot := NetworkManager.my_slot
	if my_slot < 0 or my_slot >= _gm.balls.size():
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false
		return
	var my_ball: PoolBall = _gm.balls[my_slot]
	if my_ball == null or not my_ball.is_alive:
		if _portal_ring != null and is_instance_valid(_portal_ring):
			_portal_ring.queue_free()
		_portal_ring = null
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false
		_clear_swap_rings()
		return

	if _portal_ring != null and is_instance_valid(_portal_ring):
		_portal_ring.queue_free()
	_portal_ring = null

	# Portal placement preview
	var has_portal := my_ball.held_powerup == Powerup.Type.PORTAL_TRAP
	if has_portal and _is_valid_cursor_pos(cursor_world_pos):
		_ensure_portal_preview_nodes()
		_portal_preview_root.visible = true
		_portal_preview_root.position = Vector3(cursor_world_pos.x, 0.08, cursor_world_pos.z)
		_portal_preview_root.rotation.y = _portal_preview_yaw
		var preview_color := Color(0.2, 0.6, 1.0)
		if my_slot in _portal_visual_nodes:
			var own_visuals: Dictionary = _portal_visual_nodes[my_slot]
			if own_visuals.get("blue", null) != null and own_visuals.get("orange", null) == null:
				preview_color = Color(1.0, 0.5, 0.05)
		if _portal_preview_ring != null and is_instance_valid(_portal_preview_ring):
			var mat: StandardMaterial3D = _portal_preview_ring.material_override
			mat.albedo_color = Color(preview_color.r, preview_color.g, preview_color.b, 0.35)
			mat.emission = preview_color
			mat.emission_energy_multiplier = 1.8
		if _portal_preview_arrow != null and is_instance_valid(_portal_preview_arrow):
			for n in _portal_preview_arrow.get_children():
				if n is MeshInstance3D and (n as MeshInstance3D).material_override is StandardMaterial3D:
					var amat := (n as MeshInstance3D).material_override as StandardMaterial3D
					amat.albedo_color = Color(preview_color.r, preview_color.g, preview_color.b, 0.9)
					amat.emission = preview_color
		if not _portal_hint_shown and _gm.game_hud != null:
			_portal_hint_shown = true
			_gm.game_hud.set_info_text("Portal: scroll or Q/E to rotate facing, SPACE to place", preview_color)
			_gm.get_tree().create_timer(2.5).timeout.connect(func() -> void:
				if is_instance_valid(_gm):
					_gm.reset_hud_info()
			)
	else:
		if _portal_preview_root != null and is_instance_valid(_portal_preview_root):
			_portal_preview_root.visible = false

	# Swap cursor rings
	if my_ball.held_powerup == Powerup.Type.SWAP:
		_update_swap_rings(my_ball, cursor_world_pos)
	else:
		_clear_swap_rings()
