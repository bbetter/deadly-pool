extends Node
class_name RoomNetworkManagerBase
## Base class for a server-authoritative WebSocket room/lobby system.
##
## Subclass this in your game's NetworkManager autoload and:
##   1. Set configuration properties in _ready() before calling super._ready().
##   2. Override virtual hooks to apply game-specific settings.
##   3. Add game-specific RPCs and helpers as normal GDScript methods.
##
## Example minimal subclass:
##   extends RoomNetworkManagerBase
##   func _ready() -> void:
##       port = 8910
##       max_players = 2
##       game_scene_path = "res://scenes/main.tscn"
##       proxy_ws_path = "/mygame/ws"
##       super._ready()


# ─── Configuration ──────────────────────────────────────────────────────────────

## TCP port the dedicated server listens on.
var port: int = 9876

## Maximum human (non-bot) players per room.
var max_players: int = 8

## Minimum human players required before the room creator can start the game.
## Defaults to 2.  Set equal to max_players to require a full room.
var min_players_to_start: int = 2

## Seconds of countdown broadcast to clients before the game scene loads.
var countdown_seconds: int = 5

## Packed scene path loaded via get_tree().change_scene_to_file() on clients.
var game_scene_path: String = "res://scenes/main.tscn"

## Scene path used by _on_server_disconnected to return clients to the menu.
var main_menu_scene_path: String = "res://scenes/main_menu.tscn"

## Caddy / nginx reverse-proxy WebSocket path appended to remote hostnames.
## E.g. "/dp/ws" → wss://example.com/dp/ws
var proxy_ws_path: String = "/ws"

## Label used in all server-side log messages.
var server_display_name: String = "Game"

## When true, only rooms that are not yet started and not full appear in query results.
## When false, started rooms also appear (useful for spectator-join games).
var list_only_joinable_rooms: bool = true


## Controls how the game scene is placed on the server when a room starts.
enum GameInstantiationMode {
	## Scene added directly to /root.  Its name must match game_scene_root_name so
	## client RPCs (which resolve paths from /root/<name>) work without proxying.
	## Good when the server hosts a single room at a time.
	SHARED_ROOT,
	## Scene placed in a container node, offset spatially per room.
	## Allows many simultaneous rooms on one server with full physics isolation.
	SPATIAL_CONTAINER,
}
var instantiation_mode: GameInstantiationMode = GameInstantiationMode.SHARED_ROOT

## Node name assigned to the game scene instance in SHARED_ROOT mode.
## Must match the root node name inside game_scene_path.
var game_scene_root_name: String = "Main"

## World-space distance between room game instances in SPATIAL_CONTAINER mode.
var spatial_room_spacing: float = 1000.0


# ─── State ──────────────────────────────────────────────────────────────────────

## peer_id → { "name": String, "slot": int, "room": String, ... }
## On clients this only contains peers in the current lobby (populated by server).
var players: Dictionary = {}

var my_peer_id: int = 0
var my_slot: int = -1
var my_name: String = "Player"
var is_server_mode: bool = false
var _server_ip: String = ""

## The room code the local client is currently in (empty when not in a room).
var current_room: String = ""

# Server-only:
# room_code → { players, started, countdown, last_tick, creator, created_at,
#               game_manager, settings, create_settings }
var _rooms: Dictionary = {}
var _room_container: Node = null   # used in SPATIAL_CONTAINER mode
var _room_index_counter: int = 0


# ─── Signals ────────────────────────────────────────────────────────────────────

## Emitted on the client when it successfully connects to the server.
signal player_connected(peer_id: int)

## Emitted on the server when a previously-registered player drops.
signal player_disconnected(peer_id: int)

## Emitted on the client whenever the lobby player list changes.
signal lobby_updated()

## Emitted on the client when the WebSocket connection attempt fails.
signal connection_failed()

## Emitted on the client (just before scene change) when the game is starting.
## `settings` contains whatever Dictionary was passed to start_countdown().
signal game_starting(settings: Dictionary)

## Emitted on the client for each countdown tick (seconds_left counts down to 1).
signal countdown_tick(seconds_left: int)

## Emitted on the client after the server confirms room creation.
signal room_created(code: String)

## Emitted on the client after successfully joining a room.
signal room_joined(code: String)

## Emitted on the client when a join attempt is rejected (includes reason string).
signal room_join_failed(reason: String)

## Emitted on the client with the rooms array returned by query_rooms().
signal rooms_list_received(rooms: Array)

## Emitted on the SERVER when a previously-disconnected peer rejoins an in-progress game.
signal peer_reconnected_in_game(peer_id: int, slot: int)

## Emitted on CLIENTS when a peer disconnects mid-game (slot held for 30s).
signal peer_left_mid_game(slot: int, player_name: String)


# ─── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	for arg in OS.get_cmdline_user_args():
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

	# Countdown reconnect grace timers for mid-game disconnects
	for code: String in _rooms.duplicate():
		var room: Dictionary = _rooms[code]
		if not room.get("dc_peers", {}).is_empty():
			for dc_id: int in room["dc_peers"].duplicate():
				room["dc_peers"][dc_id]["timer"] -= delta
				if room["dc_peers"][dc_id]["timer"] <= 0.0:
					var dcdata: Dictionary = room["dc_peers"][dc_id]
					room["dc_peers"].erase(dc_id)
					print("[%s] Reconnect window expired for %s (slot %d)" % [
						server_display_name, dcdata["name"], dcdata["slot"]])
					if room["players"].is_empty() and room["dc_peers"].is_empty():
						cleanup_room(code)
						break

	for code: String in _rooms:
		var room: Dictionary = _rooms[code]
		if room["countdown"] > 0.0:
			room["countdown"] -= delta
			var secs := ceili(room["countdown"])
			if secs != room.get("last_tick", -1):
				room["last_tick"] = secs
				for pid: int in room["players"]:
					if pid > 0:
						_rpc_countdown_tick.rpc_id(pid, secs)
				print("[%s] Room %s: starting in %d..." % [server_display_name, code, secs])
			if room["countdown"] <= 0.0:
				_start_room_game(code)


# ─── Public client API ──────────────────────────────────────────────────────────

## Connect to a server.  `ip` may be:
##   - A full WebSocket URL (ws:// or wss://)
##   - "localhost" or "127.0.0.1"  →  ws://ip:port
##   - Any other hostname          →  wss://hostname<proxy_ws_path>
func connect_to_server(ip: String, player_name: String) -> void:
	my_name = player_name
	_server_ip = ip
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 1048576
	var url: String
	if ip.begins_with("ws://") or ip.begins_with("wss://"):
		url = ip
	elif ip == "localhost" or ip == "127.0.0.1":
		url = "ws://%s:%d" % [ip, port]
	else:
		url = "wss://%s%s" % [ip, proxy_ws_path]
	var err := peer.create_client(url)
	if err != OK:
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer


## Ask the server to create a new room.
## `create_settings` is passed to _sanitize_create_settings() on the server
## and stored as room["create_settings"] for use by _get_room_extra_display_info().
func create_room(create_settings: Dictionary = {}) -> void:
	_rpc_create_room.rpc_id(1, my_name, create_settings)


## Ask the server to join the room with the given code.
func join_room(code: String) -> void:
	_rpc_join_room.rpc_id(1, code.strip_edges().to_upper(), my_name)


## Request the current room list from the server.  Listen for rooms_list_received.
func query_rooms() -> void:
	_rpc_query_rooms.rpc_id(1)


## Start the countdown (only the room creator's call is accepted by the server).
## `game_settings` is forwarded to all clients via _rpc_start_game and stored in
## room["settings"].  Override _sanitize_game_settings() to validate/clamp values.
func start_countdown(game_settings: Dictionary = {}) -> void:
	if current_room.is_empty():
		return
	_rpc_request_start.rpc_id(1, current_room, game_settings)


## Cleanly disconnect from the server and reset local state.
func disconnect_from_server() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null
	players.clear()
	my_peer_id = 0
	my_slot = -1
	current_room = ""


# ─── Public helpers ─────────────────────────────────────────────────────────────

## Returns true if the local client is the creator of their current room.
func is_room_creator() -> bool:
	return not is_server_mode and not current_room.is_empty() and my_slot == 0


## Returns true for all positive peer IDs that are not the server (peer 1).
## Override if your game uses a different convention.
func is_player_peer(peer_id: int) -> bool:
	return peer_id > 1


func get_player_count() -> int:
	return players.size()


## Returns the peer ID assigned to a given slot, or -1 if not found.
func get_slot_peer(slot: int) -> int:
	for pid: int in players:
		if players[pid]["slot"] == slot:
			return pid
	return -1


## Returns all real (positive) peer IDs currently in a room.  Server-side only.
func get_room_peers(room_code: String) -> Array[int]:
	var peers: Array[int] = []
	if room_code in _rooms:
		for pid: int in _rooms[room_code]["players"]:
			if pid > 0:
				peers.append(pid)
	return peers


## Returns the game scene node for the room the given peer is in.  Server-side only.
func get_game_manager_for_peer(peer_id: int) -> Node:
	if peer_id not in players:
		return null
	var room_code: String = players[peer_id].get("room", "")
	if room_code.is_empty() or room_code not in _rooms:
		return null
	var gm = _rooms[room_code].get("game_manager")
	return gm if gm != null and is_instance_valid(gm) else null


## Broadcast an RPC to all real players in a room.  Server-side only.
## Example: broadcast_to_room(my_room, _rpc_some_event.bind(arg1, arg2))
func broadcast_to_room(room_code: String, bound_callable: Callable) -> void:
	for pid in get_room_peers(room_code):
		bound_callable.call(pid)


# ─── Virtual hooks ──────────────────────────────────────────────────────────────

## SERVER — called just before the game scene is instantiated.
## Use to apply validated room settings to server-side singletons (e.g. Globals).
func _on_server_before_game_start(_room_code: String, _settings: Dictionary) -> void:
	pass


## CLIENT — called inside _rpc_start_game, before scene change.
## Use to apply game settings received from the server (e.g. Globals.difficulty).
func _on_client_before_game_start(_settings: Dictionary) -> void:
	pass


## SERVER — validate/clamp game_settings passed to start_countdown().
## Return the sanitized dictionary that gets stored in room["settings"].
func _sanitize_game_settings(settings: Dictionary) -> Dictionary:
	return settings


## SERVER — validate/clamp create_settings passed to create_room().
## Return the sanitized dictionary stored in room["create_settings"].
func _sanitize_create_settings(settings: Dictionary) -> Dictionary:
	return settings


## SERVER — return extra fields to merge into each room entry in query results.
## `room` is the server-side room dictionary.
func _get_room_extra_display_info(_room: Dictionary) -> Dictionary:
	return {}


## SERVER — called after a player's entry is removed from room["players"] on disconnect.
## Use to clean up spectator lists, bot arrays, pending queues, etc.
## Default: cancels the countdown if below min_players_to_start.
func _on_player_left_room(_peer_id: int, _room_code: String, room: Dictionary) -> void:
	var human_count := 0
	for pid: int in room["players"]:
		if pid > 0:
			human_count += 1
	if human_count < min_players_to_start:
		room["countdown"] = -1.0


## SERVER — called at the start of cleanup_room(), before the game node and player
## entries are freed.  Use to erase bot player entries or other room-specific state.
func _on_cleanup_room(_room_code: String, _room: Dictionary) -> void:
	pass


## SERVER — return false to hide a room from query_rooms() results.
## Default: hide started rooms (if list_only_joinable_rooms) and full non-started rooms.
func _should_include_room_in_list(room: Dictionary) -> bool:
	if room["players"].size() >= max_players and not room["started"]:
		return false  # totally full before game started
	if list_only_joinable_rooms and room["started"]:
		return false
	return true


# ─── Server internals ───────────────────────────────────────────────────────────

func _start_dedicated_server() -> void:
	var p := port
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			p = int(arg.split("=")[1])

	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 1048576
	var err := peer.create_server(p)
	if err != OK:
		print("[%s] Failed to start server on port %d: %s" % [server_display_name, p, error_string(err)])
		return

	multiplayer.multiplayer_peer = peer
	my_peer_id = 1
	print("[%s] Server started on port %d" % [server_display_name, p])

	if instantiation_mode == GameInstantiationMode.SPATIAL_CONTAINER:
		_room_container = Node.new()
		_room_container.name = "RoomContainer"
		get_tree().root.add_child.call_deferred(_room_container)


func _generate_room_code() -> String:
	const CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no I/O/0/1
	var code := ""
	for _i in 5:
		code += CHARS[randi() % CHARS.length()]
	return code


func _assign_slot_in_room(room_code: String) -> int:
	var used: Array[int] = []
	for pid: int in players:
		if players[pid].get("room", "") == room_code:
			used.append(players[pid]["slot"] as int)
	for s in max_players:
		if s not in used:
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
				"name":     players[pid]["name"],
				"slot":     players[pid]["slot"],
				"is_bot":   players[pid].get("is_bot", false),
				"spectator": players[pid].get("spectator", false),
			})
	for pid: int in room["players"]:
		if pid > 0:
			_rpc_lobby_update.rpc_id(pid, lobby_data, room_code, room["creator"])


func _start_room_game(room_code: String) -> void:
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	if room["started"]:
		return

	room["started"] = true
	room["countdown"] = -1.0
	var settings: Dictionary = room.get("settings", {})

	print("[%s] Starting game for room %s (%d players)" % [
		server_display_name, room_code, room["players"].size()])

	_on_server_before_game_start(room_code, settings)

	for pid: int in room["players"]:
		if pid > 0:
			_rpc_start_game.rpc_id(pid, settings)

	_instantiate_room_game.call_deferred(room_code)


func _instantiate_room_game(room_code: String) -> void:
	if room_code not in _rooms:
		return
	var scene := load(game_scene_path) as PackedScene
	if scene == null:
		push_error("[%s] Cannot load game_scene_path: %s" % [server_display_name, game_scene_path])
		return
	var game_instance: Node = scene.instantiate()
	game_instance.set_meta("room_code", room_code)

	match instantiation_mode:
		GameInstantiationMode.SHARED_ROOT:
			game_instance.name = game_scene_root_name
			get_tree().root.add_child(game_instance)

		GameInstantiationMode.SPATIAL_CONTAINER:
			if _room_container == null:
				push_error("[%s] _room_container is null — SPATIAL_CONTAINER requires it" % server_display_name)
				return
			var idx := _room_index_counter
			_room_index_counter += 1
			game_instance.name = "Room_%s" % room_code
			if game_instance is Node3D:
				(game_instance as Node3D).position = Vector3(idx * spatial_room_spacing, 0.0, 0.0)
			_room_container.add_child(game_instance)

	_rooms[room_code]["game_manager"] = game_instance


## Remove a room and free its game scene.  Safe to call on an already-gone room.
func cleanup_room(room_code: String) -> void:
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	_on_cleanup_room(room_code, room)

	var gm: Node = room.get("game_manager")
	if gm != null and is_instance_valid(gm):
		gm.queue_free()

	for pid: int in room["players"]:
		if pid in players:
			players.erase(pid)

	_rooms.erase(room_code)
	print("[%s] Room %s cleaned up" % [server_display_name, room_code])


# ─── Connection callbacks ────────────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	print("[%s] Peer %d connected" % [server_display_name, id])


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if id not in players:
		return

	var pdata: Dictionary = players[id]
	var room_code: String = pdata.get("room", "")
	print("[%s] Peer %d disconnected (slot %d, room %s)" % [
		server_display_name, id, pdata.get("slot", -1), room_code])

	players.erase(id)
	player_disconnected.emit(id)

	if room_code in _rooms:
		var room: Dictionary = _rooms[room_code]
		room["players"].erase(id)
		_on_player_left_room(id, room_code, room)

		# Mid-game disconnect: hold the slot for 30 seconds to allow rejoin
		if room["started"]:
			room.get_or_add("dc_peers", {})[id] = {
				"name": pdata["name"],
				"slot": pdata["slot"],
				"timer": 30.0,
			}
			print("[%s] Room %s: holding slot %d for %s (30s reconnect window)" % [
				server_display_name, room_code, pdata["slot"], pdata["name"]])
			_rpc_peer_left_mid_game.rpc(pdata["slot"], pdata["name"])
			return  # Don't clean up room

		if room["players"].is_empty():
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
	var was_in_game := not current_room.is_empty()
	var saved_room := current_room
	multiplayer.multiplayer_peer = null
	players.clear()
	my_peer_id = 0
	my_slot = -1
	current_room = ""
	if was_in_game and _on_disconnected_mid_game(saved_room):
		return  # subclass handled the scene transition
	get_tree().change_scene_to_file(main_menu_scene_path)


## Override to intercept mid-game disconnects. Return true to prevent the
## default scene change (the override is then responsible for scene navigation).
func _on_disconnected_mid_game(_room_code: String) -> bool:
	return false


# ─── RPCs: Client → Server ───────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func _rpc_query_rooms() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var result: Array = []
	for code: String in _rooms:
		var room: Dictionary = _rooms[code]
		if not _should_include_room_in_list(room):
			continue
		var creator_id: int = room["creator"]
		var creator_name: String = players.get(creator_id, {}).get("name", "?")
		var entry := {
			"code":    code,
			"players": room["players"].size(),
			"max":     max_players,
			"creator": creator_name,
			"started": room["started"],
		}
		entry.merge(_get_room_extra_display_info(room))
		result.append(entry)
	_rpc_rooms_list.rpc_id(sender, result)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_create_room(player_name: String, create_settings: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender in players and players[sender].get("room", "") != "":
		return

	var code := _generate_room_code()
	while code in _rooms:
		code = _generate_room_code()

	_rooms[code] = {
		"players":        [sender],
		"started":        false,
		"countdown":      -1.0,
		"last_tick":      -1,
		"creator":        sender,
		"created_at":     Time.get_ticks_msec(),
		"game_manager":   null,
		"settings":       {},
		"create_settings": _sanitize_create_settings(create_settings),
	}
	players[sender] = {
		"name": player_name.substr(0, 20),
		"slot": 0,
		"room": code,
	}
	print("[%s] Room %s created by peer %d (%s)" % [server_display_name, code, sender, player_name])
	_rpc_assign_slot.rpc_id(sender, 0)
	_rpc_room_created.rpc_id(sender, code)
	_broadcast_room_lobby(code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_room(code: String, player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()

	if code not in _rooms:
		_rpc_room_join_failed.rpc_id(sender, "Room not found.")
		return
	var room: Dictionary = _rooms[code]

	# Mid-game rejoin: check if this player has a held slot
	if room["started"]:
		var dc_peers: Dictionary = room.get("dc_peers", {})
		var reconnect_slot: int = -1
		var reconnect_old_id: int = -1
		for dc_id: int in dc_peers:
			if dc_peers[dc_id]["name"] == player_name.substr(0, 20):
				reconnect_slot = dc_peers[dc_id]["slot"]
				reconnect_old_id = dc_id
				break
		if reconnect_slot == -1:
			_rpc_room_join_failed.rpc_id(sender, "Game already in progress.")
			return
		# Restore the slot
		dc_peers.erase(reconnect_old_id)
		room["players"].append(sender)
		players[sender] = {"name": player_name.substr(0, 20), "slot": reconnect_slot, "room": code}
		print("[%s] Peer %d (%s) rejoined room %s as slot %d" % [
			server_display_name, sender, player_name, code, reconnect_slot])
		_rpc_assign_slot.rpc_id(sender, reconnect_slot)
		_rpc_start_game.rpc_id(sender, room["settings"])
		peer_reconnected_in_game.emit(sender, reconnect_slot)
		return

	if room["players"].size() >= max_players:
		_rpc_room_join_failed.rpc_id(sender, "Room is full.")
		return

	var slot := _assign_slot_in_room(code)
	if slot == -1:
		_rpc_room_join_failed.rpc_id(sender, "No slots available.")
		return

	room["players"].append(sender)
	players[sender] = {
		"name": player_name.substr(0, 20),
		"slot": slot,
		"room": code,
	}
	print("[%s] Peer %d (%s) joined room %s as slot %d" % [
		server_display_name, sender, player_name, code, slot])
	_rpc_assign_slot.rpc_id(sender, slot)
	_rpc_room_joined.rpc_id(sender, code)
	_broadcast_room_lobby(code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start(room_code: String, game_settings: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	if room["creator"] != sender:
		return

	var human_count := 0
	for pid: int in room["players"]:
		if pid > 0:
			human_count += 1
	if human_count < min_players_to_start:
		print("[%s] Room %s: not enough players (%d/%d)" % [
			server_display_name, room_code, human_count, min_players_to_start])
		return

	if room["countdown"] > 0.0:
		return  # already counting down

	room["settings"] = _sanitize_game_settings(game_settings)
	room["countdown"] = float(countdown_seconds)
	room["last_tick"] = -1
	print("[%s] Room %s: countdown started (%ds)" % [server_display_name, room_code, countdown_seconds])


# ─── RPCs: Server → Client ───────────────────────────────────────────────────────

@rpc("authority", "call_remote", "reliable")
func _rpc_rooms_list(rooms: Array) -> void:
	rooms_list_received.emit(rooms)


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
		players[entry["peer_id"]] = {
			"name":     entry["name"],
			"slot":     entry["slot"],
			"room":     room_code,
			"is_bot":   entry.get("is_bot", false),
			"spectator": entry.get("spectator", false),
		}
	current_room = room_code
	lobby_updated.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_countdown_tick(seconds_left: int) -> void:
	countdown_tick.emit(seconds_left)


## Server sends this to each client when the game begins.
## `settings` matches what was passed to start_countdown() (after sanitization).
@rpc("authority", "call_remote", "reliable")
func _rpc_start_game(settings: Dictionary = {}) -> void:
	_on_client_before_game_start(settings)
	game_starting.emit(settings)
	get_tree().change_scene_to_file(game_scene_path)


## Broadcast to room clients when a peer disconnects mid-game (slot held for 30s).
@rpc("authority", "call_remote", "reliable")
func _rpc_peer_left_mid_game(slot: int, player_name: String) -> void:
	# Subclass or HUD can listen for NetworkManager.peer_left_mid_game signal
	peer_left_mid_game.emit(slot, player_name)
