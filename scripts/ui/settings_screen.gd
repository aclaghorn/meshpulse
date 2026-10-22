extends Control
## Settings screen, opened from the map: map detail, terrain exaggeration and demo traffic. Apply
## saves them and reopens the map (which reloads); Back returns unchanged.

const MAIN_SCENE := "res://scenes/main.tscn"

var _demo_check: CheckBox
var _exaggeration: SpinBox
var _map_detail: OptionButton
var _apply_button: Button
var _back_button: Button

# Pieces the compact (phone) layout rearranges.
var _margin: MarginContainer
var _title: Label
var _footer: BoxContainer


func _ready() -> void:
	theme = UiTheme.build(UiScale.touch)
	set_anchors_preset(PRESET_FULL_RECT)
	_build()
	UiScale.layout_changed.connect(_apply_layout)
	_apply_layout(UiScale.compact)


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	# The whole screen scrolls when it doesn't fit (phones, short windows).
	var page := ScrollContainer.new()
	page.set_anchors_preset(PRESET_FULL_RECT)
	page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(page)

	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = SIZE_EXPAND_FILL
	_margin.size_flags_vertical = SIZE_EXPAND_FILL
	page.add_child(_margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 18)
	_margin.add_child(root)

	_title = UiTheme.label("SETTINGS", 54, UiTheme.ACCENT)
	root.add_child(_title)
	var blurb := UiTheme.label("How the live map looks. Changes take effect when you apply them.", 16, UiTheme.MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(blurb)

	var panel := PanelContainer.new()
	root.add_child(panel)
	var options := VBoxContainer.new()
	options.add_theme_constant_override("separation", 14)
	panel.add_child(options)

	_map_detail = OptionButton.new()
	_map_detail.add_item("Standard", AppConfig.MapDetail.STANDARD)
	_map_detail.add_item("High", AppConfig.MapDetail.HIGH)
	_map_detail.add_item("Ultra", AppConfig.MapDetail.ULTRA)
	_map_detail.select(_map_detail.get_item_index(AppConfig.map_detail))
	_map_detail.tooltip_text = "Sharpness of the satellite imagery. High and Ultra load finer tiles on larger or high-DPI screens, which downloads more data."
	options.add_child(_option_row("Map detail", _map_detail))
	_exaggeration = SpinBox.new()
	_exaggeration.min_value = 1.0
	_exaggeration.max_value = 10.0
	_exaggeration.step = 0.5
	_exaggeration.suffix = "×"
	_exaggeration.value = AppConfig.vertical_exaggeration
	options.add_child(_option_row("Terrain exaggeration", _exaggeration))
	_demo_check = CheckBox.new()
	_demo_check.text = "Simulated demo traffic"
	_demo_check.tooltip_text = "Generate fake packets over the loaded nodes (or a synthetic mesh when no Beacon is reachable)."
	_demo_check.button_pressed = AppConfig.demo_mode
	_demo_check.size_flags_horizontal = SIZE_SHRINK_BEGIN
	options.add_child(_demo_check)

	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(spacer)

	_footer = BoxContainer.new()
	_footer.alignment = BoxContainer.ALIGNMENT_END
	_footer.add_theme_constant_override("separation", 14)
	root.add_child(_footer)
	_back_button = Button.new()
	_back_button.text = "BACK TO MAP"
	_back_button.tooltip_text = "Discard changes"
	_back_button.custom_minimum_size = Vector2(160, 44)
	_back_button.pressed.connect(_cancel)
	_footer.add_child(_back_button)
	_apply_button = Button.new()
	_apply_button.text = "APPLY & OPEN MAP"
	_apply_button.custom_minimum_size = Vector2(200, 44)
	_apply_button.add_theme_font_size_override("font_size", 18)
	_apply_button.pressed.connect(_apply)
	_footer.add_child(_apply_button)


func _option_row(caption: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := UiTheme.label(caption, 15, UiTheme.MUTED)
	label.custom_minimum_size.x = 190
	label.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(label)
	row.add_child(control)
	return row


func _apply_layout(compact: bool) -> void:
	var m := 16 if compact else 40
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, m)
	_title.add_theme_font_size_override("font_size", 36 if compact else 54)
	_footer.vertical = compact
	for button in [_back_button, _apply_button]:
		button.size_flags_horizontal = SIZE_FILL if compact else SIZE_SHRINK_END


## Saves the settings and reopens the map, which reloads with them.
func _apply() -> void:
	AppConfig.demo_mode = _demo_check.button_pressed
	AppConfig.vertical_exaggeration = _exaggeration.value
	AppConfig.map_detail = _map_detail.get_selected_id() as AppConfig.MapDetail
	AppConfig.save_config()
	MeshData.clear()
	get_tree().change_scene_to_file(MAIN_SCENE)


## Back to the map without saving; nodes already loaded are kept.
func _cancel() -> void:
	AppConfig.load_config()
	get_tree().change_scene_to_file(MAIN_SCENE)
