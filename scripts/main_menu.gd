extends Control

# UI panels
var main_panel: VBoxContainer
var online_panel: VBoxContainer
var connect_panel: VBoxContainer
var lobby_panel: VBoxContainer

# Main panel
var solo_button: Button
var online_button: Button
var bot_count_label: Label
var _bot_count: int = 2
var name_input: LineEdit

# Online panel
var ip_input: LineEdit
var create_button: Button
var join_button: Button
var online_status: Label

# Connect panel (room code entry)
var code_input: LineEdit
var action_button: Button
var back_button: Button

# Lobby panel
var room_code_label: Label
var player_list_container: VBoxContainer
var start_button: Button
var add_bot_button: Button
var leave_button: Button
var lobby_status: Label
var countdown_label: Label

var _is_joining: bool = false
var _current_room_code: String = ""

# Music controls
var _music_mute_btn: Button
var _music_vol_label: Label
var _music_vol_down_btn: Button
var _music_vol_up_btn: Button

var player_colors: Array[Color] = [
	Color(0.9, 0.15, 0.15),
	Color(0.15, 0.4, 0.9),
	Color(0.9, 0.75, 0.1),
	Color(0.15, 0.8, 0.3),
]
var player_color_names: Array[String] = ["Red", "Blue", "Yellow", "Green"]


var _auto_create: bool = false
var _auto_join: String = ""
var _auto_start: bool = false

func _ready() -> void:
	if NetworkManager.is_server_mode:
		return

	_build_ui()
	_build_music_controls()
	_show_main_panel()

	NetworkManager.player_connected.connect(_on_server_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.room_created.connect(_on_room_created)
	NetworkManager.room_joined.connect(_on_room_joined)
	NetworkManager.room_join_failed.connect(_on_room_join_failed)
	NetworkManager.lobby_updated.connect(_on_lobby_updated)
	NetworkManager.countdown_tick.connect(_on_countdown_tick)
	NetworkManager.game_starting.connect(_on_game_starting)

	_parse_auto_args()


func _build_ui() -> void:
	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.1)
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	root.custom_minimum_size = Vector2(450, 0)
	center.add_child(root)

	# Title (always visible)
	var title := Label.new()
	title.text = "DEADLY POOL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Push your opponents off the table!"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	root.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 30)
	root.add_child(spacer)

	_build_main_panel(root)
	_build_online_panel(root)
	_build_connect_panel(root)
	_build_lobby_panel(root)

	# Version label — bottom-right corner
	var version_label := Label.new()
	version_label.text = "v%s" % Version.VERSION
	version_label.add_theme_font_size_override("font_size", 13)
	version_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.anchor_left = 1.0
	version_label.anchor_top = 1.0
	version_label.anchor_right = 1.0
	version_label.anchor_bottom = 1.0
	version_label.offset_left = -100
	version_label.offset_top = -30
	version_label.offset_right = -12
	version_label.offset_bottom = -8
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(version_label)


func _build_main_panel(root: VBoxContainer) -> void:
	main_panel = VBoxContainer.new()
	main_panel.add_theme_constant_override("separation", 12)
	root.add_child(main_panel)

	var name_label := Label.new()
	name_label.text = "Your Name:"
	name_label.add_theme_font_size_override("font_size", 16)
	main_panel.add_child(name_label)

	name_input = LineEdit.new()
	name_input.placeholder_text = "Player"
	name_input.text = "Player"
	name_input.custom_minimum_size = Vector2(0, 42)
	name_input.add_theme_font_size_override("font_size", 18)
	main_panel.add_child(name_input)

	var btn_spacer := Control.new()
	btn_spacer.custom_minimum_size = Vector2(0, 8)
	main_panel.add_child(btn_spacer)

	# Solo play row
	var solo_row := HBoxContainer.new()
	solo_row.add_theme_constant_override("separation", 8)
	main_panel.add_child(solo_row)

	solo_button = Button.new()
	solo_button.text = "PLAY SOLO"
	solo_button.custom_minimum_size = Vector2(0, 50)
	solo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	solo_button.add_theme_font_size_override("font_size", 20)
	solo_button.pressed.connect(_on_solo_pressed)
	solo_row.add_child(solo_button)

	var bot_minus := Button.new()
	bot_minus.text = "-"
	bot_minus.custom_minimum_size = Vector2(40, 50)
	bot_minus.add_theme_font_size_override("font_size", 20)
	bot_minus.pressed.connect(func() -> void:
		_bot_count = maxi(_bot_count - 1, 1)
		bot_count_label.text = "%d" % _bot_count
	)
	solo_row.add_child(bot_minus)

	bot_count_label = Label.new()
	bot_count_label.text = "%d" % _bot_count
	bot_count_label.custom_minimum_size = Vector2(24, 0)
	bot_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bot_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bot_count_label.add_theme_font_size_override("font_size", 20)
	bot_count_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	solo_row.add_child(bot_count_label)

	var bot_plus := Button.new()
	bot_plus.text = "+"
	bot_plus.custom_minimum_size = Vector2(40, 50)
	bot_plus.add_theme_font_size_override("font_size", 20)
	bot_plus.pressed.connect(func() -> void:
		_bot_count = mini(_bot_count + 1, 3)
		bot_count_label.text = "%d" % _bot_count
	)
	solo_row.add_child(bot_plus)

	var solo_hint := Label.new()
	solo_hint.text = "vs bots"
	solo_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	solo_hint.add_theme_font_size_override("font_size", 14)
	solo_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	solo_row.add_child(solo_hint)

	# Online button
	online_button = Button.new()
	online_button.text = "PLAY ONLINE"
	online_button.custom_minimum_size = Vector2(0, 50)
	online_button.add_theme_font_size_override("font_size", 20)
	online_button.pressed.connect(_on_online_pressed)
	main_panel.add_child(online_button)


func _build_online_panel(root: VBoxContainer) -> void:
	online_panel = VBoxContainer.new()
	online_panel.add_theme_constant_override("separation", 12)
	online_panel.visible = false
	root.add_child(online_panel)

	var header := Label.new()
	header.text = "PLAY ONLINE"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 24)
	header.add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
	online_panel.add_child(header)

	var ip_label := Label.new()
	ip_label.text = "Server:"
	ip_label.add_theme_font_size_override("font_size", 16)
	online_panel.add_child(ip_label)

	ip_input = LineEdit.new()
	ip_input.placeholder_text = "dp.900dfe11a-media.pp.ua"
	ip_input.text = "dp.900dfe11a-media.pp.ua"
	ip_input.custom_minimum_size = Vector2(0, 42)
	ip_input.add_theme_font_size_override("font_size", 18)
	online_panel.add_child(ip_input)

	var btn_spacer := Control.new()
	btn_spacer.custom_minimum_size = Vector2(0, 4)
	online_panel.add_child(btn_spacer)

	create_button = Button.new()
	create_button.text = "CREATE ROOM"
	create_button.custom_minimum_size = Vector2(0, 50)
	create_button.add_theme_font_size_override("font_size", 20)
	create_button.pressed.connect(_on_create_pressed)
	online_panel.add_child(create_button)

	join_button = Button.new()
	join_button.text = "JOIN ROOM"
	join_button.custom_minimum_size = Vector2(0, 50)
	join_button.add_theme_font_size_override("font_size", 20)
	join_button.pressed.connect(_on_join_pressed)
	online_panel.add_child(join_button)

	online_status = Label.new()
	online_status.text = ""
	online_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	online_status.add_theme_font_size_override("font_size", 14)
	online_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	online_panel.add_child(online_status)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(0, 40)
	back_btn.add_theme_font_size_override("font_size", 16)
	back_btn.pressed.connect(_on_online_back_pressed)
	online_panel.add_child(back_btn)


func _build_connect_panel(root: VBoxContainer) -> void:
	connect_panel = VBoxContainer.new()
	connect_panel.add_theme_constant_override("separation", 12)
	connect_panel.visible = false
	root.add_child(connect_panel)

	var code_label := Label.new()
	code_label.text = "Enter Room Code:"
	code_label.add_theme_font_size_override("font_size", 18)
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	connect_panel.add_child(code_label)

	code_input = LineEdit.new()
	code_input.placeholder_text = "XXXXX"
	code_input.custom_minimum_size = Vector2(0, 50)
	code_input.add_theme_font_size_override("font_size", 28)
	code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_input.max_length = 5
	connect_panel.add_child(code_input)

	action_button = Button.new()
	action_button.text = "JOIN"
	action_button.custom_minimum_size = Vector2(0, 50)
	action_button.add_theme_font_size_override("font_size", 20)
	action_button.pressed.connect(_on_code_submit)
	connect_panel.add_child(action_button)

	var connect_status_2 := Label.new()
	connect_status_2.name = "ConnectStatus2"
	connect_status_2.text = ""
	connect_status_2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	connect_status_2.add_theme_font_size_override("font_size", 14)
	connect_panel.add_child(connect_status_2)

	back_button = Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(0, 40)
	back_button.add_theme_font_size_override("font_size", 16)
	back_button.pressed.connect(_on_connect_back_pressed)
	connect_panel.add_child(back_button)


func _build_lobby_panel(root: VBoxContainer) -> void:
	lobby_panel = VBoxContainer.new()
	lobby_panel.add_theme_constant_override("separation", 10)
	lobby_panel.visible = false
	root.add_child(lobby_panel)

	room_code_label = Label.new()
	room_code_label.text = "Room: -----"
	room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	room_code_label.add_theme_font_size_override("font_size", 32)
	room_code_label.add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
	room_code_label.mouse_filter = Control.MOUSE_FILTER_STOP
	room_code_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	room_code_label.gui_input.connect(_on_room_code_clicked)
	lobby_panel.add_child(room_code_label)

	var share_hint := Label.new()
	share_hint.text = "Click code to copy!"
	share_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	share_hint.add_theme_font_size_override("font_size", 13)
	share_hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	lobby_panel.add_child(share_hint)

	var sep := HSeparator.new()
	lobby_panel.add_child(sep)

	var players_title := Label.new()
	players_title.text = "Players:"
	players_title.add_theme_font_size_override("font_size", 18)
	players_title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	lobby_panel.add_child(players_title)

	player_list_container = VBoxContainer.new()
	player_list_container.add_theme_constant_override("separation", 6)
	lobby_panel.add_child(player_list_container)

	var sep2 := HSeparator.new()
	lobby_panel.add_child(sep2)

	# Add bot button (creator only, hidden for joiners)
	add_bot_button = Button.new()
	add_bot_button.text = "+ ADD BOT"
	add_bot_button.custom_minimum_size = Vector2(0, 40)
	add_bot_button.add_theme_font_size_override("font_size", 16)
	add_bot_button.pressed.connect(_on_add_bot_pressed)
	add_bot_button.visible = false
	lobby_panel.add_child(add_bot_button)

	countdown_label = Label.new()
	countdown_label.text = ""
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_size_override("font_size", 28)
	countdown_label.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	countdown_label.visible = false
	lobby_panel.add_child(countdown_label)

	start_button = Button.new()
	start_button.text = "START GAME"
	start_button.custom_minimum_size = Vector2(0, 50)
	start_button.add_theme_font_size_override("font_size", 20)
	start_button.pressed.connect(_on_start_pressed)
	lobby_panel.add_child(start_button)

	lobby_status = Label.new()
	lobby_status.text = "Waiting for players..."
	lobby_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_status.add_theme_font_size_override("font_size", 14)
	lobby_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	lobby_panel.add_child(lobby_status)

	leave_button = Button.new()
	leave_button.text = "LEAVE ROOM"
	leave_button.custom_minimum_size = Vector2(0, 40)
	leave_button.add_theme_font_size_override("font_size", 16)
	leave_button.pressed.connect(_on_leave_pressed)
	lobby_panel.add_child(leave_button)


# --- Panel navigation ---

func _show_main_panel() -> void:
	main_panel.visible = true
	online_panel.visible = false
	connect_panel.visible = false
	lobby_panel.visible = false


func _show_online_panel() -> void:
	main_panel.visible = false
	online_panel.visible = true
	connect_panel.visible = false
	lobby_panel.visible = false
	online_status.text = ""
	create_button.disabled = false
	join_button.disabled = false


func _show_connect_panel() -> void:
	main_panel.visible = false
	online_panel.visible = false
	connect_panel.visible = true
	lobby_panel.visible = false
	code_input.text = ""
	var status_2: Label = connect_panel.get_node("ConnectStatus2")
	if status_2:
		status_2.text = ""


func _show_lobby_panel() -> void:
	main_panel.visible = false
	online_panel.visible = false
	connect_panel.visible = false
	lobby_panel.visible = true
	countdown_label.visible = false


# --- Button handlers ---

func _on_solo_pressed() -> void:
	var player_name := name_input.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"
	NetworkManager.start_single_player(player_name, _bot_count)


func _on_online_pressed() -> void:
	_show_online_panel()


func _on_online_back_pressed() -> void:
	_show_main_panel()


func _on_create_pressed() -> void:
	var ip := ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "dp.900dfe11a-media.pp.ua"

	var player_name := name_input.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	create_button.disabled = true
	join_button.disabled = true
	online_status.text = "Connecting to %s..." % ip
	online_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

	_is_joining = false
	NetworkManager.connect_to_server(ip, player_name)


func _on_join_pressed() -> void:
	var ip := ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "dp.900dfe11a-media.pp.ua"

	var player_name := name_input.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	create_button.disabled = true
	join_button.disabled = true
	online_status.text = "Connecting to %s..." % ip
	online_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

	_is_joining = true
	NetworkManager.connect_to_server(ip, player_name)


func _on_code_submit() -> void:
	var code := code_input.text.strip_edges().to_upper()
	var status_2: Label = connect_panel.get_node("ConnectStatus2")
	if code.length() < 3:
		if status_2:
			status_2.text = "Enter a valid room code"
			status_2.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		return

	action_button.disabled = true
	if status_2:
		status_2.text = "Joining room %s..." % code
		status_2.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

	NetworkManager.join_room(code)


func _on_connect_back_pressed() -> void:
	NetworkManager.disconnect_from_server()
	_show_online_panel()


func _on_start_pressed() -> void:
	NetworkManager.start_countdown()
	start_button.disabled = true
	lobby_status.text = "Starting countdown..."
	lobby_status.add_theme_color_override("font_color", Color(1, 0.85, 0.2))


func _on_leave_pressed() -> void:
	NetworkManager.disconnect_from_server()
	_show_main_panel()


func _on_add_bot_pressed() -> void:
	NetworkManager.request_add_bot()


func _on_remove_bot_pressed(peer_id: int) -> void:
	NetworkManager.request_remove_bot(peer_id)


# --- Network callbacks ---

func _on_server_connected(_peer_id: int) -> void:
	if _is_joining:
		if not _auto_join.is_empty():
			# Auto-join: skip the code entry panel, submit directly
			NetworkManager.join_room(_auto_join)
			online_status.text = "Auto-joining room %s..." % _auto_join
		else:
			_show_connect_panel()
	else:
		# Creating room - send request immediately
		NetworkManager.create_room()
		online_status.text = "Creating room..."


func _on_connection_failed() -> void:
	online_status.text = "Connection failed!"
	online_status.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	create_button.disabled = false
	join_button.disabled = false


func _on_room_created(code: String) -> void:
	_current_room_code = code
	room_code_label.text = "Room: %s" % code
	_show_lobby_panel()
	start_button.visible = true
	start_button.disabled = false
	add_bot_button.visible = true
	lobby_status.text = "You are the host. Waiting for players..."
	if _auto_create:
		print("ROOM_CODE=%s" % code)
		# Write to /tmp so the test script can reliably find it
		var f := FileAccess.open("/tmp/deadly-pool-room-code.txt", FileAccess.WRITE)
		if f:
			f.store_string(code)
			f.close()


func _on_room_joined(code: String) -> void:
	_current_room_code = code
	room_code_label.text = "Room: %s" % code
	_show_lobby_panel()
	start_button.visible = false  # Only creator can start
	add_bot_button.visible = false  # Only creator can add bots
	lobby_status.text = "Waiting for host to start..."


func _on_room_join_failed(reason: String) -> void:
	var status_2: Label = connect_panel.get_node("ConnectStatus2")
	if status_2:
		status_2.text = reason
		status_2.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	action_button.disabled = false


func _on_lobby_updated() -> void:
	_rebuild_player_list()

	var count := NetworkManager.get_player_count()
	var is_creator := NetworkManager.is_room_creator()

	if is_creator:
		start_button.visible = true
		start_button.disabled = count < 2
		add_bot_button.visible = count < NetworkManager.MAX_PLAYERS
		if count < 2:
			lobby_status.text = "Need at least 2 players to start"
			lobby_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		else:
			lobby_status.text = "%d players ready!" % count
			lobby_status.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
			# Auto-start when enough players joined
			if _auto_start:
				_auto_start = false  # Only trigger once
				_on_start_pressed()
	else:
		add_bot_button.visible = false


func _on_countdown_tick(seconds_left: int) -> void:
	if seconds_left > 0:
		countdown_label.visible = true
		countdown_label.text = "Starting in %d..." % seconds_left
		start_button.disabled = true
		add_bot_button.visible = false
		leave_button.disabled = true
	else:
		countdown_label.text = "GO!"


func _on_game_starting() -> void:
	countdown_label.text = "Loading..."


func _rebuild_player_list() -> void:
	for child in player_list_container.get_children():
		child.queue_free()

	var is_creator := NetworkManager.is_room_creator()

	for peer_id: int in NetworkManager.players:
		var info: Dictionary = NetworkManager.players[peer_id]
		var slot: int = info["slot"]
		var pname: String = info["name"]
		var is_bot: bool = info.get("is_bot", false)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		# Color dot
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.color = player_colors[slot] if slot < player_colors.size() else Color.WHITE
		row.add_child(dot)

		# Player label
		var label := Label.new()
		var color_name: String = player_color_names[slot] if slot < player_color_names.size() else "?"
		label.add_theme_font_size_override("font_size", 20)

		if is_bot:
			label.text = "%s (%s)" % [pname, color_name]
			label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		elif peer_id == NetworkManager.my_peer_id:
			label.text = "%s (%s)  <- You" % [pname, color_name]
			label.add_theme_color_override("font_color", Color(1, 1, 0.5))
		else:
			label.text = "%s (%s)" % [pname, color_name]
			label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))

		row.add_child(label)

		# Remove bot button (creator only)
		if is_bot and is_creator:
			var remove_btn := Button.new()
			remove_btn.text = "x"
			remove_btn.custom_minimum_size = Vector2(30, 24)
			remove_btn.add_theme_font_size_override("font_size", 14)
			var bot_peer := peer_id  # Capture for lambda
			remove_btn.pressed.connect(func() -> void:
				_on_remove_bot_pressed(bot_peer)
			)
			row.add_child(remove_btn)

		player_list_container.add_child(row)

	# Empty slots
	var filled := NetworkManager.get_player_count()
	for i in range(filled, NetworkManager.MAX_PLAYERS):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.color = Color(0.2, 0.2, 0.2, 0.5)
		row.add_child(dot)

		var label := Label.new()
		label.text = "(empty)"
		label.add_theme_font_size_override("font_size", 18)
		label.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
		row.add_child(label)
		player_list_container.add_child(row)


# --- Room code copy ---

func _on_room_code_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			DisplayServer.clipboard_set(_current_room_code)
			# Flash the label to confirm copy
			room_code_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
			room_code_label.text = "Copied: %s" % _current_room_code
			get_tree().create_timer(0.8).timeout.connect(func() -> void:
				if room_code_label:
					room_code_label.text = "Room: %s" % _current_room_code
					room_code_label.add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
			)


# --- Auto-join from command line ---
# Usage:
#   ./deadly-pool.x86_64 -- --name=Alice --ip=localhost --auto-create --auto-start
#   ./deadly-pool.x86_64 -- --name=Bob --ip=localhost --auto-join=ABCDE

func _parse_auto_args() -> void:
	var args := OS.get_cmdline_user_args()
	var auto_ip := ""
	var auto_name := ""

	for arg: String in args:
		if arg.begins_with("--name="):
			auto_name = arg.split("=", true, 1)[1]
		elif arg.begins_with("--ip="):
			auto_ip = arg.split("=", true, 1)[1]
		elif arg == "--auto-create":
			_auto_create = true
		elif arg.begins_with("--auto-join="):
			_auto_join = arg.split("=", true, 1)[1].to_upper()
		elif arg == "--auto-start":
			_auto_start = true

	if not _auto_create and _auto_join.is_empty():
		return

	# Apply name/ip overrides
	if not auto_name.is_empty():
		name_input.text = auto_name
	if not auto_ip.is_empty():
		ip_input.text = auto_ip

	# Trigger connect flow (auto-args skip the online panel)
	if _auto_create:
		_on_create_pressed()
	elif not _auto_join.is_empty():
		_is_joining = true
		_on_join_pressed()


# --- Music controls ---

func _build_music_controls() -> void:
	var music_row := HBoxContainer.new()
	music_row.anchor_left = 0.0
	music_row.anchor_top = 1.0
	music_row.anchor_right = 0.0
	music_row.anchor_bottom = 1.0
	music_row.offset_left = 12
	music_row.offset_top = -44
	music_row.offset_right = 250
	music_row.offset_bottom = -8
	music_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	music_row.add_theme_constant_override("separation", 4)
	add_child(music_row)

	_music_mute_btn = Button.new()
	_music_mute_btn.custom_minimum_size = Vector2(36, 32)
	_music_mute_btn.add_theme_font_size_override("font_size", 16)
	_music_mute_btn.pressed.connect(_on_music_mute_pressed)
	music_row.add_child(_music_mute_btn)

	_music_vol_down_btn = Button.new()
	_music_vol_down_btn.text = "-"
	_music_vol_down_btn.custom_minimum_size = Vector2(32, 32)
	_music_vol_down_btn.add_theme_font_size_override("font_size", 16)
	_music_vol_down_btn.pressed.connect(_on_music_vol_down)
	music_row.add_child(_music_vol_down_btn)

	_music_vol_label = Label.new()
	_music_vol_label.custom_minimum_size = Vector2(40, 0)
	_music_vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_music_vol_label.add_theme_font_size_override("font_size", 14)
	_music_vol_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	music_row.add_child(_music_vol_label)

	_music_vol_up_btn = Button.new()
	_music_vol_up_btn.text = "+"
	_music_vol_up_btn.custom_minimum_size = Vector2(32, 32)
	_music_vol_up_btn.add_theme_font_size_override("font_size", 16)
	_music_vol_up_btn.pressed.connect(_on_music_vol_up)
	music_row.add_child(_music_vol_up_btn)

	_update_music_ui()


func _on_music_mute_pressed() -> void:
	MusicManager.toggle_mute()
	_update_music_ui()


func _on_music_vol_down() -> void:
	MusicManager.volume_down()
	_update_music_ui()


func _on_music_vol_up() -> void:
	MusicManager.volume_up()
	_update_music_ui()


func _update_music_ui() -> void:
	if _music_mute_btn == null:
		return
	_music_mute_btn.text = "M" if MusicManager.is_muted() else "♪"
	_music_vol_label.text = "%d%%" % MusicManager.get_volume_percent()
	var muted := MusicManager.is_muted()
	_music_vol_down_btn.disabled = muted
	_music_vol_up_btn.disabled = muted
