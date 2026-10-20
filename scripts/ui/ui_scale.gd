extends Node
## Picks the UI scale for the device and reports whether layouts should be compact (phones).
##
## Desktop keeps the project's 1600x960 canvas_items stretch. Touch devices (Android, iOS and mobile
## browsers) size the UI in density-independent pixels instead, so text stays readable on small,
## dense screens. Pass `-- --touch-ui` to preview the touch UI on desktop.

signal layout_changed(compact: bool)

## Logical sizes below these switch the HUD and setup screen to their compact layouts.
const COMPACT_WIDTH := 900.0
const COMPACT_HEIGHT := 560.0

var touch := false
var compact := false


func _ready() -> void:
	touch = OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios") \
		or "--touch-ui" in OS.get_cmdline_user_args()
	get_tree().root.size_changed.connect(_update)
	_update()


func _update() -> void:
	var root := get_tree().root
	if touch:
		var logical := Vector2i((Vector2(root.size) / _density()).round())
		if root.content_scale_size != logical:
			root.content_scale_size = logical
	var visible := root.get_visible_rect().size
	var now_compact := visible.x < COMPACT_WIDTH or visible.y < COMPACT_HEIGHT
	if now_compact != compact:
		compact = now_compact
		layout_changed.emit(compact)


## Physical pixels per density-independent pixel.
func _density() -> float:
	if OS.has_feature("web") or not OS.has_feature("mobile"):
		# Browsers report devicePixelRatio here; desktop previews use the monitor's scale.
		return maxf(1.0, DisplayServer.screen_get_scale())
	return maxf(1.0, DisplayServer.screen_get_dpi() / 160.0)
