class_name UiTheme
extends RefCounted
## Shared dark "mission control" look for the setup screen and HUD.

const BG := Color("070b14")
const PANEL := Color(0.05, 0.08, 0.13, 0.88)
const PANEL_SOLID := Color("0d1422")
const BORDER := Color("1d3a52")
const ACCENT := Color("2fd8ff")
const TEXT := Color("cfe6f5")
const MUTED := Color("6f8aa3")
const GOOD := Color("4dff9a")
const WARN := Color("ffc94d")
const BAD := Color("ff5d6c")


## `touch` pads buttons, fields and checkboxes out to finger-sized targets.
static func build(touch := false) -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 16 if touch else 15
	var pad := 12 if touch else 6

	theme.set_stylebox("panel", "PanelContainer", panel_box(PANEL))
	theme.set_stylebox("panel", "Panel", panel_box(PANEL))

	var normal := _box(Color("10233a"), BORDER, 4, pad)
	var hover := _box(Color("15304d"), ACCENT.darkened(0.3), 4, pad)
	var pressed := _box(Color("0b4a66"), ACCENT, 4, pad)
	var disabled := _box(Color("0b1420"), Color("15202d"), 4, pad)
	for kind in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", kind, normal)
		theme.set_stylebox("hover", kind, hover)
		theme.set_stylebox("pressed", kind, pressed)
		theme.set_stylebox("hover_pressed", kind, pressed)
		theme.set_stylebox("disabled", kind, disabled)
		theme.set_stylebox("focus", kind, StyleBoxEmpty.new())
		theme.set_color("font_color", kind, TEXT)
		theme.set_color("font_hover_color", kind, Color.WHITE)
		theme.set_color("font_pressed_color", kind, Color.WHITE)
		theme.set_color("font_disabled_color", kind, MUTED.darkened(0.3))

	var field := _box(Color("08111c"), BORDER, 3, pad)
	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("focus", "LineEdit", _box(Color("08111c"), ACCENT, 3, pad))
	theme.set_stylebox("read_only", "LineEdit", _box(Color("060c14"), Color("15202d"), 3, pad))
	if touch:
		var check_box := StyleBoxEmpty.new()
		check_box.set_content_margin_all(pad - 4)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			theme.set_stylebox(state, "CheckBox", check_box)
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED.darkened(0.25))
	theme.set_color("caret_color", "LineEdit", ACCENT)

	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_color", "CheckBox", TEXT)
	theme.set_color("font_hover_color", "CheckBox", Color.WHITE)
	theme.set_color("font_pressed_color", "CheckBox", TEXT)
	theme.set_color("font_hover_pressed_color", "CheckBox", Color.WHITE)
	theme.set_color("default_color", "RichTextLabel", TEXT)

	var bar_bg := _box(Color("08111c"), BORDER, 3)
	var bar_fill := _box(ACCENT.darkened(0.2), ACCENT, 3)
	theme.set_stylebox("background", "ProgressBar", bar_bg)
	theme.set_stylebox("fill", "ProgressBar", bar_fill)
	theme.set_color("font_color", "ProgressBar", Color.WHITE)
	return theme


static func panel_box(color: Color) -> StyleBoxFlat:
	var box := _box(color, BORDER, 6)
	box.set_content_margin_all(12)
	return box


static func _box(bg: Color, border: Color, radius: int, pad := 6) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 10 + pad - 6
	box.content_margin_right = 10 + pad - 6
	box.content_margin_top = pad
	box.content_margin_bottom = pad
	return box


static func label(text: String, size := 15, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
