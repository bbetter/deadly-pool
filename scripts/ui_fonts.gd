extends Node
## Ensures OpenSans is used everywhere, including on web where the engine's
## built-in bitmap font would otherwise render as hieroglyphs.

func _ready() -> void:
	var font: Font = load("res://fonts/DejaVuSans.ttf")
	if font == null:
		push_warning("[UIFonts] Failed to load OpenSans-Regular.ttf")
		return

	# Set on the default engine theme for every common control type.
	# ThemeDB.fallback_font is not enough — the default theme has per-type
	# font entries that take priority over the fallback.
	var dt: Theme = ThemeDB.get_default_theme()
	for ctrl in ["Label", "Button", "LineEdit", "RichTextLabel",
				 "CheckBox", "OptionButton", "PopupMenu", "TabBar",
				 "Tree", "ItemList", "SpinBox", "TextEdit"]:
		dt.set_font("font", ctrl, font)

	ThemeDB.fallback_font = font
	ThemeDB.fallback_font_size = 16
