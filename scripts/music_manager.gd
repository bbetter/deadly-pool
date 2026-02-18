extends Node

var _player: AudioStreamPlayer
var _music: AudioStream
var _muted: bool = false
var _volume_db: float = -50.0  # Default: moderately quiet background music

const VOLUME_MIN_DB := -40.0
const VOLUME_MAX_DB := 0.0
const VOLUME_STEP_DB := 5.0


func _ready() -> void:
	_music = load("res://Eventide Hexagons.mp3")

	_player = AudioStreamPlayer.new()
	_player.stream = _music
	_player.volume_db = _volume_db
	_player.bus = &"Master"
	add_child(_player)
	_player.finished.connect(_on_finished)
	_player.play()


func _on_finished() -> void:
	_player.play()


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
