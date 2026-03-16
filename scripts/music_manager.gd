extends Node

var _player: AudioStreamPlayer
var _music: AudioStream
var _muted: bool = false
var _volume_db: float = -36.0  # 10% of slider range (-40..0)

var _sfx_muted: bool = false
var _sfx_volume_db: float = -36.0  # 10% default
var _sfx_bus_idx: int = -1

const VOLUME_MIN_DB := -40.0
const VOLUME_MAX_DB := 0.0
const VOLUME_STEP_DB := 5.0


func _ready() -> void:
	# Ensure SFX bus exists (routes to Master)
	_sfx_bus_idx = AudioServer.get_bus_index("SFX")
	if _sfx_bus_idx == -1:
		AudioServer.add_bus()
		_sfx_bus_idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_sfx_bus_idx, "SFX")
		AudioServer.set_bus_send(_sfx_bus_idx, "Master")
	AudioServer.set_bus_volume_db(_sfx_bus_idx, _sfx_volume_db)

	_music = load("res://Midnight Billiard Haze.mp3")

	_player = AudioStreamPlayer.new()
	_player.stream = _music
	_player.volume_db = _volume_db
	_player.bus = &"Master"
	add_child(_player)
	_player.finished.connect(_on_finished)
	_player.play()


func _on_finished() -> void:
	_player.play()


# --- Music ---

func is_muted() -> bool:
	return _muted


func get_volume_db() -> float:
	return _volume_db


func get_volume_percent() -> int:
	return int(remap(_volume_db, VOLUME_MIN_DB, VOLUME_MAX_DB, 0.0, 100.0))


func set_muted(muted: bool) -> void:
	_muted = muted
	_player.volume_db = -80.0 if _muted else _volume_db


func toggle_mute() -> void:
	set_muted(not _muted)


func set_volume_db(db: float) -> void:
	_volume_db = clampf(db, VOLUME_MIN_DB, VOLUME_MAX_DB)
	if not _muted:
		_player.volume_db = _volume_db


func volume_up() -> void:
	set_volume_db(_volume_db + VOLUME_STEP_DB)


func volume_down() -> void:
	set_volume_db(_volume_db - VOLUME_STEP_DB)


# --- SFX ---

func is_sfx_muted() -> bool:
	return _sfx_muted


func get_sfx_volume_percent() -> int:
	return int(remap(_sfx_volume_db, VOLUME_MIN_DB, VOLUME_MAX_DB, 0.0, 100.0))


func toggle_sfx_mute() -> void:
	_sfx_muted = not _sfx_muted
	_apply_sfx_volume()


func sfx_volume_up() -> void:
	set_sfx_volume_db(_sfx_volume_db + VOLUME_STEP_DB)


func sfx_volume_down() -> void:
	set_sfx_volume_db(_sfx_volume_db - VOLUME_STEP_DB)


func set_sfx_volume_db(db: float) -> void:
	_sfx_volume_db = clampf(db, VOLUME_MIN_DB, VOLUME_MAX_DB)
	_apply_sfx_volume()


func _apply_sfx_volume() -> void:
	if _sfx_bus_idx < 0:
		_sfx_bus_idx = AudioServer.get_bus_index("SFX")
	if _sfx_bus_idx >= 0:
		AudioServer.set_bus_mute(_sfx_bus_idx, _sfx_muted)
		if not _sfx_muted:
			AudioServer.set_bus_volume_db(_sfx_bus_idx, _sfx_volume_db)
