class_name RegionScreen
extends Control
## Region picker: choose up to AppConfig.MAX_IATAS IATA regions on a map (left) or a searchable list
## (right); both views tick the same selection. Applying saves it and reopens the map, which reloads
## nodes and live traffic for those regions.

const MAIN_SCENE := "res://scenes/main.tscn"
## Last region list fetched, so the picker works offline and opens instantly.
const CACHE_PATH := "user://iatas.json"

var _selected := PackedStringArray()
var _regions: Array[Dictionary] = []
var _rows := {}  # iata -> CheckBox
var _client: BeaconClient

var _map: RegionMap
var _list: VBoxContainer
var _search: LineEdit
var _chips: HFlowContainer
var _count: Label
var _status: Label
var _retry: Button
var _apply_button: Button
var _back_button: Button

# Pieces the compact (phone) layout rearranges.
var _page: ScrollContainer
var _margin: MarginContainer
var _map_frame: PanelContainer
var _title: Label
var _body: BoxContainer
var _list_panel: PanelContainer
var _footer: BoxContainer


func _ready() -> void:
	theme = UiTheme.build(UiScale.touch)
	set_anchors_preset(PRESET_FULL_RECT)
	_selected = AppConfig.selected_iatas.duplicate()
	_client = BeaconClient.new()
	add_child(_client)
	_build()
	UiScale.layout_changed.connect(_apply_layout)
	_apply_layout(UiScale.compact)
	_set_regions(_load_cache())
	_refresh()
	_fetch()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	# Desktop fits the window; phones scroll the page past the map to the list.
	_page = ScrollContainer.new()
	_page.set_anchors_preset(PRESET_FULL_RECT)
	_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_page)
	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = SIZE_EXPAND_FILL
	_margin.size_flags_vertical = SIZE_EXPAND_FILL
	_page.add_child(_margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	_margin.add_child(root)

	_title = UiTheme.label("REGIONS", 40, UiTheme.ACCENT)
	root.add_child(_title)
	var blurb := UiTheme.label("Pick up to %d IATA regions. The map loads their nodes and live traffic only." % AppConfig.MAX_IATAS, 16, UiTheme.MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(blurb)

	_chips = HFlowContainer.new()
	_chips.add_theme_constant_override("h_separation", 8)
	_chips.add_theme_constant_override("v_separation", 8)
	root.add_child(_chips)
	_count = UiTheme.label("", 15, UiTheme.MUTED)

	_body = BoxContainer.new()
	_body.size_flags_vertical = SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 14)
	root.add_child(_body)

	_map_frame = PanelContainer.new()
	var frame_box := UiTheme.panel_box(UiTheme.PANEL_SOLID)
	frame_box.set_content_margin_all(2)
	_map_frame.add_theme_stylebox_override("panel", frame_box)
	_map_frame.size_flags_horizontal = SIZE_EXPAND_FILL
	_map_frame.size_flags_vertical = SIZE_EXPAND_FILL
	_map_frame.size_flags_stretch_ratio = 1.8
	_body.add_child(_map_frame)
	_map = RegionMap.new()
	_map.region_toggled.connect(_toggle)
	_map_frame.add_child(_map)

	_list_panel = PanelContainer.new()
	_list_panel.size_flags_horizontal = SIZE_EXPAND_FILL
	_list_panel.size_flags_vertical = SIZE_EXPAND_FILL
	_body.add_child(_list_panel)
	var list_box := VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 10)
	_list_panel.add_child(list_box)
	_search = LineEdit.new()
	_search.placeholder_text = "Search code or name"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _filter_list())
	list_box.add_child(_search)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	list_box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_list)

	_footer = BoxContainer.new()
	_footer.add_theme_constant_override("separation", 14)
	root.add_child(_footer)
	_status = UiTheme.label("", 15, UiTheme.MUTED)
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer.add_child(_status)
	_retry = Button.new()
	_retry.text = "Retry"
	_retry.visible = false
	_retry.pressed.connect(_fetch)
	_footer.add_child(_retry)
	_back_button = Button.new()
	_back_button.text = "BACK"
	_back_button.tooltip_text = "Discard region changes"
	_back_button.custom_minimum_size = Vector2(120, 44)
	_back_button.pressed.connect(_cancel)
	_footer.add_child(_back_button)
	_apply_button = Button.new()
	_apply_button.text = "APPLY & OPEN MAP"
	_apply_button.custom_minimum_size = Vector2(200, 44)
	_apply_button.add_theme_font_size_override("font_size", 18)
	_apply_button.pressed.connect(_apply)
	_footer.add_child(_apply_button)


## Phones: map above the list, each a fixed height, and the page scrolls. Desktop: map left, list
## right, filling the window.
func _apply_layout(compact: bool) -> void:
	var m := 16 if compact else 40
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, m)
	_title.add_theme_font_size_override("font_size", 30 if compact else 40)
	_page.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if compact else ScrollContainer.SCROLL_MODE_DISABLED
	_body.vertical = compact
	_map_frame.custom_minimum_size = Vector2(0, 340) if compact else Vector2.ZERO
	_list_panel.custom_minimum_size = Vector2(0, 420) if compact else Vector2(320, 0)
	_footer.vertical = compact
	for button in [_back_button, _apply_button]:
		button.size_flags_horizontal = SIZE_FILL if compact else SIZE_SHRINK_END


func _fetch() -> void:
	_retry.visible = false
	_set_status("Loading regions…")
	var res: Dictionary = await _client.fetch_iatas(_beacon_url())
	if not res.ok:
		_set_status("Couldn't load regions: %s%s" % [res.error, " (showing the saved list)" if not _regions.is_empty() else ""], UiTheme.BAD)
		_retry.visible = true
		return
	_set_status("%d regions" % res.iatas.size())
	_save_cache(res.iatas)
	_set_regions(res.iatas)
	_refresh()


## The first enabled Beacon server, else MeshMapper (which hosts the region list).
static func _beacon_url() -> String:
	for b in AppConfig.beacons:
		if b.get("enabled", true) and str(b.get("url", "")) != "":
			return b.url
	return AppConfig.MESHMAPPER_URL


func _set_regions(regions: Array) -> void:
	_regions.assign(regions)
	_rows.clear()
	for child in _list.get_children():
		child.queue_free()
	for region in _regions:
		var code: String = region.iata
		var row := CheckBox.new()
		row.text = code if region.get("displayName") == null else "%s · %s" % [code, region.displayName]
		row.focus_mode = FOCUS_NONE
		row.size_flags_horizontal = SIZE_EXPAND_FILL
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.toggled.connect(func(on: bool) -> void:
			_toggle(code, on)
			if on:
				_map.focus(code))
		_list.add_child(row)
		_rows[code] = row
	_map.set_regions(_regions)
	_filter_list()


func _filter_list() -> void:
	var query := _search.text.strip_edges().to_lower()
	for code: String in _rows:
		var row: CheckBox = _rows[code]
		row.visible = query == "" or row.text.to_lower().contains(query)


func _toggle(code: String, on: bool) -> void:
	if on and not _selected.has(code) and _selected.size() < AppConfig.MAX_IATAS:
		_selected.append(code)
	elif not on and _selected.has(code):
		_selected.remove_at(_selected.find(code))
	_refresh()


## Pushes the selection into the chips, the list and the map.
func _refresh() -> void:
	var at_limit := _selected.size() >= AppConfig.MAX_IATAS
	for child in _chips.get_children():
		if child != _count:
			child.queue_free()
	if _count.get_parent() == null:
		_chips.add_child(_count)
	_count.text = "SELECTED %d/%d%s" % [_selected.size(), AppConfig.MAX_IATAS, " · limit reached" if at_limit else ""]
	_count.add_theme_color_override("font_color", UiTheme.WARN if at_limit else UiTheme.MUTED)
	for code in _selected:
		var chip := Button.new()
		chip.text = "%s  ✕" % code
		chip.tooltip_text = "Remove %s" % code
		chip.pressed.connect(_toggle.bind(code, false))
		_chips.add_child(chip)
	for code: String in _rows:
		var row: CheckBox = _rows[code]
		var on := _selected.has(code)
		row.set_pressed_no_signal(on)
		row.disabled = at_limit and not on
	_map.set_selected(_selected, at_limit)


func _set_status(text: String, color := UiTheme.MUTED) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _load_cache() -> Array[Dictionary]:
	if not FileAccess.file_exists(CACHE_PATH):
		return []
	return BeaconClient.parse_iatas(JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH)))


func _save_cache(regions: Array) -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(regions))


## Saves the regions and reopens the map, which reloads nodes and traffic for them.
func _apply() -> void:
	AppConfig.selected_iatas = AppConfig.normalize_iatas(_selected)
	AppConfig.save_config()
	MeshData.clear()
	get_tree().change_scene_to_file(MAIN_SCENE)


## Back to the map without saving; nodes already loaded are kept.
func _cancel() -> void:
	AppConfig.load_config()
	get_tree().change_scene_to_file(MAIN_SCENE)
