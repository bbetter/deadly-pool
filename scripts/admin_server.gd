extends Node
## Lightweight HTTP server for admin status page. Server-only.
## Serves GET / (HTML dashboard) and GET /api/status (JSON).

var _tcp_server: TCPServer
var _port: int = 8081
var _start_time: float = 0.0
var _clients: Array[StreamPeerTCP] = []
var _responded_clients: Array[Array] = []  # [StreamPeerTCP, float] — peer + time sent


func _ready() -> void:
	if not NetworkManager.is_server_mode:
		return

	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if arg.begins_with("--admin-port="):
			_port = int(arg.split("=")[1])

	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port)
	if err != OK:
		print("[ADMIN] Failed to start HTTP server on port %d: %s" % [_port, error_string(err)])
		return

	_start_time = Time.get_unix_time_from_system()
	print("[ADMIN] HTTP admin server on port %d" % _port)


func _process(_delta: float) -> void:
	if _tcp_server == null or not _tcp_server.is_listening():
		return

	# Accept new connections
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		if peer:
			print("[ADMIN] New connection accepted, status=%d" % peer.get_status())
			_clients.append(peer)

	# Process existing connections
	var i := 0
	while i < _clients.size():
		var peer := _clients[i]
		peer.poll()

		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			var request := peer.get_utf8_string(peer.get_available_bytes())
			var first_line := request.split("\n")[0] if request.length() > 0 else "(empty)"
			print("[ADMIN] Request: %s" % first_line.strip_edges())
			_handle_request(peer, request)
			print("[ADMIN] Response sent")
			# Keep peer alive briefly so OS can flush the TCP buffer
			_responded_clients.append([peer, Time.get_ticks_msec() / 1000.0])
			_clients.remove_at(i)
			continue
		elif status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			print("[ADMIN] Peer dropped (status=%d)" % status)
			_clients.remove_at(i)
			continue

		i += 1

	# Clean up responded clients after a short delay (let TCP flush)
	var now := Time.get_ticks_msec() / 1000.0
	var j := 0
	while j < _responded_clients.size():
		var entry: Array = _responded_clients[j]
		if now - entry[1] > 0.5:
			_responded_clients.remove_at(j)
			continue
		j += 1


func _handle_request(peer: StreamPeerTCP, request: String) -> void:
	var path := "/"
	var lines := request.split("\r\n")
	if lines.size() > 0:
		var parts := lines[0].split(" ")
		if parts.size() >= 2:
			path = parts[1]

	var method := "GET"
	if lines.size() > 0:
		var parts2 := lines[0].split(" ")
		if parts2.size() >= 1:
			method = parts2[0]

	if path == "/api/status":
		var json := _build_status_json()
		_send_response(peer, "200 OK", "application/json", json)
	elif path.begins_with("/api/logs"):
		var json := _build_logs_json(path)
		_send_response(peer, "200 OK", "application/json", json)
	elif path == "/api/tuning" and method == "GET":
		var json := JSON.stringify(GameConfig.to_dict())
		_send_response(peer, "200 OK", "application/json", json)
	elif path == "/api/tuning" and method == "POST":
		# Extract body after blank line
		var body := ""
		var body_start := request.find("\r\n\r\n")
		if body_start >= 0:
			body = request.substr(body_start + 4)
		var parsed = JSON.parse_string(body)
		if parsed is Dictionary:
			GameConfig.from_dict(parsed)
			_send_response(peer, "200 OK", "application/json", JSON.stringify(GameConfig.to_dict()))
		else:
			_send_response(peer, "400 Bad Request", "application/json", '{"error":"invalid json"}')
	elif path == "/api/tuning/reset" and method == "POST":
		GameConfig.reset_defaults()
		_send_response(peer, "200 OK", "application/json", JSON.stringify(GameConfig.to_dict()))
	elif path.begins_with("/tuning"):
		var html := _build_tuning_html()
		_send_response(peer, "200 OK", "text/html; charset=utf-8", html)
	elif path.begins_with("/logs"):
		var html := _build_logs_html()
		_send_response(peer, "200 OK", "text/html; charset=utf-8", html)
	else:
		var html := _build_admin_html()
		_send_response(peer, "200 OK", "text/html; charset=utf-8", html)


func _send_response(peer: StreamPeerTCP, status: String, content_type: String, body: String) -> void:
	var body_bytes := body.to_utf8_buffer()
	var header := "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n" % [status, content_type, body_bytes.size()]
	var header_bytes := header.to_utf8_buffer()
	# Combine into single buffer to ensure atomic send before peer is freed
	var full := PackedByteArray()
	full.append_array(header_bytes)
	full.append_array(body_bytes)
	peer.put_data(full)


func _build_status_json() -> String:
	var uptime := Time.get_unix_time_from_system() - _start_time
	var rooms_arr: Array[Dictionary] = []

	for code: String in NetworkManager._rooms:
		var room: Dictionary = NetworkManager._rooms[code]
		var room_players: Array[Dictionary] = []

		for pid: int in room["players"]:
			if pid in NetworkManager.players:
				var p: Dictionary = NetworkManager.players[pid]
				room_players.append({
					"peer_id": pid,
					"name": p["name"],
					"slot": p["slot"],
				})

		var status := "lobby"
		if room["started"]:
			var gm_node = room.get("game_manager")
			if gm_node != null and is_instance_valid(gm_node):
				status = "in_game"
			else:
				status = "starting"
		elif room["countdown"] > 0.0:
			status = "countdown"

		rooms_arr.append({
			"code": code,
			"status": status,
			"player_count": room["players"].size(),
			"players": room_players,
		})

	var data := {
		"server_uptime": int(uptime),
		"total_players": NetworkManager.players.size(),
		"total_rooms": NetworkManager._rooms.size(),
		"rooms": rooms_arr,
	}

	return JSON.stringify(data)


func _build_admin_html() -> String:
	return '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Deadly Pool - Admin</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #0a0a14; color: #ccc; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; padding: 24px; }
h1 { color: #ffda33; font-size: 28px; margin-bottom: 4px; }
.subtitle { color: #666; font-size: 14px; margin-bottom: 24px; }
.stats { display: flex; gap: 24px; margin-bottom: 24px; }
.stat { background: #14142a; border: 1px solid #2a2a4a; border-radius: 8px; padding: 16px 24px; }
.stat-value { font-size: 32px; font-weight: bold; color: #fff; }
.stat-label { font-size: 12px; color: #666; text-transform: uppercase; letter-spacing: 1px; margin-top: 4px; }
.rooms { display: flex; flex-direction: column; gap: 16px; }
.room { background: #14142a; border: 1px solid #2a2a4a; border-radius: 8px; padding: 20px; }
.room-header { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
.room-code { font-size: 22px; font-weight: bold; color: #4dd9ff; font-family: monospace; }
.badge { font-size: 11px; padding: 3px 10px; border-radius: 12px; text-transform: uppercase; font-weight: bold; letter-spacing: 1px; }
.badge-lobby { background: #1a3a1a; color: #4dff7c; }
.badge-countdown { background: #3a3a1a; color: #ffda33; }
.badge-in_game { background: #1a1a3a; color: #4d9fff; }
.player-list { list-style: none; }
.player { display: flex; align-items: center; gap: 10px; padding: 6px 0; border-bottom: 1px solid #1a1a2a; }
.player:last-child { border-bottom: none; }
.color-dot { width: 14px; height: 14px; border-radius: 50%; flex-shrink: 0; }
.player-name { color: #eee; font-size: 15px; }
.player-peer { color: #444; font-size: 12px; }
.empty { color: #444; font-style: italic; padding: 20px; text-align: center; }
.updated { color: #333; font-size: 12px; position: fixed; bottom: 12px; right: 16px; }
</style>
</head>
<body>
<h1>Deadly Pool</h1>
<p class="subtitle">Server Admin Dashboard &mdash; <a href="/logs" style="color:#4dd9ff">Room Logs</a> &mdash; <a href="/tuning" style="color:#4dd9ff">Physics Tuning</a></p>
<div class="stats">
  <div class="stat"><div class="stat-value" id="uptime">--</div><div class="stat-label">Uptime</div></div>
  <div class="stat"><div class="stat-value" id="players">--</div><div class="stat-label">Players</div></div>
  <div class="stat"><div class="stat-value" id="room-count">--</div><div class="stat-label">Rooms</div></div>
</div>
<div class="rooms" id="rooms"><div class="empty">Loading...</div></div>
<div class="updated" id="updated"></div>
<script>
const COLORS = ["#e62626","#2666e6","#e6bf1a","#26cc4d"];
const COLOR_NAMES = ["Red","Blue","Yellow","Green"];
function fmt(s) {
  let h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = s%60;
  return h > 0 ? h+"h "+m+"m" : m > 0 ? m+"m "+sec+"s" : sec+"s";
}
async function refresh() {
  try {
    let r = await fetch("/api/status");
    let d = await r.json();
    document.getElementById("uptime").textContent = fmt(d.server_uptime);
    document.getElementById("players").textContent = d.total_players;
    document.getElementById("room-count").textContent = d.total_rooms;
    let el = document.getElementById("rooms");
    if (d.rooms.length === 0) {
      el.innerHTML = \'<div class="empty">No active rooms</div>\';
    } else {
      el.innerHTML = d.rooms.map(room => {
        let players = room.players.map(p => {
          let c = COLORS[p.slot] || "#888";
          let cn = COLOR_NAMES[p.slot] || "?";
          return \'<li class="player"><span class="color-dot" style="background:\'+c+\'"></span><span class="player-name">\'+esc(p.name)+\' <small>(\'+cn+\')</small></span><span class="player-peer">peer:\'+p.peer_id+\'</span></li>\';
        }).join("");
        return \'<div class="room"><div class="room-header"><span class="room-code">\'+room.code+\'</span><span class="badge badge-\'+room.status+\'">\'+room.status.replace("_"," ")+\'</span><span class="player-peer">\'+room.player_count+\'/4 players</span></div><ul class="player-list">\'+players+\'</ul></div>\';
      }).join("");
    }
    document.getElementById("updated").textContent = "Updated: " + new Date().toLocaleTimeString();
  } catch(e) {
    document.getElementById("updated").textContent = "Error: " + e.message;
  }
}
function esc(s) { let d = document.createElement("div"); d.textContent = s; return d.innerHTML; }
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>'


func _build_logs_json(path: String) -> String:
	# /api/logs?room=ABCDE or /api/logs for all rooms
	var room_code := ""
	if "?" in path:
		var query := path.split("?")[1]
		for param: String in query.split("&"):
			if param.begins_with("room="):
				room_code = param.split("=")[1]

	if room_code != "":
		var logs: Array = NetworkManager.room_logs.get(room_code, [])
		return JSON.stringify({"room": room_code, "lines": logs})
	else:
		# Return all room codes with line counts and active/archived status
		var rooms: Array[Dictionary] = []
		for code: String in NetworkManager.room_logs:
			var lines: Array = NetworkManager.room_logs[code]
			var is_archived := code in NetworkManager.archived_rooms
			rooms.append({"code": code, "line_count": lines.size(), "archived": is_archived})
		return JSON.stringify({"rooms": rooms})


func _build_logs_html() -> String:
	return '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Deadly Pool - Room Logs</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #0a0a14; color: #ccc; font-family: monospace; padding: 24px; }
h1 { color: #ffda33; font-size: 24px; margin-bottom: 4px; }
.subtitle { color: #666; font-size: 13px; margin-bottom: 16px; }
.nav { margin-bottom: 20px; }
.nav a { color: #4dd9ff; text-decoration: none; margin-right: 16px; }
.nav a:hover { text-decoration: underline; }
.room-tabs { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
.tab { padding: 6px 16px; border-radius: 6px; cursor: pointer; border: 1px solid #2a2a4a; background: #14142a; color: #aaa; font-family: monospace; font-size: 14px; }
.tab:hover { border-color: #4dd9ff; color: #fff; }
.tab.active { background: #1a2a4a; border-color: #4dd9ff; color: #4dd9ff; }
.tab.archived { opacity: 0.5; }
.tab.archived:hover { opacity: 0.8; }
.section-label { color: #666; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin: 12px 0 6px; }
.section-label:first-child { margin-top: 0; }
.log-container { background: #0d0d1a; border: 1px solid #1a1a2a; border-radius: 8px; padding: 16px; max-height: 70vh; overflow-y: auto; }
.log-line { padding: 2px 0; font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-break: break-all; }
.log-line .ts { color: #555; }
.log-line .launch { color: #4dff7c; }
.log-line .state { color: #666; }
.log-line .pocket { color: #ff6b4d; }
.log-line .elim { color: #ff4d4d; }
.log-line .game { color: #ffda33; }
.log-line .powerup { color: #bf6dff; }
.log-line .effect { color: #ff9f4d; }
.empty { color: #444; font-style: italic; padding: 20px; text-align: center; }
.controls { margin-bottom: 12px; display: flex; gap: 12px; align-items: center; }
.controls label { color: #888; font-size: 13px; }
.controls input[type=checkbox] { margin-right: 4px; }
.auto-label { color: #4dff7c; font-size: 12px; }
</style>
</head>
<body>
<h1>Room Logs</h1>
<p class="subtitle">Physics debug and game event logs per room</p>
<div class="nav"><a href="/">Dashboard</a><a href="/logs">Logs</a><a href="/tuning">Tuning</a></div>
<div id="tabs"></div>
<div class="controls">
  <label><input type="checkbox" id="auto" checked> Auto-refresh (2s)</label>
  <label><input type="checkbox" id="showState"> Show STATE lines</label>
  <label><input type="checkbox" id="scrollLock" checked> Auto-scroll</label>
</div>
<div class="log-container" id="logs"><div class="empty">Select a room</div></div>
<script>
let currentRoom = "";
let autoRefresh = true;
let showState = false;
let autoScroll = true;

document.getElementById("auto").onchange = e => autoRefresh = e.target.checked;
document.getElementById("showState").onchange = e => { showState = e.target.checked; if(currentRoom) loadLogs(currentRoom); };
document.getElementById("scrollLock").onchange = e => autoScroll = e.target.checked;

async function loadRooms() {
  try {
    let r = await fetch("/api/logs");
    let d = await r.json();
    let el = document.getElementById("tabs");
    if (d.rooms.length === 0) {
      el.innerHTML = \'<span class="empty">No rooms with logs</span>\';
      return;
    }
    let active = d.rooms.filter(r => !r.archived);
    let archived = d.rooms.filter(r => r.archived);
    let html = "";
    if (active.length > 0) {
      html += \'<div class="section-label">Active Rooms</div><div class="room-tabs">\';
      html += active.map(r =>
        \'<button class="tab\'+(r.code===currentRoom?" active":"")+\'" onclick="selectRoom(\\\'\'+ r.code +\'\\\')">\'+ r.code +\' (\'+ r.line_count +\')</button>\'
      ).join("");
      html += \'</div>\';
    }
    if (archived.length > 0) {
      html += \'<div class="section-label">Archived Rooms</div><div class="room-tabs">\';
      html += archived.map(r =>
        \'<button class="tab archived\'+(r.code===currentRoom?" active":"")+\'" onclick="selectRoom(\\\'\'+ r.code +\'\\\')">\'+ r.code +\' (\'+ r.line_count +\')</button>\'
      ).join("");
      html += \'</div>\';
    }
    if (active.length === 0 && archived.length === 0) {
      html = \'<span class="empty">No rooms with logs</span>\';
    }
    el.innerHTML = html;
  } catch(e) {}
}

function selectRoom(code) {
  currentRoom = code;
  loadRooms();
  loadLogs(code);
}

function classify(line) {
  if (line.includes("LAUNCH")) return "launch";
  if (line.includes("STATE")) return "state";
  if (line.includes("POCKET")) return "pocket";
  if (line.includes("ELIMINATED")) return "elim";
  if (line.includes("GAME_START") || line.includes("GAME_OVER")) return "game";
  if (line.includes("POWERUP")) return "powerup";
  if (line.includes("SHOCKWAVE") || line.includes("ANCHOR")) return "effect";
  return "";
}

async function loadLogs(code) {
  try {
    let r = await fetch("/api/logs?room=" + code);
    let d = await r.json();
    let el = document.getElementById("logs");
    if (d.lines.length === 0) {
      el.innerHTML = \'<div class="empty">No logs yet</div>\';
      return;
    }
    let filtered = d.lines;
    if (!showState) filtered = filtered.filter(l => !l.includes("STATE"));
    el.innerHTML = filtered.map(l => {
      let cls = classify(l);
      let parts = l.match(/^(\\[[^\\]]+\\])(.*)$/);
      if (parts) return \'<div class="log-line"><span class="ts">\'+esc(parts[1])+\'</span><span class="\'+cls+\'">\'+esc(parts[2])+\'</span></div>\';
      return \'<div class="log-line">\'+esc(l)+\'</div>\';
    }).join("");
    if (autoScroll) el.scrollTop = el.scrollHeight;
  } catch(e) {}
}

function esc(s) { let d = document.createElement("div"); d.textContent = s; return d.innerHTML; }

loadRooms();
setInterval(() => { if(autoRefresh) { loadRooms(); if(currentRoom) loadLogs(currentRoom); } }, 2000);
</script>
</body>
</html>'


func _build_tuning_html() -> String:
	return '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Deadly Pool - Physics Tuning</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #0a0a14; color: #ccc; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; padding: 24px; max-width: 800px; margin: 0 auto; }
h1 { color: #ffda33; font-size: 24px; margin-bottom: 4px; }
.subtitle { color: #666; font-size: 13px; margin-bottom: 20px; }
.nav { margin-bottom: 20px; }
.nav a { color: #4dd9ff; text-decoration: none; margin-right: 16px; }
.nav a:hover { text-decoration: underline; }
.section { background: #14142a; border: 1px solid #2a2a4a; border-radius: 8px; padding: 16px 20px; margin-bottom: 16px; }
.section h2 { color: #4dd9ff; font-size: 15px; margin-bottom: 12px; text-transform: uppercase; letter-spacing: 1px; }
.field { display: flex; align-items: center; gap: 12px; padding: 6px 0; border-bottom: 1px solid #1a1a2a; }
.field:last-child { border-bottom: none; }
.field label { flex: 1; color: #aaa; font-size: 14px; }
.field input { width: 100px; background: #0a0a14; border: 1px solid #2a2a4a; border-radius: 4px; color: #fff; padding: 4px 8px; font-size: 14px; font-family: monospace; text-align: right; }
.field input:focus { outline: none; border-color: #4dd9ff; }
.field .unit { color: #555; font-size: 12px; width: 40px; }
.buttons { display: flex; gap: 12px; margin-top: 20px; }
.btn { padding: 10px 24px; border-radius: 6px; border: none; cursor: pointer; font-size: 14px; font-weight: bold; }
.btn-save { background: #1a6b1a; color: #fff; }
.btn-save:hover { background: #228b22; }
.btn-reset { background: #4a1a1a; color: #fff; }
.btn-reset:hover { background: #6b2222; }
.status { margin-top: 12px; font-size: 13px; color: #4dff7c; min-height: 20px; }
.status.error { color: #ff4d4d; }
</style>
</head>
<body>
<h1>Physics Tuning</h1>
<p class="subtitle">Change values and click Save. Changes apply to new launches immediately.</p>
<div class="nav"><a href="/">Dashboard</a><a href="/logs">Logs</a><a href="/tuning">Tuning</a></div>
<div id="sections"></div>
<div class="buttons">
  <button class="btn btn-save" onclick="save()">Save Changes</button>
  <button class="btn btn-reset" onclick="resetDefaults()">Reset Defaults</button>
</div>
<div class="status" id="status"></div>
<script>
const SECTIONS = {
  "Ball Physics": [
    ["ball_mass", "Mass", "kg"],
    ["ball_friction", "Friction", ""],
    ["ball_bounce", "Bounce", ""],
    ["ball_linear_damp", "Linear Damping", ""],
    ["ball_angular_damp", "Angular Damping", ""],
    ["ball_max_power", "Max Launch Power", ""],
    ["ball_min_power", "Min Launch Power", ""],
    ["ball_radius", "Radius", "m"],
    ["ball_slow_threshold", "Slow Threshold", "m/s"],
    ["ball_extra_damp_factor", "Extra Damp Factor", "x"],
    ["ball_stop_threshold", "Stop Threshold", "m/s"],
    ["ball_moving_threshold", "Moving Threshold", "m/s"],
  ],
  "Powerups": [
    ["powerup_pickup_radius", "Pickup Radius", "m"],
    ["powerup_max_on_table", "Max On Table", ""],
    ["powerup_spawn_min_delay", "Spawn Min Delay", "s"],
    ["powerup_spawn_max_delay", "Spawn Max Delay", "s"],
    ["speed_boost_multiplier", "Speed Boost", "x"],
    ["bomb_force", "Bomb Force", ""],
    ["bomb_radius", "Bomb Radius", "m"],
    ["shield_mass", "Shield Mass", "kg"],
    ["shield_duration", "Shield Duration", "s"],
    ["shield_knockback", "Shield Knockback", ""],
  ],
  "Bot AI": [
    ["bot_min_delay", "Min Delay", "s"],
    ["bot_max_delay", "Max Delay", "s"],
    ["bot_power_min_pct", "Power Min %", ""],
    ["bot_power_max_pct", "Power Max %", ""],
    ["bot_scatter_angle", "Scatter Angle", "rad"],
    ["bot_accuracy_easy", "Accuracy Easy (close)", "x"],
    ["bot_accuracy_hard", "Accuracy Hard (far)", "x"],
    ["bot_distance_factor", "Distance Factor", "rad/m"],
    ["bot_power_variance", "Power Variance", ""],
    ["bot_min_power_for_distance", "Min Power for Dist", ""],
  ],
  "Game Timing": [
    ["launch_cooldown", "Launch Cooldown", "s"],
    ["disconnect_grace_period", "Disconnect Grace", "s"],
  ],
};

let currentValues = {};

function buildUI(data) {
  currentValues = data;
  let html = "";
  for (let [title, fields] of Object.entries(SECTIONS)) {
    html += \'<div class="section"><h2>\' + title + \'</h2>\';
    for (let [key, label, unit] of fields) {
      let val = data[key] !== undefined ? data[key] : "";
      let step = Number.isInteger(val) ? "1" : "0.01";
      html += \'<div class="field"><label>\' + label + \'</label><input type="number" step="\' + step + \'" id="f_\' + key + \'" value="\' + val + \'"><span class="unit">\' + unit + \'</span></div>\';
    }
    html += \'</div>\';
  }
  document.getElementById("sections").innerHTML = html;
}

async function load() {
  try {
    let r = await fetch("/api/tuning");
    let d = await r.json();
    buildUI(d);
  } catch(e) {
    showStatus("Failed to load: " + e.message, true);
  }
}

async function save() {
  let data = {};
  for (let fields of Object.values(SECTIONS)) {
    for (let [key] of fields) {
      let el = document.getElementById("f_" + key);
      if (el) data[key] = parseFloat(el.value);
    }
  }
  try {
    let r = await fetch("/api/tuning", { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(data) });
    let d = await r.json();
    if (d.error) { showStatus("Error: " + d.error, true); return; }
    buildUI(d);
    showStatus("Saved successfully!");
  } catch(e) {
    showStatus("Save failed: " + e.message, true);
  }
}

async function resetDefaults() {
  if (!confirm("Reset all values to defaults?")) return;
  try {
    let r = await fetch("/api/tuning/reset", { method: "POST" });
    let d = await r.json();
    buildUI(d);
    showStatus("Reset to defaults!");
  } catch(e) {
    showStatus("Reset failed: " + e.message, true);
  }
}

function showStatus(msg, isError) {
  let el = document.getElementById("status");
  el.textContent = msg;
  el.className = "status" + (isError ? " error" : "");
  setTimeout(() => el.textContent = "", 3000);
}

load();
</script>
</body>
</html>'
