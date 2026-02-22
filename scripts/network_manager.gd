extends Node

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal lobby_updated()
signal connection_failed()
signal game_starting()
signal countdown_tick(seconds_left: int)
signal room_created(code: String)
signal room_joined(code: String)
signal room_join_failed(reason: String)
signal rooms_list_received(rooms: Array)

const PORT := 9876
const MAX_PLAYERS := 4
const COUNTDOWN_SECONDS := 5
const MAIN_SCENE := preload("res://scenes/main.tscn")
const ROOM_SPACING := 1000.0  # Spatial offset between rooms for physics isolation

# peer_id -> { "name": String, "slot": int, "room": String }
var players: Dictionary = {}
var my_peer_id: int = 0
var my_slot: int = -1
var my_name: String = "Player"
var is_server_mode: bool = false
var is_single_player: bool = false
var bot_slots: Array[int] = []  # Single-player only

# Room management
var current_room: String = ""  # Client-side only (server uses per-room data)
# Server-only: room_code -> { "players": Array[int], "started": bool, "countdown": float, "creator": int, "created_at": int, "scores": Dictionary, "bot_slots": Array[int], "game_manager": Node, "room_index": int }
var _rooms: Dictionary = {}

# Client-side persistent scores (populated by server RPCs)
var room_scores: Dictionary = {}

# Room event logs (server-only): room_code -> Array[String]
var room_logs: Dictionary = {}
var archived_rooms: Array[String] = []  # Room codes no longer active (for log display)
const MAX_LOG_LINES := 200

# Server-only: room container node and index counter
var _room_container: Node = null
var _room_index_counter: int = 0

func room_log(room_code: String, msg: String) -> void:
	var now := Time.get_datetime_dict_from_system()
	var ts := "%02d:%02d:%04d %02d:%02d:%02d.%03d" % [now.day, now.month, now.year, now.hour, now.minute, now.second, int((Time.get_ticks_msec() % 1000))]
	var line := "[%s] %s" % [ts, msg]
	if room_code not in room_logs:
		room_logs[room_code] = []
	room_logs[room_code].append(line)
	if room_logs[room_code].size() > MAX_LOG_LINES:
		room_logs[room_code] = room_logs[room_code].slice(-MAX_LOG_LINES)
	print("[%s] %s" % [room_code, line])


## Remove a room and its bot players. Called when game ends or all players leave.
## Logs are preserved — room code moves to archived_rooms for the admin log page.
func cleanup_room(room_code: String) -> void:
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	var created_at: int = room.get("created_at", 0)
	var room_duration: float = 0.0
	if created_at > 0:
		room_duration = (Time.get_ticks_msec() - created_at) / 1000.0

	# Free game instance if active
	var gm: Node = room.get("game_manager")
	if gm != null and is_instance_valid(gm):
		gm.queue_free()

	# Clean up bot player entries
	for bot_peer: int in room.get("bots", []):
		players.erase(bot_peer)
	# Clean up any remaining real player entries for this room
	for pid: int in room["players"]:
		if pid in players:
			players.erase(pid)
	_rooms.erase(room_code)
	# Archive for logs (don't duplicate)
	if room_code not in archived_rooms:
		archived_rooms.append(room_code)
	print("[SERVER] Room %s cleaned up and archived (duration=%.1fs, players=%d)" % [
		room_code, room_duration, room["players"].size()])


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg == "--server":
			is_server_mode = true
			break

	if DisplayServer.get_name() == "headless":
		is_server_mode = true

	if is_server_mode:
		_start_dedicated_server()


func _process(delta: float) -> void:
	if not is_server_mode:
		return

	# Handle countdown for each room
	for code: String in _rooms:
		var room: Dictionary = _rooms[code]
		if room["countdown"] > 0.0:
			room["countdown"] -= delta
			var secs := ceili(room["countdown"])
			if secs != room.get("last_tick", -1):
				room["last_tick"] = secs
				# Broadcast countdown to real players (not bots)
				for pid: int in room["players"]:
					if pid > 0:
						_rpc_countdown_tick.rpc_id(pid, secs)
				print("[SERVER] Room %s: Starting in %d..." % [code, secs])

			if room["countdown"] <= 0.0:
				_start_room_game(code)


func _start_dedicated_server() -> void:
	var port := PORT
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i].begins_with("--port="):
			port = int(args[i].split("=")[1])

	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 1048576  # 1MB
	var err := peer.create_server(port)
	if err != OK:
		print("[SERVER] Failed to create WebSocket server on port %d: %s" % [port, error_string(err)])
		return

	multiplayer.multiplayer_peer = peer
	my_peer_id = 1
	print("[SERVER] Deadly Pool WebSocket server started on port %d" % port)
	print("[SERVER] Waiting for players to create or join rooms...")

	# Create persistent container for game instances
	_room_container = Node.new()
	_room_container.name = "RoomContainer"
	get_tree().root.add_child.call_deferred(_room_container)


func connect_to_server(ip: String, player_name: String) -> void:
	my_name = player_name
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 1048576  # 1MB — prevent "Buffer payload full" drops
	# Build WebSocket URL from ip/hostname
	var url: String
	if ip.begins_with("ws://") or ip.begins_with("wss://"):
		url = ip
	elif ip == "localhost" or ip == "127.0.0.1":
		url = "ws://%s:%d" % [ip, PORT]
	else:
		# Remote server: connect via Caddy reverse proxy path
		url = "wss://%s/ws" % ip
	var err := peer.create_client(url)
	if err != OK:
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer


func create_room() -> void:
	_rpc_create_room.rpc_id(1, my_name)


func join_room(code: String) -> void:
	_rpc_join_room.rpc_id(1, code.to_upper(), my_name)


func query_rooms() -> void:
	_rpc_query_rooms.rpc_id(1)


func start_countdown() -> void:
	if current_room.is_empty():
		return
	_rpc_request_start.rpc_id(1, current_room)


func request_add_bot() -> void:
	if current_room.is_empty():
		return
	_rpc_request_add_bot.rpc_id(1, current_room)


func request_remove_bot(bot_peer_id: int) -> void:
	if current_room.is_empty():
		return
	_rpc_request_remove_bot.rpc_id(1, current_room, bot_peer_id)


func start_single_player(player_name: String, bot_count: int) -> void:
	is_single_player = true
	my_name = player_name
	my_slot = 0
	my_peer_id = 1
	current_room = "SOLO"
	bot_slots.clear()

	# Slot 0 = human player
	players[1] = {"name": player_name.substr(0, 20), "slot": 0, "room": "SOLO"}

	# Slots 1..bot_count = bots
	var bot_names: Array[String] = ["Bot 1", "Bot 2", "Bot 3"]
	for i in bot_count:
		var slot := i + 1
		var fake_peer := slot + 100  # Fake peer IDs for bots
		players[fake_peer] = {"name": bot_names[i], "slot": slot, "room": "SOLO"}
		bot_slots.append(slot)

	get_tree().change_scene_to_file("res://scenes/main.tscn")


func end_single_player() -> void:
	is_single_player = false
	players.clear()
	my_peer_id = 0
	my_slot = -1
	current_room = ""
	bot_slots.clear()
	room_scores.clear()


func disconnect_from_server() -> void:
	if is_single_player:
		end_single_player()
		return
	multiplayer.multiplayer_peer = null
	players.clear()
	my_peer_id = 0
	my_slot = -1
	current_room = ""
	room_scores.clear()


func get_player_count() -> int:
	return players.size()


func get_slot_peer(slot: int) -> int:
	for peer_id: int in players:
		if players[peer_id]["slot"] == slot:
			return peer_id
	return -1


func is_room_creator() -> bool:
	if is_server_mode:
		return false
	if current_room.is_empty():
		return false
	# The creator is the one with slot 0 in this room
	return my_slot == 0


# --- Room code generation ---

func _generate_room_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # No I/O/0/1 to avoid confusion
	var code := ""
	for _i in 5:
		code += chars[randi() % chars.length()]
	return code


# --- Connection callbacks ---

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	print("[SERVER] Peer %d connected (not in a room yet)" % id)


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return

	# Bot fake peers never disconnect via network
	if id < 0:
		return

	if id not in players:
		return

	var pdata: Dictionary = players[id]
	var room_code: String = pdata.get("room", "")
	var slot: int = pdata["slot"]
	print("[SERVER] Player disconnected: peer %d (slot %d, room %s)" % [id, slot, room_code])

	players.erase(id)
	player_disconnected.emit(id)

	if room_code in _rooms:
		var room: Dictionary = _rooms[room_code]
		room["players"].erase(id)

		# Check if any real players remain
		var real_players := 0
		for pid: int in room["players"]:
			if pid > 0:
				real_players += 1

		# Cancel countdown if below 2 total players
		if room["players"].size() < 2:
			room["countdown"] = -1.0

		if real_players == 0 or room["players"].size() == 0:
			cleanup_room(room_code)
		else:
			_broadcast_room_lobby(room_code)


func _on_connected_to_server() -> void:
	my_peer_id = multiplayer.get_unique_id()
	print("Connected to server as peer %d" % my_peer_id)
	player_connected.emit(my_peer_id)


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


func _on_server_disconnected() -> void:
	print("Server disconnected")
	multiplayer.multiplayer_peer = null
	players.clear()
	my_peer_id = 0
	my_slot = -1
	current_room = ""
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# --- Server-side room management ---

func _assign_slot_in_room(room_code: String) -> int:
	var used_slots: Array[int] = []
	for pid: int in players:
		if players[pid].get("room", "") == room_code:
			used_slots.append(players[pid]["slot"] as int)

	for s in MAX_PLAYERS:
		if s not in used_slots:
			return s
	return -1


func _broadcast_room_lobby(room_code: String) -> void:
	if room_code not in _rooms:
		return

	var room: Dictionary = _rooms[room_code]
	var lobby_data: Array[Dictionary] = []

	for pid: int in room["players"]:
		if pid in players:
			lobby_data.append({
				"peer_id": pid,
				"name": players[pid]["name"],
				"slot": players[pid]["slot"],
				"is_bot": players[pid].get("is_bot", false),
			})

	var creator_id: int = room["creator"]

	# Only send to real players (positive peer IDs), not bots
	for pid: int in room["players"]:
		if pid > 0:
			_rpc_lobby_update.rpc_id(pid, lobby_data, room_code, creator_id)


func _start_room_game(room_code: String) -> void:
	if room_code not in _rooms:
		return

	var room: Dictionary = _rooms[room_code]
	if room["started"]:
		return

	room["started"] = true
	room["countdown"] = -1.0

	# Build bot_slots from room bots
	var room_bot_slots: Array[int] = []
	for bot_peer: int in room["bots"]:
		if bot_peer in players:
			room_bot_slots.append(players[bot_peer]["slot"] as int)
	room["bot_slots"] = room_bot_slots

	# Initialize scores if not present
	if not room.has("scores"):
		room["scores"] = {}

	print("[SERVER] Starting game for room %s with %d players (%d bots)" % [room_code, room["players"].size(), room_bot_slots.size()])

	# Notify real players in this room (not bots)
	for pid: int in room["players"]:
		if pid > 0:
			_rpc_start_game.rpc_id(pid)

	# Instantiate game scene as sub-scene (deferred to avoid mid-frame issues)
	var room_index := _room_index_counter
	_room_index_counter += 1
	room["room_index"] = room_index
	_instantiate_room_game.call_deferred(room_code, room_index)


func _instantiate_room_game(room_code: String, room_index: int) -> void:
	if _room_container == null or room_code not in _rooms:
		return
	var game_instance: Node3D = MAIN_SCENE.instantiate()
	game_instance.name = "Room_%s" % room_code
	# Spatial offset for physics isolation
	game_instance.position = Vector3(room_index * ROOM_SPACING, 0, 0)
	# Store room_code as meta so GameManager can find its room
	game_instance.set_meta("room_code", room_code)
	_room_container.add_child(game_instance)
	# Store reference for cleanup
	_rooms[room_code]["game_manager"] = game_instance


## Get the GameManager node for a given peer's room (server-side)
func _get_game_manager_for_peer(peer_id: int) -> Node:
	if peer_id not in players:
		return null
	var room_code: String = players[peer_id].get("room", "")
	if room_code.is_empty() or room_code not in _rooms:
		return null
	var gm = _rooms[room_code].get("game_manager")
	if gm != null and is_instance_valid(gm):
		return gm
	return null


## Get the GameManager on the client (current scene root)
func _get_client_game_manager() -> Node:
	var scene := get_tree().current_scene
	if scene and scene.has_method("client_receive_state"):
		return scene
	return null


## Get all real peer IDs in a room
func get_room_peers(room_code: String) -> Array[int]:
	var peers: Array[int] = []
	if room_code.is_empty() or room_code not in _rooms:
		return peers
	var room: Dictionary = _rooms[room_code]
	for pid: int in room["players"]:
		if pid > 0:
			peers.append(pid)
	return peers


## Broadcast a game RPC to all real peers in a room (server-side helper)
func broadcast_to_room(room_code: String, rpc_method: Callable, args: Array) -> void:
	for pid in get_room_peers(room_code):
		rpc_method.rpc_id(pid, args)


# --- RPCs: Client -> Server (Lobby) ---

@rpc("any_peer", "call_remote", "reliable")
func _rpc_create_room(player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var sender := multiplayer.get_remote_sender_id()

	# Check if already in a room
	if sender in players and players[sender].get("room", "") != "":
		return

	# Generate unique code
	var code := _generate_room_code()
	while code in _rooms:
		code = _generate_room_code()

	# Create the room
	_rooms[code] = {
		"players": [sender],
		"started": false,
		"countdown": -1.0,
		"creator": sender,
		"last_tick": -1,
		"bots": [],  # Negative fake peer IDs for bots
		"bot_id_counter": 0,  # Monotonic counter for unique bot IDs
		"created_at": Time.get_ticks_msec(),
		"scores": {},
		"bot_slots": [],
		"game_manager": null,
		"room_index": -1,
	}

	# Register the player
	players[sender] = {
		"name": player_name.substr(0, 20),
		"slot": 0,
		"room": code,
	}

	print("[SERVER] Room %s created by peer %d (%s)" % [code, sender, player_name])

	_rpc_assign_slot.rpc_id(sender, 0)
	_rpc_room_created.rpc_id(sender, code)
	_broadcast_room_lobby(code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_room(code: String, player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var sender := multiplayer.get_remote_sender_id()

	if code not in _rooms:
		_rpc_room_join_failed.rpc_id(sender, "Room not found")
		return

	var room: Dictionary = _rooms[code]

	if room["started"]:
		_rpc_room_join_failed.rpc_id(sender, "Game already in progress")
		return

	if room["players"].size() >= MAX_PLAYERS:
		_rpc_room_join_failed.rpc_id(sender, "Room is full")
		return

	var slot := _assign_slot_in_room(code)
	if slot == -1:
		_rpc_room_join_failed.rpc_id(sender, "No slots available")
		return

	# Add player to room
	room["players"].append(sender)
	players[sender] = {
		"name": player_name.substr(0, 20),
		"slot": slot,
		"room": code,
	}

	print("[SERVER] Peer %d (%s) joined room %s as slot %d (%d/%d)" % [
		sender, player_name, code, slot, room["players"].size(), MAX_PLAYERS
	])

	_rpc_assign_slot.rpc_id(sender, slot)
	_rpc_room_joined.rpc_id(sender, code)
	_broadcast_room_lobby(code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_query_rooms() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var result: Array = []
	for code in _rooms:
		var room: Dictionary = _rooms[code]
		if room["started"]:
			continue
		var total: int = room["players"].size()
		if total >= MAX_PLAYERS:
			continue
		var creator_id: int = room["creator"]
		var creator_name: String = players[creator_id].get("name", "?") if creator_id in players else "?"
		result.append({
			"code": code,
			"players": total - room["bots"].size(),
			"bots": room["bots"].size(),
			"max": MAX_PLAYERS,
			"creator": creator_name,
		})
	_rpc_rooms_list.rpc_id(sender, result)


@rpc("authority", "call_remote", "reliable")
func _rpc_rooms_list(rooms: Array) -> void:
	rooms_list_received.emit(rooms)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start(room_code: String) -> void:
	if not multiplayer.is_server():
		return

	var sender := multiplayer.get_remote_sender_id()

	if room_code not in _rooms:
		return

	var room: Dictionary = _rooms[room_code]

	# Only room creator can start
	if room["creator"] != sender:
		return

	if room["players"].size() < 2:
		print("[SERVER] Room %s: Not enough players to start" % room_code)
		return

	if room["countdown"] > 0.0:
		return  # Already counting down

	room["countdown"] = float(COUNTDOWN_SECONDS)
	room["last_tick"] = -1
	print("[SERVER] Room %s: Countdown started (%ds)" % [room_code, COUNTDOWN_SECONDS])


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_add_bot(room_code: String) -> void:
	if not multiplayer.is_server():
		return

	var sender := multiplayer.get_remote_sender_id()

	if room_code not in _rooms:
		return

	var room: Dictionary = _rooms[room_code]

	if room["creator"] != sender:
		return
	if room["started"]:
		return
	if room["players"].size() >= MAX_PLAYERS:
		return

	var slot := _assign_slot_in_room(room_code)
	if slot == -1:
		return

	# Generate unique negative fake peer ID (monotonic, never reused)
	room["bot_id_counter"] += 1
	var fake_peer: int = -room["bot_id_counter"]

	var bot_num: int = room["bot_id_counter"]
	var bot_name := "Bot %d" % bot_num

	players[fake_peer] = {
		"name": bot_name,
		"slot": slot,
		"room": room_code,
		"is_bot": true,
	}
	room["players"].append(fake_peer)
	room["bots"].append(fake_peer)

	print("[SERVER] Room %s: Added %s (slot %d, fake_peer %d)" % [room_code, bot_name, slot, fake_peer])
	_broadcast_room_lobby(room_code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_remove_bot(room_code: String, bot_peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	var sender := multiplayer.get_remote_sender_id()

	if room_code not in _rooms:
		return

	var room: Dictionary = _rooms[room_code]

	if room["creator"] != sender:
		return
	if room["started"]:
		return

	# Validate this is actually a bot in this room
	if bot_peer_id not in room["bots"]:
		return

	var bot_name: String = players[bot_peer_id]["name"] if bot_peer_id in players else "Bot"
	players.erase(bot_peer_id)
	room["players"].erase(bot_peer_id)
	room["bots"].erase(bot_peer_id)

	print("[SERVER] Room %s: Removed %s (fake_peer %d)" % [room_code, bot_name, bot_peer_id])
	_broadcast_room_lobby(room_code)


# --- RPCs: Server -> Client (Lobby) ---

@rpc("authority", "call_remote", "reliable")
func _rpc_assign_slot(slot: int) -> void:
	my_slot = slot
	print("Assigned to slot %d" % slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_room_created(code: String) -> void:
	current_room = code
	room_created.emit(code)


@rpc("authority", "call_remote", "reliable")
func _rpc_room_joined(code: String) -> void:
	current_room = code
	room_joined.emit(code)


@rpc("authority", "call_remote", "reliable")
func _rpc_room_join_failed(reason: String) -> void:
	room_join_failed.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(lobby_data: Array[Dictionary], room_code: String, _creator_id: int) -> void:
	players.clear()
	for entry: Dictionary in lobby_data:
		var peer_id: int = entry["peer_id"]
		players[peer_id] = {
			"name": entry["name"],
			"slot": entry["slot"],
			"room": room_code,
			"is_bot": entry.get("is_bot", false),
		}
	current_room = room_code
	lobby_updated.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_countdown_tick(seconds_left: int) -> void:
	countdown_tick.emit(seconds_left)


@rpc("authority", "call_remote", "reliable")
func _rpc_start_game() -> void:
	game_starting.emit()
	# Change scene directly - this is the authoritative signal to start the game
	get_tree().change_scene_to_file("res://scenes/main.tscn")


# ============================================================
# Game RPCs — proxied through NetworkManager for path-safe routing
# (GameManager lives at different paths on server vs client)
# ============================================================

# --- Client -> Server game RPCs ---

@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_client_ready() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var gm := _get_game_manager_for_peer(sender)
	if gm:
		gm.server_handle_client_ready(sender)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_request_launch(slot: int, direction: Vector3, power: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var gm := _get_game_manager_for_peer(sender)
	if gm:
		gm.server_handle_request_launch(sender, slot, direction, power)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_activate_powerup(slot: int, powerup_type: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var gm := _get_game_manager_for_peer(sender)
	if gm:
		gm.server_handle_activate_powerup(sender, slot, powerup_type)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_game_send_aim(slot: int, direction: Vector3, power: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var gm := _get_game_manager_for_peer(sender)
	if gm:
		gm.server_handle_send_aim(sender, slot, direction, power)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_perf_report(report: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var room_code: String = players[sender].get("room", "???") if sender in players else "???"
	var pname: String = players[sender].get("name", "???") if sender in players else "???"
	var parts := report.split("|")
	if parts.size() >= 5:
		room_log(room_code, "CLIENT_PERF [%s] peer=%d fps_avg=%s fps_min=%s sync=%s/s ping=%sms gpu=%s" % [
			pname, sender, parts[1], parts[2], parts[3], parts[4], parts[0]])
	elif parts.size() >= 4:
		room_log(room_code, "CLIENT_PERF [%s] peer=%d fps_avg=%s fps_min=%s sync=%s/s gpu=%s" % [
			pname, sender, parts[1], parts[2], parts[3], parts[0]])


# --- Ping system ---

var client_ping_ms: float = -1.0
var _ping_send_time: float = 0.0

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping(client_time: float) -> void:
	# Server receives ping, echoes back
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
		_rpc_pong.rpc_id(sender, client_time)

@rpc("authority", "call_remote", "reliable")
func _rpc_pong(client_time: float) -> void:
	# Client receives pong, calculates RTT
	if not multiplayer.is_server():
		var now := Time.get_ticks_msec() / 1000.0
		client_ping_ms = (now - client_time) * 1000.0

func send_ping() -> void:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return
	_rpc_ping.rpc_id(1, Time.get_ticks_msec() / 1000.0)


# --- Server -> Client game RPCs ---

@rpc("authority", "call_remote", "reliable")
func _rpc_game_spawn_balls(spawn_data: Array[Dictionary], alive: Array[int]) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_spawn_balls(spawn_data, alive)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_game_sync_state(positions: PackedVector3Array, rotations: PackedVector3Array, lin_vels: PackedVector3Array) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_state(positions, rotations, lin_vels)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_ball_pocketed(slot: int, pocket_pos: Vector3) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_ball_pocketed(slot, pocket_pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_player_eliminated(slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_player_eliminated(slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_player_disconnected(slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_player_disconnected(slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_over(winner_slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_game_over(winner_slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_sync_scores(scores: Dictionary) -> void:
	room_scores = scores
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_sync_scores(scores)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_restart() -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_restart()


@rpc("authority", "call_remote", "reliable")
func _rpc_game_spawn_powerup(id: int, type: int, pos_x: float, pos_z: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_spawn_powerup(id, type, pos_x, pos_z)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_powerup_picked_up(powerup_id: int, slot: int, type: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_powerup_picked_up(powerup_id, slot, type)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_powerup_consumed(slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_powerup_consumed(slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_shockwave_effect(pos_x: float, pos_z: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_shockwave_effect(pos_x, pos_z)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_powerup_armed(slot: int, type: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_powerup_armed(slot, type)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_speed_boost(slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_speed_boost(slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_anchor_effect(slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_anchor_effect(slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_anchor_trap_placed(slot: int, pos_x: float, pos_z: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_anchor_trap_placed(slot, pos_x, pos_z)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_game_receive_aim(slot: int, direction: Vector3, power: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_aim(slot, direction, power)


@rpc("authority", "call_remote", "unreliable")
func _rpc_game_collision_effect(pos: Vector3, color: Color, intensity: float, sound_slot: int, is_wall: bool, sound_speed: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_collision_effect(pos, color, intensity, sound_slot, is_wall, sound_speed)
