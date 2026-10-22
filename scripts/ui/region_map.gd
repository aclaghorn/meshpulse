class_name RegionMap
extends Control
## Flat Web Mercator map of IATA regions for the region picker: satellite tiles from the Tiles autoload,
## one checkbox centred on each region's location, drag to pan, wheel or pinch to zoom.
##
## View coordinates are normalised Mercator (0..1 across the world, y grows southward). Where boxes
## would overlap, the selected ones and then the alphabetically first are kept; zooming in reveals the rest.

signal region_toggled(iata: String, on: bool)

const TILE_PX := 256.0
const MIN_ZOOM := 0.0
const MAX_ZOOM := 9.0
const MAX_TILE_ZOOM := 14
## Zoom when jumping to a single region.
const FOCUS_ZOOM := 6.0
## Screen-space grid bucketing boxes for the overlap test.
const CELL := Vector2(64, 32)

var _center := Vector2(0.5, 0.42)
var _zoom := 2.0
var _regions: Array[Dictionary] = []  # {iata, pos: Vector2 (normalised), box: CheckBox}
var _selected := PackedStringArray()
var _at_limit := false
var _fit_pending := true
var _dragging := false
var _touches := {}  # index -> position
var _pinch_distance := 0.0
var _tween: Tween
var _attribution: Label


func _ready() -> void:
	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP
	_attribution = UiTheme.label("Imagery © Esri", 11, UiTheme.MUTED)
	_attribution.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_attribution)
	Tiles.tile_ready.connect(func(source: StringName, _key: Vector3i) -> void:
		if source == &"imagery":
			queue_redraw())
	resized.connect(_on_resized)


## `regions`: [{iata, displayName, lat, lon}] as returned by BeaconClient.fetch_iatas. Regions without
## coordinates are left off the map.
func set_regions(regions: Array) -> void:
	for r in _regions:
		r.box.queue_free()
	_regions.clear()
	for item in regions:
		if item.get("lat") == null or item.get("lon") == null:
			continue
		var code: String = item.iata
		var box := CheckBox.new()
		box.text = code
		box.focus_mode = FOCUS_NONE
		box.add_theme_font_size_override("font_size", 12)
		box.add_theme_color_override("font_outline_color", Color.BLACK)
		box.add_theme_constant_override("outline_size", 4)
		box.tooltip_text = "%s · %s" % [code, item.displayName] if item.get("displayName") != null else code
		box.toggled.connect(func(on: bool) -> void: region_toggled.emit(code, on))
		add_child(box)
		_regions.append({"iata": code, "pos": to_view(float(item.lat), float(item.lon)), "box": box})
	_attribution.move_to_front()
	set_selected(_selected, _at_limit)
	_fit_pending = true
	_on_resized()


## Ticks the given codes; with `at_limit` the unticked boxes are disabled.
func set_selected(codes: PackedStringArray, at_limit: bool) -> void:
	_selected = codes
	_at_limit = at_limit
	for r in _regions:
		var on := codes.has(r.iata)
		r.box.set_pressed_no_signal(on)
		r.box.disabled = at_limit and not on
	_layout_boxes()


## Glides the map to a region, zooming in if the map is zoomed far out.
func focus(iata: String) -> void:
	for r in _regions:
		if r.iata == iata:
			_animate_to(r.pos, maxf(_zoom, FOCUS_ZOOM))
			return


## Normalised Mercator coordinates of a lat/lon.
static func to_view(lat: float, lon: float) -> Vector2:
	return Geo.mercator_to_tile(Geo.lon_to_mx(lon), Geo.lat_to_my(lat), 0)


func _world_px() -> float:
	return TILE_PX * pow(2.0, _zoom)


func _to_screen(p: Vector2) -> Vector2:
	# Pick the copy of the point nearest the centre, so the map wraps east-west.
	var dx := wrapf(p.x - _center.x, -0.5, 0.5)
	return Vector2(dx, p.y - _center.y) * _world_px() + size / 2.0


func _to_view(screen: Vector2) -> Vector2:
	return _center + (screen - size / 2.0) / _world_px()


func _min_zoom() -> float:
	# Never zoom out past the world filling the map's height.
	return clampf(log(maxf(size.y, 1.0) / TILE_PX) / log(2.0), MIN_ZOOM, MAX_ZOOM)


func _on_resized() -> void:
	if size.x < 1.0 or size.y < 1.0:
		return
	if _fit_pending:
		_fit_pending = false
		_fit_selected()
	_set_view(_center, _zoom)
	_attribution.position = size - _attribution.get_combined_minimum_size() - Vector2(6, 4)


## Frames the selected regions, or the whole world when nothing is selected.
func _fit_selected() -> void:
	var points: Array[Vector2] = []
	for r in _regions:
		if _selected.has(r.iata):
			points.append(r.pos)
	if points.is_empty():
		_set_view(Vector2(0.5, 0.42), log(maxf(size.x, 1.0) / TILE_PX) / log(2.0))
		return
	var bounds := Rect2(points[0], Vector2.ZERO)
	for p in points:
		bounds = bounds.expand(p)
	var span := maxf(bounds.size.x * size.y / maxf(size.x, 1.0), bounds.size.y)
	var zoom := FOCUS_ZOOM if span <= 0.0 else log(size.y * 0.6 / (span * TILE_PX)) / log(2.0)
	_set_view(bounds.get_center(), minf(zoom, FOCUS_ZOOM))


func _set_view(center: Vector2, zoom: float) -> void:
	_zoom = clampf(zoom, _min_zoom(), MAX_ZOOM)
	var half_h := size.y / 2.0 / _world_px()
	_center = Vector2(wrapf(center.x, 0.0, 1.0), clampf(center.y, minf(half_h, 0.5), maxf(1.0 - half_h, 0.5)))
	_layout_boxes()
	queue_redraw()


func _animate_to(center: Vector2, zoom: float) -> void:
	if _tween:
		_tween.kill()
	var from_center := _center
	var to_center := Vector2(from_center.x + wrapf(center.x - from_center.x, -0.5, 0.5), center.y)
	var from_zoom := _zoom
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(func(t: float) -> void:
		_set_view(from_center.lerp(to_center, t), lerpf(from_zoom, zoom, t)), 0.0, 1.0, 0.6)


func _zoom_at(screen: Vector2, factor: float) -> void:
	if _tween:
		_tween.kill()
	var anchor := _to_view(screen)
	var new_zoom := clampf(_zoom + log(factor) / log(2.0), _min_zoom(), MAX_ZOOM)
	var scale := pow(2.0, _zoom - new_zoom)
	_set_view(anchor + (_center - anchor) * scale, new_zoom)


func _pan_by(screen_delta: Vector2) -> void:
	if _tween:
		_tween.kill()
	_set_view(_center - screen_delta / _world_px(), _zoom)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_at(event.position, 1.25)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_at(event.position, 0.8)
			MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging and _touches.size() < 2:
		_pan_by(event.relative)
		accept_event()
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		accept_event()
	elif event is InputEventPanGesture:
		_pan_by(-event.delta * 8.0)
		accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		_pinch_distance = _touch_spread()
	elif event is InputEventScreenDrag and _touches.has(event.index):
		_touches[event.index] = event.position
		if _touches.size() == 2:
			var spread := _touch_spread()
			if _pinch_distance > 0.0 and spread > 0.0:
				var mid: Vector2 = (_touches.values()[0] + _touches.values()[1]) / 2.0
				_zoom_at(mid, spread / _pinch_distance)
			_pinch_distance = spread
		accept_event()


func _touch_spread() -> float:
	if _touches.size() != 2:
		return 0.0
	var points: Array = _touches.values()
	return (points[0] as Vector2).distance_to(points[1])


## Places each box over its region and hides the ones that would collide with a box already placed.
func _layout_boxes() -> void:
	if size.x < 1.0:
		return
	var order: Array[Dictionary] = []
	for r in _regions:
		if _selected.has(r.iata):
			order.append(r)
	for r in _regions:
		if not _selected.has(r.iata):
			order.append(r)
	var placed := {}  # Vector2i cell -> Array[Rect2] of visible boxes starting there
	for r in order:
		var box: CheckBox = r.box
		var box_size := box.get_combined_minimum_size()
		box.size = box_size
		var p := _to_screen(r.pos)
		# Centre the tick box itself (at the left edge of the control) on the location.
		box.position = p - Vector2(box_size.y / 2.0, box_size.y / 2.0)
		var rect := Rect2(box.position, box_size).grow(2.0)
		var cell := Vector2i((box.position / CELL).floor())
		var on_screen := Rect2(Vector2.ZERO, size).grow(box_size.x).has_point(p)
		box.visible = on_screen and (_selected.has(r.iata) or not _overlaps(placed, cell, rect))
		if box.visible:
			placed.get_or_add(cell, []).append(rect)


## Boxes are narrower than two cells and shorter than one, so only neighbouring cells can hold overlaps.
func _overlaps(placed: Dictionary, cell: Vector2i, rect: Rect2) -> bool:
	for dy in range(-1, 2):
		for dx in range(-2, 3):
			for other: Rect2 in placed.get(cell + Vector2i(dx, dy), []):
				if other.intersects(rect):
					return true
	return false


## Tile zoom for the current view. Like the 3D map, High and Ultra detail match tiles to real screen
## pixels (the canvas is stretched, so a 256 px tile can cover 600+ pixels on a high-DPI display).
func _tile_zoom() -> int:
	var bias := 0.0
	if AppConfig.map_detail != AppConfig.MapDetail.STANDARD:
		var physical_scale := get_global_transform_with_canvas().get_scale().x * get_viewport().get_final_transform().get_scale().x
		bias = log(maxf(physical_scale, 1.0)) / log(2.0)
		if AppConfig.map_detail == AppConfig.MapDetail.ULTRA:
			bias += 0.5
	return clampi(roundi(_zoom + bias), 0, MAX_TILE_ZOOM)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UiTheme.PANEL_SOLID)
	var tile_zoom := _tile_zoom()
	var tiles := 1 << tile_zoom
	var tile_px := _world_px() / tiles
	var top_left := _to_view(Vector2.ZERO) * tiles
	var bottom_right := _to_view(size) * tiles
	var keep := {}
	var center_tile := _center * tiles
	for ty in range(maxi(floori(top_left.y), 0), mini(floori(bottom_right.y), tiles - 1) + 1):
		for tx_unwrapped in range(floori(top_left.x), floori(bottom_right.x) + 1):
			var tx := posmod(tx_unwrapped, tiles)
			var rect := Rect2((Vector2(tx_unwrapped, ty) - center_tile) * tile_px + size / 2.0, Vector2.ONE * tile_px)
			var key := Vector3i(tx, ty, tile_zoom)
			keep[Tiles.tile_id(&"imagery", key)] = true
			var tile := Tiles.get_tile(&"imagery", key)
			if not tile.is_empty():
				draw_texture_rect(tile.texture, rect, false)
				continue
			Tiles.request(&"imagery", key, Vector2(tx_unwrapped, ty).distance_to(center_tile))
			_draw_ancestor(key, rect)
	Tiles.cancel_except(&"imagery", keep)


## Stretches the nearest loaded lower-zoom tile over a tile that is still loading.
func _draw_ancestor(key: Vector3i, rect: Rect2) -> void:
	for up in range(1, mini(key.z, 6) + 1):
		var parent := Vector3i(key.x >> up, key.y >> up, key.z - up)
		var tile := Tiles.get_tile(&"imagery", parent)
		if tile.is_empty():
			continue
		var tex: Texture2D = tile.texture
		var part := tex.get_size() / float(1 << up)
		var offset := Vector2(key.x - (parent.x << up), key.y - (parent.y << up)) * part
		draw_texture_rect_region(tex, rect, Rect2(offset, part))
		return
