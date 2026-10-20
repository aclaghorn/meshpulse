extends CanvasLayer
## On-map overlay: stats, source status, view controls, packet-type filters, packet log, node details
## and the hover tooltip.
##
## Two layouts: on desktop the panels sit around the edges; on compact (phone) screens a bottom
## toolbar opens the legend, log and sources one at a time as a drawer above it.

signal view_3d_requested(enabled: bool)
signal setup_requested
signal fly_to_requested(node: MeshNode)
signal selection_cleared

const LOG_LINES := 14
const MARGIN := 16.0
const COMPACT_MARGIN := 8.0

var _root: Control
var _title: Label
var _stats: Label
var _sources: VBoxContainer
var _broker_labels := {}  # index -> Label
var _log: RichTextLabel
var _log_lines: Array[String] = []
var _node_panel: PanelContainer
var _node_title: Label
var _node_body: Label
var _node: MeshNode
var _tooltip: PanelContainer
var _tooltip_label: Label
var _view_buttons: Array[Button] = []
var _disabled_types := {}

var _title_panel: PanelContainer
var _source_panel: PanelContainer
var _legend_panel: PanelContainer
var _log_panel: PanelContainer
var _hint: Label
var _toolbar: HBoxContainer
var _fullscreen_button: Button
## Compact layout: which drawer is open ("" for none).
var _drawer := ""
var _drawer_panels := {}  # name -> PanelContainer
var _compact := false
var _is_3d := false
var _stats_values := []

var _loading: ColorRect
var _loading_title: Label
var _loading_status: Label

var _immersive := false
## Window mode changes are asynchronous (macOS animates them), so only treat "not fullscreen" as
## the user leaving once fullscreen has actually been reached.
var _reached_fullscreen := false


func _ready() -> void:
	_root = Control.new()
	_root.theme = UiTheme.build(UiScale.touch)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Title and stats.
	_title_panel = _new_panel()
	var title_box := VBoxContainer.new()
	_title_panel.add_child(title_box)
	_title = UiTheme.label("MESH PULSE", 26, UiTheme.ACCENT)
	title_box.add_child(_title)
	_stats = UiTheme.label("", 14, UiTheme.MUTED)
	title_box.add_child(_stats)

	# Sources and view controls.
	_source_panel = _new_panel()
	var source_box := VBoxContainer.new()
	source_box.custom_minimum_size.x = 280
	_source_panel.add_child(source_box)
	source_box.add_child(UiTheme.label("SOURCES", 13, UiTheme.MUTED))
	_sources = VBoxContainer.new()
	source_box.add_child(_sources)
	var buttons := HBoxContainer.new()
	source_box.add_child(buttons)
	buttons.add_child(_new_view_button())
	var setup := Button.new()
	setup.text = "Sources…"
	setup.pressed.connect(func() -> void: setup_requested.emit())
	buttons.add_child(setup)

	# Legend doubling as packet-type filters.
	_legend_panel = _new_panel()
	var legend := VBoxContainer.new()
	_legend_panel.add_child(legend)
	legend.add_child(UiTheme.label("PACKET TYPES", 13, UiTheme.MUTED))
	for row in PacketStyle.LEGEND:
		var line := HBoxContainer.new()
		legend.add_child(line)
		var swatch := ColorRect.new()
		swatch.color = PacketStyle.color_for(row[1][0])
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(swatch)
		var check := CheckBox.new()
		check.text = row[0]
		check.button_pressed = true
		var types: Array = row[1]
		check.toggled.connect(func(on: bool) -> void:
			for t in types:
				if on:
					_disabled_types.erase(t)
				else:
					_disabled_types[t] = true)
		line.add_child(check)

	# Packet log.
	_log_panel = _new_panel()
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_active = false
	_log.autowrap_mode = TextServer.AUTOWRAP_OFF
	_log.clip_contents = true
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log_panel.add_child(_log)

	# Selected node details.
	_node_panel = _new_panel()
	var node_box := VBoxContainer.new()
	node_box.custom_minimum_size.x = 280
	_node_panel.add_child(node_box)
	_node_title = UiTheme.label("", 20, UiTheme.ACCENT)
	node_box.add_child(_node_title)
	_node_body = UiTheme.label("", 14)
	node_box.add_child(_node_body)
	var node_buttons := HBoxContainer.new()
	node_box.add_child(node_buttons)
	var fly := Button.new()
	fly.text = "Fly to"
	fly.pressed.connect(func() -> void:
		if _node != null:
			fly_to_requested.emit(_node))
	node_buttons.add_child(fly)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func() -> void:
		show_node(null)
		selection_cleared.emit())
	node_buttons.add_child(close)

	# Controls hint and attribution.
	_hint = UiTheme.label("", 12, UiTheme.MUTED)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_hint)

	# Compact toolbar: drawer toggles and the 3D toggle.
	_toolbar = HBoxContainer.new()
	_root.add_child(_toolbar)
	_drawer_panels = {"Types": _legend_panel, "Log": _log_panel, "Sources": _source_panel}
	for drawer_name: String in _drawer_panels:
		var toggle := Button.new()
		toggle.text = drawer_name
		toggle.toggle_mode = true
		toggle.pressed.connect(func() -> void: _open_drawer("" if _drawer == drawer_name else drawer_name))
		toggle.set_meta("drawer", drawer_name)
		_toolbar.add_child(toggle)
	_toolbar.add_child(_new_view_button())

	# Fullscreen toggle. Fades out while fullscreen, brightens on hover.
	_fullscreen_button = Button.new()
	_fullscreen_button.tooltip_text = "Hide the UI and go fullscreen (F)"
	_root.add_child(_fullscreen_button)
	_fullscreen_button.pressed.connect(func() -> void: set_immersive(not _immersive))
	_fullscreen_button.mouse_entered.connect(func() -> void: _fullscreen_button.modulate.a = 1.0)
	_fullscreen_button.mouse_exited.connect(func() -> void: _fullscreen_button.modulate.a = 0.35 if _immersive else 1.0)

	_tooltip = PanelContainer.new()
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	_tooltip_label = UiTheme.label("", 14)
	_tooltip.add_child(_tooltip_label)
	_root.add_child(_tooltip)

	# Full-screen loading overlay, on top of everything while sources load.
	_loading = ColorRect.new()
	_loading.color = UiTheme.BG
	_loading.mouse_filter = Control.MOUSE_FILTER_STOP
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading.visible = false
	_root.add_child(_loading)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading.add_child(center)
	var loading_box := VBoxContainer.new()
	loading_box.add_theme_constant_override("separation", 14)
	center.add_child(loading_box)
	_loading_title = UiTheme.label("MESH PULSE", 54, UiTheme.ACCENT)
	_loading_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_box.add_child(_loading_title)
	_loading_status = UiTheme.label("", 16, UiTheme.MUTED)
	_loading_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_box.add_child(_loading_status)
	var bar := ProgressBar.new()
	bar.indeterminate = true
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(280, 10)
	loading_box.add_child(bar)

	UiScale.layout_changed.connect(_apply_layout)
	get_viewport().size_changed.connect(func() -> void: _apply_layout.call_deferred(_compact))
	_apply_layout(UiScale.compact)


func show_loading(text: String) -> void:
	_loading_status.text = text
	_loading.modulate.a = 1.0
	_loading.visible = true


func hide_loading() -> void:
	var tween := create_tween()
	tween.tween_property(_loading, "modulate:a", 0.0, 0.4)
	tween.tween_callback(func() -> void: _loading.visible = false)


func _new_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	_root.add_child(panel)
	return panel


func _new_view_button() -> Button:
	var button := Button.new()
	button.tooltip_text = "Toggle top-down / 3D (V)"
	button.pressed.connect(func() -> void: view_3d_requested.emit(not _is_3d))
	_view_buttons.append(button)
	return button


## Positions every element for the desktop or compact layout.
func _apply_layout(compact: bool) -> void:
	_compact = compact
	var m := COMPACT_MARGIN if compact else MARGIN
	var width := _root.get_viewport_rect().size.x
	_title.add_theme_font_size_override("font_size", 20 if compact else 26)
	_loading_title.add_theme_font_size_override("font_size", 36 if compact else 54)
	_set_stats_text()
	_fullscreen_button.text = _fullscreen_label()
	set_view_3d(_is_3d)
	if compact:
		var drawer_width := width - 2.0 * m
		_log.custom_minimum_size = Vector2(drawer_width - 26.0, 230)
		_node_panel.get_child(0).custom_minimum_size.x = drawer_width - 26.0
		_hint.text = "Imagery © Esri, Maxar, Earthstar Geographics · Elevation: AWS Terrain Tiles"
		_hint.add_theme_font_size_override("font_size", 10)
		_place(_title_panel, Control.PRESET_TOP_LEFT, Vector2(m, m))
		_place(_toolbar, Control.PRESET_BOTTOM_LEFT, Vector2(m, -m))
		_place(_fullscreen_button, Control.PRESET_BOTTOM_RIGHT, Vector2(-m, -m))
		var above_toolbar := -m - _toolbar.get_combined_minimum_size().y - 8.0
		for panel in [_legend_panel, _log_panel, _source_panel, _node_panel]:
			_place(panel, Control.PRESET_BOTTOM_LEFT, Vector2(m, above_toolbar))
		_place(_hint, Control.PRESET_BOTTOM_RIGHT, Vector2(-m, above_toolbar))
	else:
		_log.custom_minimum_size = Vector2(560, 290)
		_node_panel.get_child(0).custom_minimum_size.x = 280
		_hint.text = "Drag pan · Scroll zoom · Shift/right-drag orbit · Double-click node to fly in · V 3D · R north · F fullscreen\nImagery © Esri, Maxar, Earthstar Geographics · Elevation: AWS Terrain Tiles (Mapzen)"
		_hint.add_theme_font_size_override("font_size", 12)
		_place(_title_panel, Control.PRESET_TOP_LEFT, Vector2(m, m))
		_place(_source_panel, Control.PRESET_TOP_RIGHT, Vector2(-m, m))
		_place(_legend_panel, Control.PRESET_CENTER_LEFT, Vector2(m, -60))
		_place(_log_panel, Control.PRESET_BOTTOM_LEFT, Vector2(m, -64))
		_place(_node_panel, Control.PRESET_CENTER_RIGHT, Vector2(-m, 0))
		_place(_hint, Control.PRESET_BOTTOM_RIGHT, Vector2(-12, -12))
		_place(_fullscreen_button, Control.PRESET_BOTTOM_LEFT, Vector2(m, -m))
	_refresh_visibility()


## Anchors a control to a corner or edge, growing away from it, then nudges it inward by `offset`.
func _place(c: Control, preset: Control.LayoutPreset, offset: Vector2) -> void:
	c.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE)
	var right := preset in [Control.PRESET_TOP_RIGHT, Control.PRESET_CENTER_RIGHT, Control.PRESET_BOTTOM_RIGHT]
	var bottom := preset in [Control.PRESET_BOTTOM_LEFT, Control.PRESET_BOTTOM_RIGHT]
	var middle := preset in [Control.PRESET_CENTER_LEFT, Control.PRESET_CENTER_RIGHT]
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	if middle:
		c.grow_vertical = Control.GROW_DIRECTION_BOTH
	else:
		c.grow_vertical = Control.GROW_DIRECTION_BEGIN if bottom else Control.GROW_DIRECTION_END
	c.position += offset


func _open_drawer(drawer_name: String) -> void:
	_drawer = drawer_name
	_refresh_visibility()


func _refresh_visibility() -> void:
	var shown := not _immersive
	_title_panel.visible = shown
	_hint.visible = shown
	_toolbar.visible = shown and _compact
	for drawer_name: String in _drawer_panels:
		_drawer_panels[drawer_name].visible = shown and (not _compact or _drawer == drawer_name)
	_node_panel.visible = shown and _node != null and (not _compact or _drawer == "")
	for toggle in _toolbar.get_children():
		if toggle.has_meta("drawer"):
			toggle.set_pressed_no_signal(toggle.get_meta("drawer") == _drawer)
	if not shown:
		_tooltip.visible = false


func _fullscreen_label() -> String:
	if _compact:
		return "Show UI" if _immersive else "Hide UI"
	return "Exit fullscreen" if _immersive else "Fullscreen"


## Fullscreen mode: hides every overlay and makes the window fullscreen. Leaving fullscreen by other
## means (Esc in a browser, the macOS green button) brings the UI back too.
func set_immersive(enabled: bool) -> void:
	_immersive = enabled
	_reached_fullscreen = false
	_refresh_visibility()
	_fullscreen_button.text = _fullscreen_label()
	_fullscreen_button.modulate.a = 0.35 if enabled else 1.0
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if enabled else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)


func _process(_delta: float) -> void:
	if not _immersive:
		return
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		_reached_fullscreen = true
	elif _reached_fullscreen:
		set_immersive(false)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		set_immersive(not _immersive)
		get_viewport().set_input_as_handled()


func is_type_enabled(payload_type: int) -> bool:
	return not _disabled_types.has(payload_type)


func set_view_3d(is_3d: bool) -> void:
	_is_3d = is_3d
	for button in _view_buttons:
		button.text = ("Top" if is_3d else "3D") if _compact else ("Top-down" if is_3d else "3D view")


func set_stats(nodes: int, located: int, per_minute: int, in_flight: int, dropped: int) -> void:
	_stats_values = [nodes, located, per_minute, in_flight, dropped]
	_set_stats_text()


func _set_stats_text() -> void:
	if _stats_values.is_empty():
		return
	var v: Array = _stats_values
	if _compact:
		_stats.text = "%d nodes · %d pkt/min · %d in flight" % [v[0], v[2], v[3]]
		return
	var text := "%d nodes (%d mapped) · %d pkt/min · %d in flight" % [v[0], v[1], v[2], v[3]]
	if v[4] > 0:
		text += " · %d skipped (busy)" % v[4]
	_stats.text = text


func set_broker_status(index: int, broker_name: String, state: MqttClient.State, detail: String) -> void:
	var label: Label = _broker_labels.get(index)
	if label == null:
		label = UiTheme.label("", 14)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_sources.add_child(label)
		_broker_labels[index] = label
	var colors := {
		MqttClient.State.CONNECTED: UiTheme.GOOD,
		MqttClient.State.CONNECTING: UiTheme.WARN,
		MqttClient.State.ERROR: UiTheme.BAD,
		MqttClient.State.DISCONNECTED: UiTheme.MUTED,
	}
	var words := ["offline", "connecting", "live", "error"]
	label.text = "● %s — %s" % [broker_name, words[state]]
	label.tooltip_text = detail
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_theme_color_override("font_color", colors[state])
	if state == MqttClient.State.ERROR and detail != "":
		label.text += "\n   " + detail


func add_source_note(text: String, color := UiTheme.MUTED) -> void:
	var label := UiTheme.label(text, 14, color)
	_sources.add_child(label)


func log_packet(pkt: Dictionary, resolved_hops: int) -> void:
	var color := PacketStyle.color_for(pkt.payload_type).to_html(false)
	var observer: String = pkt.get("observer_name", "")
	if observer == "":
		observer = str(pkt.get("observer", "")).substr(0, 8).to_upper()
	var hops: Array = pkt.get("hops", [])
	var line := "[color=#%s]■ %-8s[/color] [color=#6f8aa3]%s[/color]  %d hop%s (%d mapped)  ← %s" % [
		color, pkt.type_name, Time.get_time_string_from_system(), hops.size(), "" if hops.size() == 1 else "s",
		resolved_hops, observer.left(22),
	]
	if pkt.get("snr", 0.0) != 0.0:
		line += "  [color=#6f8aa3]SNR %.1f[/color]" % pkt.snr
	_log_lines.push_front(line)
	if _log_lines.size() > LOG_LINES:
		_log_lines.pop_back()
	_log.text = "[color=#6f8aa3]RECENT PACKETS[/color]\n" + "\n".join(_log_lines)


func show_node(node: MeshNode, hop_count := 0) -> void:
	_node = node
	if node != null and _compact:
		_drawer = ""
	_refresh_visibility()
	if node == null:
		return
	_node_title.text = node.display_name()
	var lines := [
		node.type_name(),
		"Key  %s…" % node.pubkey.substr(0, 16).to_upper(),
		"%.5f, %.5f" % [node.lat, node.lon] if node.has_location else "No location",
		"Packets relayed (this session)  %d" % hop_count,
	]
	if node.source != "beacon":
		lines.append("Source  %s" % node.source)
	_node_body.text = "\n".join(lines)


## Hover tooltip; skipped on touch screens, where there is no hover.
func show_tooltip(node: MeshNode, screen_pos: Vector2) -> void:
	_tooltip.visible = node != null and not _immersive and not UiScale.touch
	if not _tooltip.visible:
		return
	_tooltip_label.text = "%s\n%s · %s" % [node.display_name(), node.type_name(), node.short_id()]
	_tooltip.reset_size()
	_tooltip.position = screen_pos + Vector2(16, 16)
