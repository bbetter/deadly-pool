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
	else:
		_send_response(peer, "404 Not Found", "application/json", '{"error":"not found"}')


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
					"perf": p.get("perf", {}),
				})

		var status := "lobby"
		var game_state: Dictionary = {}
		if room["started"]:
			var gm_node = room.get("game_manager")
			if gm_node != null and is_instance_valid(gm_node):
				status = "in_game"
				game_state = gm_node.get_state_dict()
			else:
				status = "starting"
		elif room["countdown"] > 0.0:
			status = "countdown"

		rooms_arr.append({
			"code": code,
			"status": status,
			"player_count": room["players"].size(),
			"players": room_players,
			"game": game_state,
		})

	var data := {
		"server_uptime": int(uptime),
		"total_players": NetworkManager.players.size(),
		"total_rooms": NetworkManager._rooms.size(),
		"rooms": rooms_arr,
	}

	return JSON.stringify(data)




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




