extends Node3D
## Streams satellite imagery over Terrarium elevation around the camera focus, as nested zoom levels:
## the finest level under the camera, each coarser level covering twice the area for tilted views.

const GRID := 32
const LEVELS := 4
## Tiles each side of the centre tile, per level. Grows with the screen so wide views stay covered.
const MIN_RADIUS := 3
const MAX_RADIUS := 6
## Finest-level tiles across the screen at STANDARD detail, whatever its size.
const STANDARD_TILES_ACROSS := 2.5
## Screen pixels one finest-level tile spans at HIGH and ULTRA detail (imagery tiles are 256 px).
const TILE_PX := {AppConfig.MapDetail.HIGH: 640.0, AppConfig.MapDetail.ULTRA: 400.0}
const MIN_ZOOM := 2
const MAX_ZOOM := 18
const UPDATE_INTERVAL := 0.15
## A tile with imagery but no elevation yet is shown flat after this long, rather than staying hidden.
const HEIGHT_WAIT_MS := 2000
const DEPTH_PUSH_PER_LEVEL := 0.02


class TileView:
	var key: Vector3i
	var height_key: Vector3i
	var instance: MeshInstance3D
	var material: ShaderMaterial
	var has_image := false
	var has_height := false
	var created_ms := 0


var _shader: Shader = preload("res://shaders/terrain_tile.gdshader")
var _mesh: ArrayMesh
var _tiles := {}  # Vector3i -> TileView
var _timer := 0.0
var base_zoom := -1


func _ready() -> void:
	_mesh = _build_grid_mesh()
	Tiles.tile_ready.connect(_on_tile_ready)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_INTERVAL
	_update_tiles()


func _update_tiles() -> void:
	var cam := get_viewport().get_camera_3d() as MapCamera
	if cam == null:
		return
	# Real render pixels: the stretched logical size stays ~1600 wide on any screen.
	var px := Vector2(get_viewport().size)
	var aspect := maxf(1.0, px.x / maxf(px.y, 1.0))
	var view_km := 2.0 * cam.distance * tan(deg_to_rad(cam.fov) * 0.5) * aspect
	var world_km := 2.0 * Geo.ORIGIN_SHIFT * Geo.km_per_mercator_m
	var tiles_across := STANDARD_TILES_ACROSS
	if AppConfig.map_detail != AppConfig.MapDetail.STANDARD:
		# view_km spans the longer side (fov is vertical, aspect clamped to >= 1), so match it.
		tiles_across = maxf(px.x, px.y) / TILE_PX[AppConfig.map_detail]
	# Never ask for more tiles than the largest ring can cover.
	tiles_across = clampf(tiles_across, STANDARD_TILES_ACROSS, 2.0 * (MAX_RADIUS - 2))
	var radius := clampi(ceili(tiles_across * 0.5 + 1.75), MIN_RADIUS, MAX_RADIUS)
	base_zoom = clampi(roundi(log(world_km * tiles_across / view_km) / log(2.0)), MIN_ZOOM, MAX_ZOOM)

	var center := Geo.world_to_mercator(cam.target.x, cam.target.z)
	var wanted := {}  # key -> level
	var keep_imagery := {}
	var keep_terrain := {}
	var now := Time.get_ticks_msec()
	for level in LEVELS:
		var z := base_zoom - level
		if z < 1:
			break
		var n := 1 << z
		var c := Geo.mercator_to_tile(center.x, center.y, z)
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var tx := int(c.x) + dx
				var ty := int(c.y) + dy
				if tx < 0 or ty < 0 or tx >= n or ty >= n:
					continue
				var key := Vector3i(tx, ty, z)
				wanted[key] = level
				var tile: TileView = _tiles.get(key)
				if tile == null:
					tile = _create_tile(key)
				var priority := level * 100.0 + absf(dx) + absf(dy)
				if not tile.has_image:
					Tiles.request(&"imagery", key, priority)
					keep_imagery[Tiles.tile_id(&"imagery", key)] = true
				if not tile.has_height:
					Tiles.request(&"terrain", tile.height_key, priority - 0.5)
					keep_terrain[Tiles.tile_id(&"terrain", tile.height_key)] = true

	for key: Vector3i in _tiles.keys():
		if not wanted.has(key):
			_tiles[key].instance.queue_free()
			_tiles.erase(key)
	Tiles.cancel_except(&"imagery", keep_imagery)
	Tiles.cancel_except(&"terrain", keep_terrain)

	for key: Vector3i in _tiles:
		var tile: TileView = _tiles[key]
		tile.material.set_shader_parameter("depth_push", wanted[key] * DEPTH_PUSH_PER_LEVEL)
		tile.instance.visible = tile.has_image and (tile.has_height or now - tile.created_ms > HEIGHT_WAIT_MS)


func set_vertical_scale(value: float) -> void:
	for tile: TileView in _tiles.values():
		tile.material.set_shader_parameter("vertical_scale", value)


func _create_tile(key: Vector3i) -> TileView:
	var tile := TileView.new()
	tile.key = key
	tile.created_ms = Time.get_ticks_msec()
	var hz := mini(key.z, Tiles.TERRAIN_MAX_ZOOM)
	var shift := key.z - hz
	tile.height_key = Vector3i(key.x >> shift, key.y >> shift, hz)
	var sub := 1.0 / float(1 << shift)
	var height_rect := Vector4((key.x - (tile.height_key.x << shift)) * sub, (key.y - (tile.height_key.y << shift)) * sub, sub, sub)

	var size_km := Geo.tile_size_m(key.z) * Geo.km_per_mercator_m
	var nw := Geo.tile_nw_mercator(key.z, key.x, key.y)
	var nw_world := Geo.mercator_to_world(nw.x, nw.y)

	tile.material = ShaderMaterial.new()
	tile.material.shader = _shader
	tile.material.set_shader_parameter("height_rect", height_rect)
	tile.material.set_shader_parameter("vertical_scale", Geo.vertical_scale)
	tile.material.set_shader_parameter("skirt_depth", size_km * 0.03 + 0.05)

	tile.instance = MeshInstance3D.new()
	tile.instance.mesh = _mesh
	tile.instance.material_override = tile.material
	tile.instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile.instance.transform = Transform3D(Basis.from_scale(Vector3(size_km, 1.0, size_km)), Vector3(nw_world.x, 0.0, nw_world.y))
	# Displacement happens on the GPU, so give culling room for mountains.
	tile.instance.custom_aabb = AABB(Vector3(0.0, -1.0, 0.0), Vector3(1.0, 9.0 * maxf(Geo.vertical_scale, 1.0) + 2.0, 1.0))
	tile.instance.extra_cull_margin = size_km * 0.1
	tile.instance.visible = false
	add_child(tile.instance)
	_tiles[key] = tile

	_apply_imagery(tile)
	_apply_height(tile)
	return tile


func _apply_imagery(tile: TileView) -> void:
	var entry := Tiles.get_tile(&"imagery", tile.key)
	if entry.is_empty():
		return
	tile.material.set_shader_parameter("imagery", entry.texture)
	tile.has_image = true


func _apply_height(tile: TileView) -> void:
	var entry := Tiles.get_tile(&"terrain", tile.height_key)
	if entry.is_empty():
		return
	tile.material.set_shader_parameter("heightmap", entry.texture)
	tile.material.set_shader_parameter("has_height", true)
	tile.has_height = true


func _on_tile_ready(source: StringName, key: Vector3i) -> void:
	if source == &"imagery":
		var tile: TileView = _tiles.get(key)
		if tile != null and not tile.has_image:
			_apply_imagery(tile)
	elif source == &"terrain":
		for tile: TileView in _tiles.values():
			if tile.height_key == key and not tile.has_height:
				_apply_height(tile)


## A unit grid on XZ in [0, 1] with UV = position, plus a skirt (UV2.x = 1) dropped below each edge.
func _build_grid_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var row := GRID + 1
	for j in row:
		for i in row:
			var u := float(i) / GRID
			var v := float(j) / GRID
			verts.append(Vector3(u, 0.0, v))
			uvs.append(Vector2(u, v))
			uv2s.append(Vector2.ZERO)
	for j in GRID:
		for i in GRID:
			var a := j * row + i
			indices.append_array([a, a + 1, a + row, a + 1, a + row + 1, a + row])

	# Skirts: walk each edge, duplicating its vertices as skirt vertices.
	var edges := [
		func(k: int) -> int: return k,  # north
		func(k: int) -> int: return GRID * row + k,  # south
		func(k: int) -> int: return k * row,  # west
		func(k: int) -> int: return k * row + GRID,  # east
	]
	for edge: Callable in edges:
		var start := verts.size()
		for k in row:
			var src: int = edge.call(k)
			verts.append(verts[src])
			uvs.append(uvs[src])
			uv2s.append(Vector2(1.0, 0.0))
		for k in GRID:
			var a: int = edge.call(k)
			var b: int = edge.call(k + 1)
			indices.append_array([a, b, start + k, b, start + k + 1, start + k])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
