extends RefCounted
class_name DebugHUDOverlay
## Perf/debug overlay: FPS, sync rate, memory, ping, draw calls.
## Extracted from GameHUD to keep HUD focused on layout/UI logic.

var _gm: Node
var _debug_label: Label = null

# Sync tracking
var _sync_count: int = 0
var _last_sync_time: float = 0.0
var _sync_gaps: int = 0

# Per-second sampling
var _debug_timer: float = 0.0

# Perf report accumulators (sent to server every 30s)
var _perf_report_timer: float = 0.0
var _perf_ping_timer: float = 0.0
var _perf_fps_sum: float = 0.0
var _perf_fps_min: float = 9999.0
var _perf_sync_sum: float = 0.0
var _perf_ping_sum: float = 0.0
var _perf_sample_count: int = 0
var _perf_renderer: String = ""

# Memory & node-count tracking
var _prev_mem_mb: float = 0.0
var _mem_delta_mb: float = 0.0
var _prev_obj_count: int = 0
var _obj_delta: int = 0
var _alloc_spike_count: int = 0


func _init(gm_ref: Node, parent: CanvasLayer) -> void:
	_gm = gm_ref
	if not OS.is_debug_build():
		return
	_debug_label = Label.new()
	_debug_label.text = ""
	_debug_label.add_theme_font_size_override("font_size", 13)
	_debug_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	_debug_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.88))
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_debug_label.position = Vector2(0, 4)
	_debug_label.size = Vector2(1280, 40)
	parent.add_child(_debug_label)


func on_sync_received() -> void:
	_sync_count += 1
	var now := Time.get_ticks_msec() / 1000.0
	if _last_sync_time > 0.0:
		var gap := now - _last_sync_time
		if gap > 0.1:  # >100ms gap = likely dropped packet(s)
			_sync_gaps += 1
	_last_sync_time = now


func update(delta: float) -> void:
	if not OS.is_debug_build():
		return
	_debug_timer += delta

	# Send ping every 3 seconds
	if not NetworkManager.is_single_player:
		_perf_ping_timer += delta
		if _perf_ping_timer >= 3.0:
			_perf_ping_timer = 0.0
			NetworkManager.send_ping()

	if _debug_timer < 1.0:
		return
	var fps: float = float(Engine.get_frames_per_second())
	var sync_rate: float = float(_sync_count) / _debug_timer
	var gaps: int = _sync_gaps
	_sync_count = 0
	_sync_gaps = 0
	_debug_timer = 0.0
	if _perf_renderer.is_empty():
		_fetch_renderer_name.call_deferred()

	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var mem_mb: float = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var tris_k: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) / 1000
	var vmem_mb: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var ping_ms: float = NetworkManager.client_ping_ms

	# Memory delta (allocation rate)
	_mem_delta_mb = mem_mb - _prev_mem_mb
	_prev_mem_mb = mem_mb

	# Object count & delta (node allocations)
	var tree: SceneTree = Engine.get_main_loop()
	var obj_count := tree.get_node_count() if tree else 0
	_obj_delta = obj_count - _prev_obj_count
	_prev_obj_count = obj_count

	# Track allocation spikes
	if _obj_delta > 5:
		_alloc_spike_count += 1

	_perf_sample_count += 1

	if _debug_label != null:
		var active_bursts := 0
		if tree and tree.has_group("bursts"):
			active_bursts = tree.get_node_count_in_group("bursts")

		var debug_line: String = "%d FPS | sync %.0f/s" % [int(fps), sync_rate]
		if gaps > 0:
			debug_line += " | gaps %d!" % gaps
		if ping_ms >= 0.0:
			debug_line += " | ping %.0fms" % ping_ms
		debug_line += " | draw %d | mem %.0fMB" % [draw_calls, mem_mb]
		if _mem_delta_mb > 0.1:
			debug_line += " (+%.2f)" % _mem_delta_mb
		elif _mem_delta_mb < -0.1:
			debug_line += " (-%.2f)" % -_mem_delta_mb
		if _obj_delta > 0:
			debug_line += " | obj +%d" % _obj_delta
		elif _obj_delta < 0:
			debug_line += " | obj %d" % _obj_delta
		if active_bursts > 0:
			debug_line += " | bursts %d" % active_bursts
		var frame_time: float = _gm._last_frame_time if _gm.has_method("_process") else 0.0
		if frame_time > 0:
			debug_line += " | frame %.1fms" % frame_time
			if frame_time > 16:
				debug_line += "!"
			if frame_time > 50:
				debug_line += "!!"
		if _alloc_spike_count > 0:
			debug_line += " | spikes %d!" % _alloc_spike_count

		var ball_us: int = 0
		for ball in _gm.balls:
			if ball != null:
				ball_us += ball._last_process_us
		var budget_line := "proc %.1fms | phys %.1fms | gm %.1fms | balls %dµs" % [
			proc_ms, phys_ms, frame_time, ball_us]
		budget_line += " | tris %dk | vmem %.0fMB" % [tris_k, vmem_mb]
		var fx_rings := 0
		if tree and tree.has_group("fx_rings"):
			fx_rings = tree.get_node_count_in_group("fx_rings")
		if fx_rings > 0:
			budget_line += " | rings %d" % fx_rings

		_debug_label.text = debug_line + "\n" + budget_line

		if fps < 30 or (ping_ms > 150 and ping_ms >= 0.0) or gaps > 2 or _alloc_spike_count > 3:
			_debug_label.add_theme_color_override("font_color", Color(1, 0.4, 0.3, 0.9))
		elif fps < 50 or (ping_ms > 80 and ping_ms >= 0.0) or gaps > 0 or _alloc_spike_count > 0:
			_debug_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 0.9))
		else:
			_debug_label.add_theme_color_override("font_color", Color(0.7, 1, 0.7, 0.9))

		if _perf_sample_count % 5 == 0:
			print("[PERF] %s | %s\n[PERF] %s" % [debug_line, _perf_renderer, budget_line])
		if _obj_delta > 10:
			print("[PERF] ALLOC SPIKE: +%d nodes, +%.2f MB memory" % [_obj_delta, _mem_delta_mb])

	# Accumulate for server report
	_perf_fps_sum += fps
	_perf_sync_sum += sync_rate
	if ping_ms >= 0.0:
		_perf_ping_sum += ping_ms
	if fps < _perf_fps_min:
		_perf_fps_min = fps

	# Reset allocation spike counter every 10 seconds
	if _perf_sample_count % 10 == 0:
		_alloc_spike_count = 0

	# Send summary to server every 30s
	if not NetworkManager.is_single_player:
		_perf_report_timer += 1.0
		if _perf_report_timer >= 30.0 and _perf_sample_count > 0:
			_perf_report_timer = 0.0
			_send_perf_report()


func _fetch_renderer_name() -> void:
	_perf_renderer = RenderingServer.get_video_adapter_name()


func _send_perf_report() -> void:
	var count: float = maxf(float(_perf_sample_count), 1.0)
	var avg_ping: float = _perf_ping_sum / count
	var fps_avg: float = _perf_fps_sum / count
	var sync_avg: float = _perf_sync_sum / count
	var report := "%s|%.0f|%.0f|%.0f|%.0f" % [
		_perf_renderer, fps_avg, _perf_fps_min, sync_avg, avg_ping]
	if OS.is_debug_build():
		print("[PERF] Sending report to server: fps_avg=%.0f fps_min=%.0f sync=%.0f/s ping=%.0fms" % [
			fps_avg, _perf_fps_min, sync_avg, avg_ping])
	_perf_fps_sum = 0.0
	_perf_fps_min = 9999.0
	_perf_sync_sum = 0.0
	_perf_ping_sum = 0.0
	_perf_sample_count = 0
	NetworkManager._rpc_client_perf_report.rpc_id(1, report)
