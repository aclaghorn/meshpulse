extends Node
## Fetches XYZ map tiles with a small HTTP worker pool, a disk cache under user://tilecache and an
## in-memory LRU. Also answers point elevation queries from Terrarium tiles.

signal tile_ready(source: StringName, key: Vector3i)

const SOURCES := {
	&"imagery": {
		"url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
		"ext": "jpg",
		"mipmaps": true,
	},
	# Terrarium encoding: metres = R * 256 + G + B / 256 - 32768
	&"terrain": {
		"url": "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
		"ext": "png",
		"mipmaps": false,
	},
}
const TERRAIN_MAX_ZOOM := 14
const WORKERS := 8
const DISK_LOADS_PER_FRAME := 6
const MEMORY_LIMIT := 900
const RETRY_FAILED_MS := 60000
## Coarse elevation used for every node, refined near the camera.
const ELEVATION_ZOOM_COARSE := 10
const ELEVATION_ZOOM_FINE := 12

var _memory := {}  # id -> {image, texture, used}
var _queue := {}  # id -> {source, key, priority}
var _in_flight := {}  # id -> true
var _failed := {}  # id -> ticks_msec
var _idle_workers: Array[HTTPRequest] = []
var _use_counter := 0


func _ready() -> void:
	for i in WORKERS:
		var http := HTTPRequest.new()
		http.timeout = 15.0
		http.use_threads = true
		add_child(http)
		_idle_workers.append(http)


static func tile_id(source: StringName, key: Vector3i) -> String:
	return "%s/%d/%d/%d" % [source, key.z, key.x, key.y]


## Returns {image, texture} when the tile is in memory, otherwise {}.
func get_tile(source: StringName, key: Vector3i) -> Dictionary:
	var entry: Dictionary = _memory.get(tile_id(source, key), {})
	if not entry.is_empty():
		_use_counter += 1
		entry.used = _use_counter
	return entry


## Queues a tile; lower priority values load first. Re-requesting updates the priority.
func request(source: StringName, key: Vector3i, priority := 0.0) -> void:
	var id := tile_id(source, key)
	if _memory.has(id) or _in_flight.has(id):
		return
	if _failed.has(id) and Time.get_ticks_msec() - _failed[id] < RETRY_FAILED_MS:
		return
	_queue[id] = {"source": source, "key": key, "priority": priority}


## Drops queued (not yet in-flight) requests for a source that aren't in `keep` (a set of ids).
func cancel_except(source: StringName, keep: Dictionary) -> void:
	for id in _queue.keys():
		if _queue[id].source == source and not keep.has(id):
			_queue.erase(id)


## Ground elevation in km, or NAN while the elevation tile is still loading (it gets requested).
func sample_elevation_km(lat: float, lon: float, fine := false) -> float:
	var mx := Geo.lon_to_mx(lon)
	var my := Geo.lat_to_my(lat)
	if fine:
		var h := _sample(mx, my, ELEVATION_ZOOM_FINE, true)
		if not is_nan(h):
			return h
	return _sample(mx, my, ELEVATION_ZOOM_COARSE, true)


func _sample(mx: float, my: float, zoom: int, load_missing: bool) -> float:
	var t := Geo.mercator_to_tile(mx, my, zoom)
	var key := Vector3i(int(t.x), int(t.y), zoom)
	var entry := get_tile(&"terrain", key)
	if entry.is_empty():
		if load_missing:
			request(&"terrain", key, 50.0)
		return NAN
	var img: Image = entry.image
	var px := clampi(int((t.x - floorf(t.x)) * img.get_width()), 0, img.get_width() - 1)
	var py := clampi(int((t.y - floorf(t.y)) * img.get_height()), 0, img.get_height() - 1)
	var c := img.get_pixel(px, py)
	return maxf(0.0, c.r8 * 256.0 + c.g8 + c.b8 / 256.0 - 32768.0) / 1000.0


func _process(_delta: float) -> void:
	if _queue.is_empty():
		return
	var ids := _queue.keys()
	ids.sort_custom(func(a, b): return _queue[a].priority < _queue[b].priority)
	var disk_loads := 0
	for id: String in ids:
		var req: Dictionary = _queue[id]
		var path := _disk_path(req.source, req.key)
		if FileAccess.file_exists(path):
			if disk_loads >= DISK_LOADS_PER_FRAME:
				continue
			disk_loads += 1
			_queue.erase(id)
			if not _store(id, req.source, req.key, FileAccess.get_file_as_bytes(path)):
				DirAccess.remove_absolute(path)
			continue
		if _idle_workers.is_empty():
			continue
		_queue.erase(id)
		_start_download(id, req)


func _start_download(id: String, req: Dictionary) -> void:
	var http: HTTPRequest = _idle_workers.pop_back()
	var key: Vector3i = req.key
	var url: String = SOURCES[req.source].url.format({"z": key.z, "x": key.x, "y": key.y})
	_in_flight[id] = true
	var on_done := _on_downloaded.bind(http, id, req)
	http.request_completed.connect(on_done, CONNECT_ONE_SHOT)
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("User-Agent: MeshPulse/0.1 (Godot)")
	var err := http.request(url, headers)
	if err != OK:
		http.request_completed.disconnect(on_done)
		_finish_worker(http, id)
		_failed[id] = Time.get_ticks_msec()


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, id: String, req: Dictionary) -> void:
	_finish_worker(http, id)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.is_empty():
		_failed[id] = Time.get_ticks_msec()
		return
	if _store(id, req.source, req.key, body):
		var path := _disk_path(req.source, req.key)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(body)


func _finish_worker(http: HTTPRequest, id: String) -> void:
	_in_flight.erase(id)
	_idle_workers.append(http)


func _store(id: String, source: StringName, key: Vector3i, bytes: PackedByteArray) -> bool:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(bytes) if SOURCES[source].ext == "jpg" else img.load_png_from_buffer(bytes)
	if err != OK:
		_failed[id] = Time.get_ticks_msec()
		return false
	if SOURCES[source].mipmaps:
		img.generate_mipmaps()
	_use_counter += 1
	_memory[id] = {"image": img, "texture": ImageTexture.create_from_image(img), "used": _use_counter}
	_evict()
	tile_ready.emit(source, key)
	return true


func _evict() -> void:
	if _memory.size() <= MEMORY_LIMIT:
		return
	var ids := _memory.keys()
	ids.sort_custom(func(a, b): return _memory[a].used < _memory[b].used)
	for i in ids.size() - MEMORY_LIMIT:
		_memory.erase(ids[i])


func _disk_path(source: StringName, key: Vector3i) -> String:
	return "user://tilecache/%s/%d/%d/%d.%s" % [source, key.z, key.x, key.y, SOURCES[source].ext]
