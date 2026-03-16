extends "res://addons/websocket_rooms/room_network_manager_base.gd"
## Deadly Pool NetworkManager.
## Room/lobby/connection boilerplate lives in RoomNetworkManagerBase (addon).
## This file adds: bot management, spectators, game RPC proxies, ping, room logs,
## single-player mode, and per-frame peer-list caching.


# ─── Deadly Pool state ──────────────────────────────────────────────────────────

var is_single_player: bool = false
var bot_slots: Array[int] = []         # single-player only
var solo_enabled_powerups: Array[int] = [
	Powerup.Type.BOMB, Powerup.Type.FREEZE, Powerup.Type.PORTAL_TRAP,
	Powerup.Type.SWAP, Powerup.Type.GRAVITY_WELL,
]

# Client-side persistent scores (populated by server RPCs)
var room_scores: Dictionary = {}

# Room event logs (server-only): room_code -> Array[String]
var room_logs: Dictionary = {}
var archived_rooms: Array[String] = []
const MAX_LOG_LINES := 200

# Per-physics-frame peer-list cache
var _peer_cache: Dictionary = {}
var _peer_cache_frame: int = -1

# Datetime cache for room_log() (refresh at most once/sec)
var _log_datetime_cache: Dictionary = {}
var _log_datetime_cache_ms: int = -1

const _ALL_POWERUP_TYPES: Array[int] = [
	Powerup.Type.BOMB, Powerup.Type.FREEZE, Powerup.Type.PORTAL_TRAP,
	Powerup.Type.SWAP, Powerup.Type.GRAVITY_WELL,
]


# ─── Configuration ──────────────────────────────────────────────────────────────

func _ready() -> void:
	port                     = 9876
	max_players              = 8
	min_players_to_start     = 1  # Bots count as players; client UI enforces ≥2 total
	countdown_seconds        = 5
	game_scene_path          = "res://scenes/main.tscn"
	main_menu_scene_path     = "res://scenes/main_menu.tscn"
	proxy_ws_path            = "/dp/ws"
	server_display_name      = "Deadly Pool"
	instantiation_mode       = GameInstantiationMode.SPATIAL_CONTAINER
	spatial_room_spacing     = 1000.0
	list_only_joinable_rooms = false   # show started rooms as spectate-only
	super._ready()


# ─── Virtual hook overrides ──────────────────────────────────────────────────────

func _sanitize_create_settings(settings: Dictionary) -> Dictionary:
	var raw: Array = settings.get("powerups", [])
	var safe: Array[int] = []
	for t in raw:
		if t in _ALL_POWERUP_TYPES and t not in safe:
			safe.append(t as int)
	if safe.is_empty():
		safe = _ALL_POWERUP_TYPES.duplicate()
	settings["powerups"] = safe
	return settings


func _get_room_extra_display_info(room: Dictionary) -> Dictionary:
	return {
		"bots":         room.get("bots", []).size(),
		"spectate_only": room["started"],
	}


func _on_player_left_room(peer_id: int, room_code: String, room: Dictionary) -> void:
	super._on_player_left_room(peer_id, room_code, room)  # handles countdown cancel
	room.get("spectators",      []).erase(peer_id)
	room.get("pending_players", []).erase(peer_id)


func _on_cleanup_room(room_code: String, room: Dictionary) -> void:
	# Erase bot fake-peer entries from the shared players dict
	for bot_peer: int in room.get("bots", []):
		players.erase(bot_peer)
	# Archive logs
	if room_code not in archived_rooms:
		archived_rooms.append(room_code)


# Deadly Pool rooms have extra fields: bots, bot_id_counter, spectators, pending_players,
# enabled_powerups, scores, bot_slots, room_index.
# We override _rpc_create_room handling by overriding create_room() to pass create_settings,
# but the server-side room dict also needs extra fields.  We achieve this by overriding
# _rpc_create_room directly (calling super first, then adding the extra fields).

# NOTE: We cannot call super._rpc_create_room() because @rpc methods are not easily
# super-callable in GDScript 4.  Instead we override the full client-side API and
# add extra room fields via an @rpc hook called right after room creation.

func create_room(create_settings: Dictionary = {}) -> void:
	# Passes powerups as create_settings so _sanitize_create_settings picks them up.
	super.create_room(create_settings)
	# After room is created on server the _rpc_room_created_extra RPC adds bot/spectator fields.


# ─── Room creation extra init (server-side) ─────────────────────────────────────

# The base _rpc_create_room creates the room, then calls _rpc_room_created on the sender.
# We listen for room creation on the server via overriding cleanup_room and _start_room_game,
# but the easiest way to add extra fields is: when _rpc_create_room runs on the server, the
# room dict is created, then _broadcast_room_lobby is called.  We hook after that by
# connecting to the room_created signal... but that fires on clients.
#
# Simplest robust approach: override _rpc_create_room completely (duplicate it with extras).
# The base _rpc_create_room is @rpc so GDScript 4 won't forward it via super — we replicate it.

@rpc("any_peer", "call_remote", "reliable")
func _rpc_create_room(player_name: String, create_settings: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[NM] _rpc_create_room from peer=%d name=%s already_in_room=%s" % [
		sender, player_name, str(sender in players and players[sender].get("room", "") != "")])
	if sender in players and players[sender].get("room", "") != "":
		return

	var code := _generate_room_code()
	while code in _rooms:
		code = _generate_room_code()

	var safe_settings := _sanitize_create_settings(create_settings)

	_rooms[code] = {
		"players":         [sender],
		"started":         false,
		"countdown":       -1.0,
		"last_tick":       -1,
		"creator":         sender,
		"created_at":      Time.get_ticks_msec(),
		"game_manager":    null,
		"settings":        {},
		"create_settings": safe_settings,
		# Deadly Pool extras:
		"bots":            [],
		"bot_id_counter":  0,
		"spectators":      [],
		"pending_players": [],
		"scores":          {},
		"bot_slots":       [],
		"room_index":      -1,
		"enabled_powerups": safe_settings.get("powerups", _ALL_POWERUP_TYPES.duplicate()),
	}
	players[sender] = {"name": player_name.substr(0, 20), "slot": 0, "room": code}

	print("[NM] Room %s created: players=%s bot_slots=%s" % [code, str(_rooms[code]["players"]), str(_rooms[code]["bot_slots"])])
	room_log(code, "Room created by %s (peer %d)" % [player_name, sender])
	_rpc_assign_slot.rpc_id(sender, 0)
	_rpc_room_created.rpc_id(sender, code)
	_broadcast_room_lobby(code)


# ─── Bot management ─────────────────────────────────────────────────────────────

func request_add_bot() -> void:
	if not current_room.is_empty():
		_rpc_request_add_bot.rpc_id(1, current_room)


func request_remove_bot(bot_peer_id: int) -> void:
	if not current_room.is_empty():
		_rpc_request_remove_bot.rpc_id(1, current_room, bot_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_add_bot(room_code: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[NM] _rpc_request_add_bot room=%s from peer=%d room_exists=%s" % [room_code, sender, str(room_code in _rooms)])
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	print("[NM]   creator=%d started=%s players=%s bot_slots=%s" % [room["creator"], str(room["started"]), str(room["players"]), str(room["bot_slots"])])
	if room["creator"] != sender or room["started"]:
		print("[NM]   rejected: wrong creator or started")
		return
	if room["players"].size() >= max_players:
		print("[NM]   rejected: room full (%d/%d)" % [room["players"].size(), max_players])
		return
	var slot := _assign_slot_in_room(room_code)
	print("[NM]   assigned slot=%d" % slot)
	if slot == -1:
		return

	room["bot_id_counter"] += 1
	var fake_peer: int = -room["bot_id_counter"]
	var bot_name := "Bot %d" % room["bot_id_counter"]
	players[fake_peer] = {"name": bot_name, "slot": slot, "room": room_code, "is_bot": true}
	room["players"].append(fake_peer)
	room["bots"].append(fake_peer)
	room["bot_slots"].append(slot)
	print("[NM]   bot added: fake_peer=%d slot=%d bot_slots_now=%s players_now=%s" % [fake_peer, slot, str(room["bot_slots"]), str(room["players"])])
	room_log(room_code, "Added %s (slot %d)" % [bot_name, slot])
	_broadcast_room_lobby(room_code)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_remove_bot(room_code: String, bot_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[NM] _rpc_request_remove_bot room=%s bot_peer=%d from peer=%d" % [room_code, bot_peer_id, sender])
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	if room["creator"] != sender or room["started"]:
		print("[NM]   rejected: wrong creator or started")
		return
	if bot_peer_id not in room.get("bots", []):
		print("[NM]   rejected: bot_peer not in bots list=%s" % str(room.get("bots", [])))
		return
	var bot_name: String = players.get(bot_peer_id, {}).get("name", "Bot")
	var bot_slot: int = players.get(bot_peer_id, {}).get("slot", -1)
	players.erase(bot_peer_id)
	room["players"].erase(bot_peer_id)
	room["bots"].erase(bot_peer_id)
	room["bot_slots"].erase(bot_slot)
	print("[NM]   bot removed: slot=%d bot_slots_now=%s players_now=%s" % [bot_slot, str(room["bot_slots"]), str(room["players"])])
	room_log(room_code, "Removed %s" % bot_name)
	_broadcast_room_lobby(room_code)


# ─── Single-player mode ─────────────────────────────────────────────────────────

func start_single_player(player_name: String, bot_count: int, enabled_powerups: Array[int] = []) -> void:
	is_single_player = true
	my_name   = player_name
	my_slot   = 0
	my_peer_id = 1
	current_room = "SOLO"
	bot_slots.clear()
	solo_enabled_powerups.clear()
	for t in enabled_powerups:
		if t in _ALL_POWERUP_TYPES and t not in solo_enabled_powerups:
			solo_enabled_powerups.append(t as int)
	if solo_enabled_powerups.is_empty():
		solo_enabled_powerups = _ALL_POWERUP_TYPES.duplicate()

	players[1] = {"name": player_name.substr(0, 20), "slot": 0, "room": "SOLO"}
	var bot_names: Array[String] = ["Bot 1", "Bot 2", "Bot 3", "Bot 4", "Bot 5", "Bot 6", "Bot 7"]
	for i in bot_count:
		var slot := i + 1
		var fake_peer := slot + 100
		players[fake_peer] = {"name": bot_names[i], "slot": slot, "room": "SOLO"}
		bot_slots.append(slot)

	get_tree().change_scene_to_file(game_scene_path)


func end_single_player() -> void:
	is_single_player = false
	players.clear()
	my_peer_id = 0
	my_slot    = -1
	current_room = ""
	bot_slots.clear()
	solo_enabled_powerups = _ALL_POWERUP_TYPES.duplicate()
	room_scores.clear()


func disconnect_from_server() -> void:
	if is_single_player:
		end_single_player()
		return
	super.disconnect_from_server()
	room_scores.clear()


# ─── Per-frame peer cache ───────────────────────────────────────────────────────

## Cached version of get_room_peers() — one allocation per physics frame.
func get_room_peers_cached(room_code: String) -> Array[int]:
	var frame := Engine.get_physics_frames()
	if frame == _peer_cache_frame and room_code in _peer_cache:
		return _peer_cache[room_code]
	if frame != _peer_cache_frame:
		_peer_cache.clear()
		_peer_cache_frame = frame
	var peers := get_room_peers(room_code)
	_peer_cache[room_code] = peers
	return peers


# ─── Room logs ──────────────────────────────────────────────────────────────────

func room_log(room_code: String, msg: String) -> void:
	if not multiplayer.is_server():
		return
	var now_ms := int(Time.get_ticks_msec())
	if now_ms - _log_datetime_cache_ms >= 1000:
		_log_datetime_cache = Time.get_datetime_dict_from_system()
		_log_datetime_cache_ms = now_ms
	var now := _log_datetime_cache
	var ts := "%02d:%02d:%04d %02d:%02d:%02d.%03d" % [
		now.day, now.month, now.year, now.hour, now.minute, now.second, int(now_ms % 1000)]
	var line := "[%s] %s" % [ts, msg]
	if room_code not in room_logs:
		room_logs[room_code] = []
	room_logs[room_code].append(line)
	if room_logs[room_code].size() > MAX_LOG_LINES:
		room_logs[room_code] = room_logs[room_code].slice(-MAX_LOG_LINES)
	print("[%s] %s" % [room_code, line])


# ─── Ping ───────────────────────────────────────────────────────────────────────

var client_ping_ms: float = -1.0

func send_ping() -> void:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return
	_rpc_ping.rpc_id(1, Time.get_ticks_msec() / 1000.0)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping(client_time: float) -> void:
	if multiplayer.is_server():
		_rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), client_time)


@rpc("authority", "call_remote", "reliable")
func _rpc_pong(client_time: float) -> void:
	if not multiplayer.is_server():
		client_ping_ms = (Time.get_ticks_msec() / 1000.0 - client_time) * 1000.0


# ─── Spectator RPCs ─────────────────────────────────────────────────────────────

# Spectator join-next-round request
@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_request_join_round(room_code: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	if sender not in room.get("spectators", []):
		return
	if sender not in room.get("pending_players", []):
		room["pending_players"].append(sender)
		room_log(room_code, "Peer %d queued for next round" % sender)
	_rpc_game_queued_for_round.rpc_id(sender)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_queued_for_round() -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_queued_for_round()


# Mid-game join: reconnect to held slot first, then spectator fallback
@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_room(code: String, player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[NM] _rpc_join_room room=%s peer=%d name=%s room_exists=%s" % [code, sender, player_name, str(code in _rooms)])
	if code not in _rooms:
		_rpc_room_join_failed.rpc_id(sender, "Room not found")
		return
	var room: Dictionary = _rooms[code]
	print("[NM]   started=%s players=%s bot_slots=%s dc_peers=%s" % [
		str(room["started"]), str(room["players"]), str(room.get("bot_slots", [])),
		str(room.get("dc_peers", {}).keys())])
	if room["started"]:
		# Check if this player has a held reconnect slot (disconnect within grace window)
		var dc_peers: Dictionary = room.get("dc_peers", {})
		var reconnect_slot: int = -1
		var reconnect_old_id: int = -1
		for dc_id: int in dc_peers:
			if dc_peers[dc_id]["name"] == player_name.substr(0, 20):
				reconnect_slot = dc_peers[dc_id]["slot"]
				reconnect_old_id = dc_id
				break
		if reconnect_slot != -1:
			dc_peers.erase(reconnect_old_id)
			room["players"].append(sender)
			players[sender] = {"name": player_name.substr(0, 20), "slot": reconnect_slot, "room": code}
			room_log(code, "%s reconnected to slot %d" % [player_name, reconnect_slot])
			_rpc_assign_slot.rpc_id(sender, reconnect_slot)
			_rpc_start_game.rpc_id(sender, room.get("settings", {}))
			peer_reconnected_in_game.emit(sender, reconnect_slot)
			return
		# No held slot → spectator
		if room["players"].size() >= max_players:
			_rpc_room_join_failed.rpc_id(sender, "Room is full")
			return
		room["players"].append(sender)
		room["spectators"].append(sender)
		players[sender] = {"name": player_name.substr(0, 20), "slot": -1, "room": code, "spectator": true}
		room_log(code, "%s joined as spectator" % player_name)
		_rpc_assign_slot.rpc_id(sender, -1)
		_rpc_room_joined.rpc_id(sender, code)
		_rpc_start_game.rpc_id(sender, {})
		_broadcast_room_lobby(code)
		return

	if room["players"].size() >= max_players:
		_rpc_room_join_failed.rpc_id(sender, "Room is full")
		return
	var slot := _assign_slot_in_room(code)
	if slot == -1:
		_rpc_room_join_failed.rpc_id(sender, "No slots available")
		return
	room["players"].append(sender)
	players[sender] = {"name": player_name.substr(0, 20), "slot": slot, "room": code}
	print("[NM]   join OK: peer=%d slot=%d players_now=%s bot_slots=%s" % [
		sender, slot, str(room["players"]), str(room.get("bot_slots", []))])
	room_log(code, "%s joined as slot %d" % [player_name, slot])
	_rpc_assign_slot.rpc_id(sender, slot)
	_rpc_room_joined.rpc_id(sender, code)
	_broadcast_room_lobby(code)


# ─── Skip-round RPC ─────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_request_skip_round(room_code: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if room_code not in _rooms:
		return
	var room: Dictionary = _rooms[room_code]
	var gm: Node = room.get("game_manager")
	if gm == null or not is_instance_valid(gm):
		return
	var bot_slot_list: Array = room.get("bot_slots", [])
	var alive: Array = gm.alive_players
	var requester_slot := -1
	for slot in gm.slot_to_peer:
		if gm.slot_to_peer[slot] == sender:
			requester_slot = slot
			break
	if requester_slot in alive:
		return
	for slot in alive:
		if slot not in bot_slot_list:
			return
	room_log(room_code, "Skip-round requested by peer %d — all alive are bots" % sender)
	gm.call("_server_restart_round")


# ─── Game RPC helpers ───────────────────────────────────────────────────────────

## Returns the game scene node for the peer's room (server-side).
func _get_game_manager_for_peer(peer_id: int) -> Node:
	return get_game_manager_for_peer(peer_id)


## Returns the current game scene on the client.
func _get_client_game_manager() -> Node:
	var scene := get_tree().current_scene
	if scene and scene.has_method("client_receive_state"):
		return scene
	return null


# ─── Game RPC proxies (Client → Server) ─────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_client_ready() -> void:
	if not multiplayer.is_server():
		return
	var gm := _get_game_manager_for_peer(multiplayer.get_remote_sender_id())
	if gm:
		gm.server_handle_client_ready(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_request_launch(slot: int, direction: Vector3, power: float) -> void:
	if not multiplayer.is_server():
		return
	var gm := _get_game_manager_for_peer(multiplayer.get_remote_sender_id())
	if gm:
		gm.server_handle_request_launch(multiplayer.get_remote_sender_id(), slot, direction, power)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_activate_powerup(slot: int, powerup_type: String, cursor_world_pos: Vector3 = Vector3.ZERO, portal_yaw: float = 0.0) -> void:
	if not multiplayer.is_server():
		return
	var gm := _get_game_manager_for_peer(multiplayer.get_remote_sender_id())
	if gm:
		gm.server_handle_activate_powerup(multiplayer.get_remote_sender_id(), slot, powerup_type, cursor_world_pos, portal_yaw)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_game_send_aim(slot: int, direction: Vector3, power: float) -> void:
	if not multiplayer.is_server():
		return
	var gm := _get_game_manager_for_peer(multiplayer.get_remote_sender_id())
	if gm:
		gm.server_handle_send_aim(multiplayer.get_remote_sender_id(), slot, direction, power)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_game_request_emote(slot: int, emote_id: int) -> void:
	if not multiplayer.is_server():
		return
	var gm := _get_game_manager_for_peer(multiplayer.get_remote_sender_id())
	if gm:
		gm.server_handle_emote(multiplayer.get_remote_sender_id(), slot, emote_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_perf_report(report: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var room_code: String = players.get(sender, {}).get("room", "???")
	var pname: String = players.get(sender, {}).get("name", "???")
	var parts := report.split("|")
	if parts.size() >= 5:
		room_log(room_code, "CLIENT_PERF [%s] peer=%d fps_avg=%s fps_min=%s sync=%s/s ping=%sms gpu=%s" % [
			pname, sender, parts[1], parts[2], parts[3], parts[4], parts[0]])
	elif parts.size() >= 4:
		room_log(room_code, "CLIENT_PERF [%s] peer=%d fps_avg=%s fps_min=%s sync=%s/s gpu=%s" % [
			pname, sender, parts[1], parts[2], parts[3], parts[0]])


# ─── Game RPC proxies (Server → Client) ─────────────────────────────────────────

@rpc("authority", "call_remote", "reliable")
func _rpc_game_spawn_balls(spawn_data: Array[Dictionary], alive: Array[int], player_count: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_spawn_balls(spawn_data, alive, player_count)


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
func _rpc_game_player_eliminated(slot: int, killer_slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_player_eliminated(slot, killer_slot)


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
func _rpc_game_swap_effect(slot_a: int, old_ax: float, old_az: float, slot_b: int, old_bx: float, old_bz: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_swap_effect(slot_a, old_ax, old_az, slot_b, old_bx, old_bz)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_portal_placed(placer_slot: int, portal_idx: int, pos_x: float, pos_z: float, yaw: float = 0.0) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_portal_placed(placer_slot, portal_idx, pos_x, pos_z, yaw)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_game_portal_transit(ball_slot: int, from_x: float, from_z: float, to_x: float, to_z: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_portal_transit(ball_slot, from_x, from_z, to_x, to_z)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_portals_expired(placer_slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_portals_expired(placer_slot)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_gravity_well_placed(placer_slot: int, pos_x: float, pos_z: float, duration: float) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_gravity_well_placed(placer_slot, pos_x, pos_z, duration)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_gravity_well_expired(placer_slot: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_gravity_well_expired(placer_slot)


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


@rpc("authority", "call_remote", "reliable")
func _rpc_game_emote(slot: int, emote_id: int) -> void:
	var gm := _get_client_game_manager()
	if gm:
		gm.client_receive_emote(slot, emote_id)
