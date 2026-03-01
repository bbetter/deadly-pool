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

# Enemy aim indicators.
# All enemy lines share ONE ImmediateMesh so there is only ever 1 clear_surfaces/surface_end
# per rebuild cycle (= 1 gl.createBuffer/deleteBuffer) regardless of how many bots/enemies.
# Previously each slot had its own ImmediateMesh, so a 5-bot game produced 5 GL buffer
# pairs per rebuild — causing synchronized GC pauses on all clients after bot eliminations.
var all_enemy_node: MeshInstance3D
var all_enemy_mesh: ImmediateMesh
var enemy_data: Dictionary = {}          # slot -> { "dir": Vector3, "power": float }
var _enemy_dirty: bool = false           # true when any aim RPC arrived since last rebuild

# Table half-dimensions for trajectory bounce simulation (must match arena.gd ARENA_WIDTH/HEIGHT / 2)
var table_half_x: float = 14.0
var table_half_z: float = 8.0

var broadcast_timer: float = 0.0
const BROADCAST_INTERVAL := 0.05  # 20Hz aim updates

# Rate-limit the batch mesh rebuild on web to ~30Hz.
# ImmediateMesh clear_surfaces+surface_end = gl.deleteBuffer+createBuffer on each call.
var _web_rebuild_ms: int = 0
const _WEB_REBUILD_INTERVAL_MS := 33  # ~30Hz

# Spike-report counters — incremented on each actual GL rebuild, read+reset by GameManager
var rebuild_count_own:   int = 0
var rebuild_count_enemy: int = 0


func _init(game_manager: Node) -> void:
	gm = game_manager


func create(parent: Node3D) -> void:
	# Sling bands (V-shaped rubber bands from ball to drag point)
	bands_mat = StandardMaterial3D.new()
	bands_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bands_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bands_mat.vertex_color_use_as_albedo = true

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

	dots_mesh = ImmediateMesh.new()
	dots_node = MeshInstance3D.new()
	dots_node.mesh = dots_mesh
	dots_node.material_override = dots_mat
	dots_node.visible = false
	parent.add_child(dots_node)

	# Single shared mesh for ALL enemy aim lines
	var enemy_mat := StandardMaterial3D.new()
	enemy_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	enemy_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	enemy_mat.vertex_color_use_as_albedo = true
	all_enemy_mesh = ImmediateMesh.new()
	all_enemy_node = MeshInstance3D.new()
	all_enemy_node.mesh = all_enemy_mesh
	all_enemy_node.material_override = enemy_mat
	all_enemy_node.visible = false
	parent.add_child(all_enemy_node)


func show() -> void:
	if bands_node:
		bands_node.visible = true
		dots_node.visible = true


func hide() -> void:
	if bands_node:
		bands_node.visible = false
		dots_node.visible = false


func reset() -> void:
	hide()
	# Clear stale enemy aim state so leftover lines don't persist into the next round.
	enemy_data.clear()
	_enemy_dirty = false
	if all_enemy_node:
		all_enemy_node.visible = false
		all_enemy_mesh.clear_surfaces()


# --- Own aim (slingshot + trajectory dots) ---

func update(ball: Node3D, direction: Vector3, power_ratio: float) -> void:
	if bands_node == null:
		return
	# On web, skip mesh rebuilds that arrive faster than 30Hz to avoid
	# accumulating JS WebGLBuffer wrapper objects (= GC pressure / 1 FPS drops).
	if OS.get_name() == "Web":
		var now := Time.get_ticks_msec()
		if now - _web_rebuild_ms < _WEB_REBUILD_INTERVAL_MS:
			return
		_web_rebuild_ms = now

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
	rebuild_count_own += 1
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

	var _band_anchors := [left_anchor, right_anchor]
	for anchor in _band_anchors:
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

	# --- Trajectory dots (wall-bounce aware) ---
	dots_node.visible = true
	dots_mesh.clear_surfaces()
	var dot_color := Color(pcolor.r * 0.5 + 0.5, pcolor.g * 0.5 + 0.5, pcolor.b * 0.5 + 0.5)
	_draw_trajectory(ball_pos, direction, power_ratio, right, dot_color, band_y)


# --- Enemy aim lines ---

func on_aim_received(slot: int, direction: Vector3, power: float) -> void:
	# Eagerly prune data for dead slots — stops stale entries persisting until reset()
	if slot >= 0 and slot < gm.balls.size() and gm.balls[slot] != null and not gm.balls[slot].is_alive:
		if slot in enemy_data:
			enemy_data.erase(slot)
			_enemy_dirty = true
		return

	if power < 0.01 or direction.length() < 0.01:
		if slot in enemy_data:
			enemy_data.erase(slot)
			_enemy_dirty = true
	elif slot in enemy_data:
		# Update in-place — avoids allocating a new Dictionary each call (20Hz × N bots)
		enemy_data[slot]["dir"] = direction
		enemy_data[slot]["power"] = power
		_enemy_dirty = true
	else:
		enemy_data[slot] = {"dir": direction, "power": power}
		_enemy_dirty = true


func update_enemy_lines() -> void:
	# Skip entirely if no aim data arrived since last rebuild
	if not _enemy_dirty:
		return

	# On web, rate-limit the single batch rebuild to ~30Hz.
	# This is a GLOBAL limit (not per-slot), so N bots still produce only 1 GL buffer
	# pair per 33ms instead of N pairs — the key fix for synchronized GC spikes.
	if OS.get_name() == "Web":
		var now_ms := Time.get_ticks_msec()
		if now_ms - _web_rebuild_ms < _WEB_REBUILD_INTERVAL_MS:
			return
		_web_rebuild_ms = now_ms

	_enemy_dirty = false

	var my_slot := NetworkManager.my_slot
	var steps := 8
	var has_any := false

	rebuild_count_enemy += 1
	all_enemy_mesh.clear_surfaces()

	for slot: int in enemy_data:
		if slot == my_slot:
			continue
		if slot < 0 or slot >= gm.balls.size() or gm.balls[slot] == null or not gm.balls[slot].is_alive:
			continue

		var data: Dictionary = enemy_data[slot]
		var dir: Vector3 = data["dir"]
		var power: float = data["power"]
		var pcolor: Color = gm.player_colors[slot] if slot < gm.player_colors.size() else Color.WHITE
		var ball_pos: Vector3 = gm.balls[slot].global_position
		var start := ball_pos + Vector3(0, 0.12, 0)
		var end: Vector3 = start + dir * (1.2 + power * 4.0)
		var right := dir.cross(Vector3.UP).normalized() * 0.08

		# Open the surface on the first valid slot to avoid surface_end with 0 vertices
		if not has_any:
			all_enemy_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		has_any = true

		# Emit ribbon as explicit triangles so multiple lines coexist in one surface
		# (TRIANGLE_STRIP topology would connect separate lines to each other)
		for i in steps:
			var t0 := float(i) / float(steps)
			var t1 := float(i + 1) / float(steps)
			var p0 := start.lerp(end, t0)
			var p1 := start.lerp(end, t1)
			var alpha := 0.8 if (i % 2 == 0) else 0.25
			var c := Color(pcolor.r, pcolor.g, pcolor.b, alpha)

			all_enemy_mesh.surface_set_color(c)
			all_enemy_mesh.surface_add_vertex(p0 + right)
			all_enemy_mesh.surface_add_vertex(p0 - right)
			all_enemy_mesh.surface_add_vertex(p1 + right)

			all_enemy_mesh.surface_add_vertex(p0 - right)
			all_enemy_mesh.surface_add_vertex(p1 - right)
			all_enemy_mesh.surface_add_vertex(p1 + right)

	if has_any:
		all_enemy_mesh.surface_end()
	all_enemy_node.visible = has_any


# --- Trajectory helper: wall-bounce simulation + dot drawing ---

func _draw_trajectory(ball_pos: Vector3, direction: Vector3, power_ratio: float, right: Vector3, dot_color: Color, band_y: float) -> void:
	var ball_radius: float = GameConfig.ball_radius
	var x_wall := table_half_x - ball_radius
	var z_wall := table_half_z - ball_radius

	# Build trajectory segments (up to 2 bounces)
	var segments: Array = []       # each: {from: Vector3, to: Vector3}
	var bounce_pos: Array = []     # positions of wall-hit bounce markers

	var cur := ball_pos + direction * 0.4 + Vector3(0, band_y, 0)
	var d := Vector3(direction.x, 0.0, direction.z).normalized()
	var remaining := 1.0 + power_ratio * 5.5

	for _bounce in 2:
		if remaining <= 0.01 or d.length_squared() < 0.001:
			break
		# Time to nearest wall in each axis
		var tx := INF
		var tz := INF
		if abs(d.x) > 0.001:
			tx = (x_wall * signf(d.x) - cur.x) / d.x
		if abs(d.z) > 0.001:
			tz = (z_wall * signf(d.z) - cur.z) / d.z
		var t := minf(minf(tx, tz), remaining)
		t = maxf(t, 0.0)
		var next := cur + d * t
		segments.append({"from": cur, "to": next})
		remaining -= t
		cur = next
		if t < remaining + 0.001 and (tx < remaining + t + 0.001 or tz < remaining + t + 0.001):
			# Hit a wall — record bounce, reflect direction
			bounce_pos.append(cur)
			if tx <= tz:
				d.x = -d.x
			else:
				d.z = -d.z
		else:
			break  # Ran out of path before hitting a wall

	# Add final segment if path remains
	if remaining > 0.01:
		segments.append({"from": cur, "to": cur + d * remaining})

	# Measure total path length
	var total_dist := 0.0
	for seg in segments:
		total_dist += (seg["to"] - seg["from"]).length()
	if total_dist < 0.01:
		return

	# Distribute DOT_COUNT dots evenly along the full path
	var DOT_COUNT := 12
	var dot_step := total_dist / float(DOT_COUNT - 1)

	dots_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var seg_idx := 0
	var seg_walked := 0.0  # distance walked inside current segment
	var seg_from: Vector3 = segments[0]["from"]
	var seg_to: Vector3 = segments[0]["to"]
	var seg_len: float = (seg_to - seg_from).length()
	var seg_dir: Vector3 = (seg_to - seg_from).normalized() if seg_len > 0.001 else direction.normalized()

	for i in DOT_COUNT:
		var target := float(i) * dot_step
		# Advance through segments to reach this dot's position
		while seg_idx + 1 < segments.size() and seg_walked + seg_len < target - 0.001:
			seg_walked += seg_len
			seg_idx += 1
			seg_from = segments[seg_idx]["from"]
			seg_to = segments[seg_idx]["to"]
			seg_len = (seg_to - seg_from).length()
			seg_dir = (seg_to - seg_from).normalized() if seg_len > 0.001 else seg_dir

		var local_t := 0.0
		if seg_len > 0.001:
			local_t = clampf((target - seg_walked) / seg_len, 0.0, 1.0)
		var dot_pos := seg_from.lerp(seg_to, local_t)

		# Check if near a bounce point
		var is_bounce := false
		for bp in bounce_pos:
			if dot_pos.distance_squared_to(bp) < 0.25:
				is_bounce = true
				break

		var t_frac := float(i) / float(DOT_COUNT - 1)
		var alpha := lerpf(0.85, 0.1, t_frac) * power_ratio
		var dot_size := lerpf(0.09, 0.04, t_frac) * (1.6 if is_bounce else 1.0)
		var c: Color
		if is_bounce:
			c = Color(1.0, 1.0, 1.0, alpha * 1.2)
		else:
			c = Color(dot_color.r, dot_color.g, dot_color.b, alpha)

		# Get the per-segment right vector for this dot
		var dot_right := seg_dir.cross(Vector3.UP).normalized()
		if dot_right.length_squared() < 0.001:
			dot_right = right

		var fwd := seg_dir * dot_size
		var r := dot_right * dot_size

		dots_mesh.surface_set_color(c)
		dots_mesh.surface_add_vertex(dot_pos - fwd - r)
		dots_mesh.surface_add_vertex(dot_pos - fwd + r)
		dots_mesh.surface_add_vertex(dot_pos + fwd + r)
		dots_mesh.surface_add_vertex(dot_pos - fwd - r)
		dots_mesh.surface_add_vertex(dot_pos + fwd + r)
		dots_mesh.surface_add_vertex(dot_pos + fwd - r)

	dots_mesh.surface_end()
