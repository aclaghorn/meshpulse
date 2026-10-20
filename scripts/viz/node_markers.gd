class_name NodeMarkers
extends Node3D
## Draws every located node as a screen-constant dot (one MultiMesh), keeps the dots on the terrain
## as elevation arrives, flashes nodes as packets pass through, and labels nearby/selected nodes.

const BASE_COLORS := {
	MeshNode.Type.REPEATER: Color(0.25, 0.85, 1.0),
	MeshNode.Type.ROOM_SERVER: Color(0.75, 0.5, 1.0),
	MeshNode.Type.COMPANION: Color(0.45, 0.8, 0.5),
	MeshNode.Type.SENSOR: Color(1.0, 0.75, 0.3),
	MeshNode.Type.UNKNOWN: Color(0.6, 0.65, 0.7),
}
const BASE_SIZE_PX := {
	MeshNode.Type.REPEATER: 11.0,
	MeshNode.Type.ROOM_SERVER: 10.0,
	MeshNode.Type.COMPANION: 7.0,
	MeshNode.Type.SENSOR: 7.0,
	MeshNode.Type.UNKNOWN: 7.0,
}
const FLASH_SECONDS := 1.4
const PICK_RADIUS_PX := 14.0
const LABEL_LIMIT := 60
## Repeaters get labels once the camera is closer than this (km).
const LABEL_DISTANCE_KM := 35.0
## Nodes this close to the camera target get fine elevation, km.
const FINE_ELEVATION_RADIUS_KM := 40.0
## Dots float this far above the ground (world units).
const LIFT := 0.01

var selected: MeshNode
var hovered: MeshNode

var _mm := MultiMesh.new()
var _order: Array[MeshNode] = []
var _index := {}  # pubkey -> instance index
var _flash := {}  # instance index -> {t, color}
var _labels: Array[Label3D] = []
var _label_timer := 0.0
var _rebuild_queued := false
var _positions_dirty := false
var _material := ShaderMaterial.new()


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = quad
	_material.shader = preload("res://shaders/node_marker.gdshader")
	_material.render_priority = 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

	for i in LABEL_LIMIT:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.no_depth_test = true
		label.pixel_size = 0.0009
		# Labels keep a fixed pixel size, so they need to be smaller on narrow phone screens.
		label.font_size = 18 if UiScale.compact else 26
		label.outline_size = 8
		label.outline_modulate = Color(0, 0, 0, 0.85)
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		label.offset = Vector2(0, 22)
		label.render_priority = 2
		label.visible = false
		add_child(label)
		_labels.append(label)

	MeshData.nodes_changed.connect(_queue_rebuild)
	Tiles.tile_ready.connect(_on_tile_ready)
	rebuild()


func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		get_tree().create_timer(0.4).timeout.connect(rebuild)


func rebuild() -> void:
	_rebuild_queued = false
	_order = MeshData.located_nodes()
	# Repeaters last so they draw over companions.
	_order.sort_custom(func(a: MeshNode, b: MeshNode) -> bool: return int(a.can_repeat()) < int(b.can_repeat()))
	_index.clear()
	_flash.clear()
	_mm.instance_count = _order.size()
	for i in _order.size():
		_index[_order[i].pubkey] = i
		_mm.set_instance_custom_data(i, _custom_for(_order[i], 0.0, Color.WHITE))
	_update_positions()


## World position for a node's dot (also cached on the node).
func world_of(node: MeshNode) -> Vector3:
	if node.world == Vector3.ZERO:
		_place(node)
	return node.world


func flash(node: MeshNode, color: Color) -> void:
	var i: int = _index.get(node.pubkey, -1)
	if i >= 0:
		_flash[i] = {"t": FLASH_SECONDS, "color": color}


## The node whose dot is nearest to a screen position, within the pick radius.
func pick(screen_pos: Vector2) -> MeshNode:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var best: MeshNode = null
	var best_d := PICK_RADIUS_PX
	for node in _order:
		if cam.is_position_behind(node.world):
			continue
		var d := cam.unproject_position(node.world).distance_to(screen_pos)
		if d < best_d:
			best_d = d
			best = node
	return best


func _process(delta: float) -> void:
	for i: int in _flash.keys():
		var f: Dictionary = _flash[i]
		f.t -= delta
		var amount := clampf(f.t / FLASH_SECONDS, 0.0, 1.0)
		if i < _order.size():
			_mm.set_instance_custom_data(i, _custom_for(_order[i], amount, f.color))
		if f.t <= 0.0:
			_flash.erase(i)

	if _positions_dirty:
		_positions_dirty = false
		_update_positions()

	_label_timer -= delta
	if _label_timer <= 0.0:
		_label_timer = 0.25
		_update_labels()
		_request_fine_elevation()


func _custom_for(node: MeshNode, flash_amount: float, flash_color: Color) -> Color:
	var base: Color = BASE_COLORS.get(node.type, BASE_COLORS[MeshNode.Type.UNKNOWN])
	var size: float = BASE_SIZE_PX.get(node.type, 7.0)
	if node == selected:
		base = Color(1.0, 1.0, 1.0)
		size += 5.0
	var c := base.lerp(flash_color, flash_amount) * (1.0 + flash_amount * 3.0)
	return Color(c.r, c.g, c.b, size + flash_amount * 8.0)


func _place(node: MeshNode) -> void:
	var cam := get_viewport().get_camera_3d() as MapCamera
	var fine := cam != null and cam.target.distance_to(Geo.latlon_to_world(node.lat, node.lon)) < FINE_ELEVATION_RADIUS_KM
	var elev := Tiles.sample_elevation_km(node.lat, node.lon, fine)
	node.world = Geo.latlon_to_world(node.lat, node.lon, 0.0 if is_nan(elev) else elev) + Vector3.UP * LIFT


func _update_positions() -> void:
	for i in _order.size():
		_place(_order[i])
		_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, _order[i].world))


func _on_tile_ready(source: StringName, key: Vector3i) -> void:
	if source == &"terrain" and (key.z == Tiles.ELEVATION_ZOOM_COARSE or key.z == Tiles.ELEVATION_ZOOM_FINE):
		_positions_dirty = true


func _request_fine_elevation() -> void:
	var cam := get_viewport().get_camera_3d() as MapCamera
	if cam == null or cam.distance > FINE_ELEVATION_RADIUS_KM * 2.0:
		return
	for node in _order:
		if Vector2(node.world.x - cam.target.x, node.world.z - cam.target.z).length() < FINE_ELEVATION_RADIUS_KM:
			Tiles.sample_elevation_km(node.lat, node.lon, true)


func set_selected(node: MeshNode) -> void:
	var previous := selected
	selected = node
	for n in [previous, node]:
		if n != null and _index.has(n.pubkey):
			_mm.set_instance_custom_data(_index[n.pubkey], _custom_for(n, 0.0, Color.WHITE))
	_update_labels()


func _update_labels() -> void:
	var cam := get_viewport().get_camera_3d() as MapCamera
	if cam == null:
		return
	var shown: Array[MeshNode] = []
	if selected != null:
		shown.append(selected)
	if hovered != null and hovered != selected:
		shown.append(hovered)
	if cam.distance < LABEL_DISTANCE_KM:
		var radius := cam.distance * 1.2
		var near: Array[MeshNode] = []
		for node in _order:
			if node.can_repeat() and not shown.has(node):
				if Vector2(node.world.x - cam.target.x, node.world.z - cam.target.z).length() < radius:
					near.append(node)
		near.sort_custom(func(a: MeshNode, b: MeshNode) -> bool:
			return a.world.distance_squared_to(cam.target) < b.world.distance_squared_to(cam.target))
		shown.append_array(near.slice(0, LABEL_LIMIT - shown.size()))
	for i in _labels.size():
		var label := _labels[i]
		if i < shown.size():
			var node := shown[i]
			label.text = node.display_name()
			label.position = node.world
			label.modulate = Color(1, 1, 1, 1) if node == selected or node == hovered else Color(0.8, 0.92, 1.0, 0.8)
			label.visible = true
		else:
			label.visible = false
