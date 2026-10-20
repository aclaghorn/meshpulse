extends Node
## Registry of every known mesh node, keyed by lowercase public key, with a prefix index for path-hash lookups.

signal nodes_changed

const DEFAULT_ORIGIN := Vector2(47.6062, -122.3321)

var nodes: Dictionary = {}  # pubkey -> MeshNode
var _by_first_byte: Dictionary = {}  # "3a" -> Array[MeshNode]
var origin_set := false
var _changed_queued := false


func clear() -> void:
	nodes.clear()
	_by_first_byte.clear()
	origin_set = false


func find(pubkey: String) -> MeshNode:
	return nodes.get(pubkey.to_lower())


## Inserts or updates a node. Coordinates of exactly (0, 0) mean "no location" in MeshCore.
func upsert(pubkey: String, node_name: String, lat: float, lon: float, type: int, source := "beacon") -> MeshNode:
	var key := pubkey.strip_edges().to_lower()
	if key.length() < 2:
		return null
	var node: MeshNode = nodes.get(key)
	var is_new := node == null
	if is_new:
		node = MeshNode.new()
		node.pubkey = key
		node.source = source
		nodes[key] = node
		var bucket: Array = _by_first_byte.get_or_add(key.substr(0, 2), [])
		bucket.append(node)
	if node_name != "":
		node.name = node_name
	if type > 0:
		node.type = type as MeshNode.Type
	var located := not (is_zero_approx(lat) and is_zero_approx(lon)) and absf(lat) <= 90.0 and absf(lon) <= 180.0
	var moved := located and (not node.has_location or node.lat != lat or node.lon != lon)
	if located:
		node.lat = lat
		node.lon = lon
		node.has_location = true
		if not origin_set:
			set_origin(lat, lon)
	if is_new or moved:
		_queue_changed()
	return node


func upsert_from_beacon(item: Dictionary) -> MeshNode:
	var lat = item.get("lat")
	var lon = item.get("lng")
	return upsert(
		str(item.get("publicKey", "")),
		str(item.get("name", "")),
		float(lat) if lat != null else 0.0,
		float(lon) if lon != null else 0.0,
		int(item.get("nodeType", 0)),
	)


## Nodes whose public key starts with the given path hash (1-3 bytes of hex).
func candidates(hash_hex: String) -> Array[MeshNode]:
	var prefix := hash_hex.to_lower()
	var out: Array[MeshNode] = []
	for node: MeshNode in _by_first_byte.get(prefix.substr(0, 2), []):
		if node.pubkey.begins_with(prefix):
			out.append(node)
	return out


func located_nodes() -> Array[MeshNode]:
	var out: Array[MeshNode] = []
	for node: MeshNode in nodes.values():
		if node.has_location:
			out.append(node)
	return out


func set_origin(lat: float, lon: float) -> void:
	origin_set = true
	Geo.set_origin(lat, lon)


## Centres the world on the median node position, which shrugs off the odd node with a bogus location.
func set_origin_from_nodes() -> void:
	var located := located_nodes()
	if located.is_empty():
		set_origin(DEFAULT_ORIGIN.x, DEFAULT_ORIGIN.y)
		return
	var lats: Array[float] = []
	var lons: Array[float] = []
	for node in located:
		lats.append(node.lat)
		lons.append(node.lon)
	lats.sort()
	lons.sort()
	set_origin(lats[lats.size() / 2], lons[lons.size() / 2])


## Fills the registry with a fake regional mesh for demo mode when no Beacon data is available.
func generate_synthetic(center := DEFAULT_ORIGIN, count := 80) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var used_prefixes := {}
	for i in count:
		var key := PackedByteArray()
		for b in 32:
			key.append(rng.randi_range(0, 255))
		# Mostly unique first bytes, with a few collisions to exercise hop disambiguation.
		if used_prefixes.has(key[0]) and rng.randf() < 0.8:
			key[0] = (key[0] + 97) % 256
		used_prefixes[key[0]] = true
		var roll := rng.randf()
		var type := MeshNode.Type.REPEATER
		if roll > 0.9:
			type = MeshNode.Type.ROOM_SERVER
		elif roll > 0.55:
			type = MeshNode.Type.COMPANION
		var spread := 0.55 if type == MeshNode.Type.REPEATER else 0.4
		var lat := center.x + rng.randfn(0.0, spread * 0.6)
		var lon := center.y + rng.randfn(0.0, spread)
		var prefix := "RPT" if type == MeshNode.Type.REPEATER else ("ROOM" if type == MeshNode.Type.ROOM_SERVER else "NODE")
		upsert(key.hex_encode(), "%s-%02d" % [prefix, i], lat, lon, type, "synthetic")


func _queue_changed() -> void:
	if _changed_queued:
		return
	_changed_queued = true
	_emit_changed.call_deferred()


func _emit_changed() -> void:
	_changed_queued = false
	nodes_changed.emit()
