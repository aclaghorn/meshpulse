extends Control
## Start-up screen: configure MQTT brokers and Beacon servers, then load the node directory and
## launch the map. Command-line user args (after `--`): --autostart, --demo.

const MAIN_SCENE := "res://scenes/main.tscn"

var _broker_list: VBoxContainer
var _beacon_list: VBoxContainer
var _demo_check: CheckBox
var _exaggeration: SpinBox
var _excluded_iatas: LineEdit
var _status: Label
var _progress: ProgressBar
var _launch_button: Button
var _launching := false
var _launch_anyway := false
var _cmdline := OS.get_cmdline_user_args()

# Pieces the compact (phone) layout rearranges.
var _margin: MarginContainer
var _title: Label
var _columns: BoxContainer
var _list_scrolls: Array[ScrollContainer] = []
var _footer: BoxContainer


func _ready() -> void:
	theme = UiTheme.build(UiScale.touch)
	set_anchors_preset(PRESET_FULL_RECT)
	_build()
	UiScale.layout_changed.connect(_apply_layout)
	_apply_layout(UiScale.compact)
	if "--autostart" in _cmdline:
		_launch.call_deferred()


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

	_title = UiTheme.label("MESH PULSE", 54, UiTheme.ACCENT)
	root.add_child(_title)
	var blurb := UiTheme.label("Live 3D view of MeshCore packets moving through the mesh. Configure your sources, then launch.", 16, UiTheme.MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(blurb)

	_columns = BoxContainer.new()
	_columns.size_flags_vertical = SIZE_EXPAND_FILL
	_columns.add_theme_constant_override("separation", 18)
	root.add_child(_columns)

	_broker_list = _section(_columns, "MQTT BROKERS", "Live packet feed in meshcore-packet-capture format.", "+ Add broker", _add_broker_row.bind({}))
	_beacon_list = _section(_columns, "BEACON SERVERS", "Node directory: names, keys and locations.", "+ Add Beacon server", _add_beacon_row.bind({}))
	for cfg in AppConfig.brokers:
		_add_broker_row(cfg.duplicate())
	for cfg in AppConfig.beacons:
		_add_beacon_row(cfg.duplicate())

	var options := HFlowContainer.new()
	options.add_theme_constant_override("h_separation", 14)
	options.add_theme_constant_override("v_separation", 10)
	root.add_child(options)
	_demo_check = CheckBox.new()
	_demo_check.text = "Simulated demo traffic"
	_demo_check.tooltip_text = "Generate fake packets over the loaded nodes (or a synthetic mesh when no Beacon is reachable)."
	_demo_check.button_pressed = AppConfig.demo_mode
	options.add_child(_demo_check)
	var exaggeration_row := HBoxContainer.new()
	exaggeration_row.add_theme_constant_override("separation", 10)
	options.add_child(exaggeration_row)
	var exaggeration_label := UiTheme.label("Terrain exaggeration", 15, UiTheme.MUTED)
	exaggeration_label.size_flags_vertical = SIZE_SHRINK_CENTER
	exaggeration_row.add_child(exaggeration_label)
	_exaggeration = SpinBox.new()
	_exaggeration.min_value = 1.0
	_exaggeration.max_value = 10.0
	_exaggeration.step = 0.5
	_exaggeration.suffix = "×"
	_exaggeration.value = AppConfig.vertical_exaggeration
	exaggeration_row.add_child(_exaggeration)
	var exclude_row := HBoxContainer.new()
	exclude_row.add_theme_constant_override("separation", 10)
	options.add_child(exclude_row)
	var exclude_label := UiTheme.label("Exclude IATAs", 15, UiTheme.MUTED)
	exclude_label.size_flags_vertical = SIZE_SHRINK_CENTER
	exclude_row.add_child(exclude_label)
	_excluded_iatas = LineEdit.new()
	_excluded_iatas.text = AppConfig.excluded_iatas
	_excluded_iatas.placeholder_text = "e.g. MCI,CAK,Y*"
	_excluded_iatas.tooltip_text = "Packets and nodes from these IATA regions are ignored. Comma-separated; * matches anything."
	_excluded_iatas.custom_minimum_size.x = 200
	exclude_row.add_child(_excluded_iatas)

	_footer = BoxContainer.new()
	_footer.add_theme_constant_override("separation", 14)
	root.add_child(_footer)
	_status = UiTheme.label("", 15, UiTheme.MUTED)
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer.add_child(_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(260, 22)
	_progress.show_percentage = false
	_progress.visible = false
	_footer.add_child(_progress)
	_launch_button = Button.new()
	_launch_button.text = "LAUNCH"
	_launch_button.custom_minimum_size = Vector2(160, 44)
	_launch_button.add_theme_font_size_override("font_size", 18)
	_launch_button.pressed.connect(_launch)
	_footer.add_child(_launch_button)


## Phones: one column, everything stacked and scrolling as a page. Desktop: two columns whose
## source lists scroll on their own.
func _apply_layout(compact: bool) -> void:
	var m := 16 if compact else 40
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, m)
	_title.add_theme_font_size_override("font_size", 36 if compact else 54)
	_columns.vertical = compact
	for scroll in _list_scrolls:
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if compact else ScrollContainer.SCROLL_MODE_AUTO
		scroll.custom_minimum_size.y = 0 if compact else 240
		scroll.size_flags_vertical = SIZE_FILL if compact else SIZE_EXPAND_FILL
	_footer.vertical = compact
	_progress.custom_minimum_size.x = 0 if compact else 260
	_launch_button.size_flags_horizontal = SIZE_FILL if compact else SIZE_SHRINK_END


func _section(parent: Control, heading: String, blurb: String, add_text: String, on_add: Callable) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(UiTheme.label(heading, 18, UiTheme.ACCENT))
	var blurb_label := UiTheme.label(blurb, 14, UiTheme.MUTED)
	blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(blurb_label)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_list_scrolls.append(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	var add := Button.new()
	add.text = add_text
	add.pressed.connect(on_add)
	box.add_child(add)
	return list


func _add_broker_row(cfg: Dictionary) -> void:
	if cfg.is_empty():
		cfg = AppConfig.default_broker()
		cfg.name = "Broker %d" % (_broker_list.get_child_count() + 1)
	var grid := _row(_broker_list, cfg)
	_field(grid, cfg, "url", "URL", "mqtt://host:1883 · mqtts://host:8883 · wss://host:443/mqtt")
	_field(grid, cfg, "topic", "Topic", "meshcore/+/+/packets (comma-separate several)")
	_field(grid, cfg, "username", "Username", "optional")
	_field(grid, cfg, "password", "Password", "optional", true)


func _add_beacon_row(cfg: Dictionary) -> void:
	if cfg.is_empty():
		cfg = AppConfig.default_beacon()
		cfg.name = "Beacon %d" % (_beacon_list.get_child_count() + 1)
	var grid := _row(_beacon_list, cfg)
	_field(grid, cfg, "url", "URL", "https://beacon.example.com")
	_field(grid, cfg, "iatas", "IATA filter", "optional, e.g. SEA,PDX")


## A source card: enabled toggle, name, remove button, then a label/field grid. The card keeps its
## config dictionary in metadata and fields write straight into it.
func _row(list: VBoxContainer, cfg: Dictionary) -> GridContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiTheme.panel_box(UiTheme.PANEL_SOLID))
	card.set_meta("cfg", cfg)
	list.add_child(card)
	var box := VBoxContainer.new()
	card.add_child(box)
	var header := HBoxContainer.new()
	box.add_child(header)
	var enabled := CheckBox.new()
	enabled.button_pressed = cfg.get("enabled", true)
	enabled.tooltip_text = "Enabled"
	enabled.toggled.connect(func(on: bool) -> void: cfg.enabled = on)
	header.add_child(enabled)
	var name_edit := LineEdit.new()
	name_edit.text = cfg.get("name", "")
	name_edit.placeholder_text = "Name"
	name_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(t: String) -> void: cfg.name = t)
	header.add_child(name_edit)
	var remove := Button.new()
	remove.text = "Remove"
	remove.pressed.connect(card.queue_free)
	header.add_child(remove)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	box.add_child(grid)
	return grid


func _field(grid: GridContainer, cfg: Dictionary, key: String, caption: String, placeholder: String, secret := false) -> void:
	var l := UiTheme.label(caption, 14, UiTheme.MUTED)
	l.custom_minimum_size.x = 90
	grid.add_child(l)
	var edit := LineEdit.new()
	edit.text = str(cfg.get(key, ""))
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.size_flags_horizontal = SIZE_EXPAND_FILL
	edit.custom_minimum_size.x = 120
	edit.expand_to_text_length = false
	edit.text_changed.connect(func(t: String) -> void: cfg[key] = t.strip_edges())
	grid.add_child(edit)


func _collect(list: VBoxContainer) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for card in list.get_children():
		if not card.is_queued_for_deletion():
			out.append(card.get_meta("cfg"))
	return out


func _set_status(text: String, color := UiTheme.MUTED) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _launch() -> void:
	if _launching:
		return
	AppConfig.brokers = _collect(_broker_list)
	AppConfig.beacons = _collect(_beacon_list)
	AppConfig.demo_mode = _demo_check.button_pressed
	AppConfig.vertical_exaggeration = _exaggeration.value
	AppConfig.excluded_iatas = _excluded_iatas.text.strip_edges()
	AppConfig.save_config()
	if "--demo" in _cmdline:
		AppConfig.demo_mode = true

	var problems: Array[String] = []
	var checker := MqttClient.new()
	for b in AppConfig.brokers:
		if b.get("enabled", true):
			var err := checker.parse_url(b.get("url", ""))
			if err != "":
				problems.append("%s: %s" % [b.get("name", "Broker"), err])
	checker.free()
	if not problems.is_empty():
		_set_status("\n".join(problems), UiTheme.BAD)
		return

	_launching = true
	_launch_button.disabled = true
	_progress.visible = true
	_progress.indeterminate = true
	MeshData.clear()

	var warnings: Array[String] = []
	var client := BeaconClient.new()
	add_child(client)
	for b in AppConfig.beacons:
		if not b.get("enabled", true) or str(b.get("url", "")) == "":
			continue
		var label: String = b.get("name", "Beacon")
		_set_status("Loading nodes from %s…" % label)
		var on_progress := func(n: int) -> void: _set_status("Loading nodes from %s… %d" % [label, n])
		client.progress.connect(on_progress)
		var res: Dictionary = await client.fetch_nodes(b.url, b.get("iatas", ""))
		client.progress.disconnect(on_progress)
		for item in res.nodes:
			if not AppConfig.is_node_excluded(item.get("iatas", [])):
				MeshData.upsert_from_beacon(item)
		if not res.ok:
			warnings.append("%s: %s" % [label, res.error])
	client.queue_free()

	if MeshData.located_nodes().is_empty() and AppConfig.demo_mode:
		MeshData.generate_synthetic()

	if not warnings.is_empty() and not _launch_anyway and not "--autostart" in _cmdline:
		_set_status("\n".join(warnings) + "\nFix the source or press LAUNCH ANYWAY.", UiTheme.WARN)
		_launch_button.text = "LAUNCH ANYWAY"
		_launch_button.disabled = false
		_progress.visible = false
		_launching = false
		_launch_anyway = true
		return

	MeshData.set_origin_from_nodes()
	_set_status("%d nodes loaded (%d with a location). Starting…" % [MeshData.nodes.size(), MeshData.located_nodes().size()], UiTheme.GOOD)
	await get_tree().process_frame
	get_tree().change_scene_to_file(MAIN_SCENE)
