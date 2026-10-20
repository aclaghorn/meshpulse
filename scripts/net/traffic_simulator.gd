class_name TrafficSimulator
extends Node
## Demo-mode traffic: builds real MeshCore raw packets along plausible repeater chains and emits them
## in the same JSON shape meshcore-packet-capture publishes, so they run through the normal decoder.

signal message(topic: String, data: Dictionary)

@export var packets_per_second := 1.4
@export var neighbour_km := 45.0

var _rng := RandomNumberGenerator.new()
var _repeaters: Array[MeshNode] = []
var _all: Array[MeshNode] = []
var _neighbours := {}  # pubkey -> Array[MeshNode] (nearest repeaters)
var _timer := 0.0


func _ready() -> void:
	_rng.randomize()
	_rebuild()
	MeshData.nodes_changed.connect(_rebuild)


func _rebuild() -> void:
	_all = MeshData.located_nodes()
	_repeaters = _all.filter(func(n: MeshNode) -> bool: return n.can_repeat())
	_neighbours.clear()


func _process(delta: float) -> void:
	if _repeaters.size() < 2:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = -log(maxf(_rng.randf(), 0.001)) / packets_per_second
	_emit_packet()


func _emit_packet() -> void:
	var chain := _walk(_repeaters[_rng.randi() % _repeaters.size()], _rng.randi_range(1, 6))
	var origin := _nearest(chain[0], _all, chain)
	if origin == null:
		origin = chain[0]
	var observer := _nearest(chain.back(), _all, chain + [origin])
	var roll := _rng.randf()
	var raw := ""
	if roll < 0.25:
		raw = _build_advert(origin, chain)
	elif roll < 0.55:
		raw = _build(PacketDecoder.Payload.GRP_TXT, chain, _random_bytes(_rng.randi_range(20, 60)))
	elif roll < 0.7:
		raw = _build(PacketDecoder.Payload.TXT_MSG, chain, _with_src(origin, 30))
	elif roll < 0.8:
		raw = _build_trace(chain)
	elif roll < 0.9:
		raw = _build(PacketDecoder.Payload.ACK, chain, _random_bytes(4))
	else:
		raw = _build(PacketDecoder.Payload.PATH, chain, _with_src(origin, 20))
	_publish(observer, raw)

	# Often a second observer hears the same packet after it forks down another branch.
	if _rng.randf() < 0.45 and chain.size() >= 2:
		var fork_at := _rng.randi_range(0, chain.size() - 1)
		var branch := chain.slice(0, fork_at + 1)
		branch.append_array(_walk(branch.back(), _rng.randi_range(1, 3), branch).slice(1))
		var other := _nearest(branch.back(), _all, branch + [observer])
		if other != null and raw != "":
			_publish.call_deferred(other, _replace_path(raw, branch))


func _publish(observer: MeshNode, raw: String) -> void:
	if observer == null or raw == "":
		return
	message.emit("meshcore/SIM/%s/packets" % observer.pubkey.to_upper(), {
		"origin": observer.display_name(),
		"origin_id": observer.pubkey.to_upper(),
		"type": "PACKET",
		"direction": "rx",
		"raw": raw,
		"SNR": "%.1f" % _rng.randf_range(-12.0, 12.0),
		"RSSI": str(_rng.randi_range(-120, -60)),
	})


## A random walk across nearby repeaters, never revisiting a node.
func _walk(start: MeshNode, hops: int, avoid: Array = []) -> Array:
	var chain: Array = [start]
	var current := start
	for i in hops - 1:
		var options: Array = _neighbours_of(current).filter(func(n): return not chain.has(n) and not avoid.has(n))
		if options.is_empty():
			break
		current = options[_rng.randi() % mini(options.size(), 4)]
		chain.append(current)
	return chain


func _neighbours_of(node: MeshNode) -> Array:
	if _neighbours.has(node.pubkey):
		return _neighbours[node.pubkey]
	var near: Array = _repeaters.filter(func(n: MeshNode) -> bool:
		return n != node and Geo.distance_km(n.lat, n.lon, node.lat, node.lon) < neighbour_km)
	near.sort_custom(func(a: MeshNode, b: MeshNode) -> bool:
		return Geo.distance_km(a.lat, a.lon, node.lat, node.lon) < Geo.distance_km(b.lat, b.lon, node.lat, node.lon))
	near = near.slice(0, 8)
	_neighbours[node.pubkey] = near
	return near


func _nearest(to: MeshNode, pool: Array[MeshNode], exclude: Array) -> MeshNode:
	var best: MeshNode = null
	var best_d := INF
	for n in pool:
		if exclude.has(n):
			continue
		var d := Geo.distance_km(n.lat, n.lon, to.lat, to.lon) + _rng.randf() * 8.0
		if d < best_d:
			best_d = d
			best = n
	return best


func _build(payload_type: int, chain: Array, payload: PackedByteArray, route := PacketDecoder.Route.FLOOD) -> String:
	var bytes := PackedByteArray([(payload_type << 2) | route, chain.size()])
	for node: MeshNode in chain:
		bytes.append(node.pubkey.substr(0, 2).hex_to_int())
	bytes.append_array(payload)
	return bytes.hex_encode().to_upper()


func _build_advert(origin: MeshNode, chain: Array) -> String:
	var payload := origin.pubkey.hex_decode()
	payload.append_array(_random_bytes(4 + 64))  # timestamp + signature
	payload.append(origin.type | PacketDecoder.ADVERT_HAS_LOCATION | PacketDecoder.ADVERT_HAS_NAME)
	var loc := PackedByteArray()
	loc.resize(8)
	loc.encode_s32(0, int(origin.lat * 1e6))
	loc.encode_s32(4, int(origin.lon * 1e6))
	payload.append_array(loc)
	payload.append_array(origin.name.to_utf8_buffer())
	return _build(PacketDecoder.Payload.ADVERT, chain, payload)


## TRACE: the route goes in the payload; the header path carries one SNR byte per hop crossed.
func _build_trace(chain: Array) -> String:
	var bytes := PackedByteArray([(PacketDecoder.Payload.TRACE << 2) | PacketDecoder.Route.DIRECT, chain.size()])
	for i in chain.size():
		bytes.append(_rng.randi_range(0, 60))
	bytes.append_array(_random_bytes(8))  # tag + auth code
	bytes.append(0)  # flags: 1-byte hashes
	for node: MeshNode in chain:
		bytes.append(node.pubkey.substr(0, 2).hex_to_int())
	return bytes.hex_encode().to_upper()


## Same packet, different path: rewrites the path bytes of a flood packet.
func _replace_path(raw: String, chain: Array) -> String:
	var bytes := raw.hex_decode()
	if (bytes[0] & 0x03) != PacketDecoder.Route.FLOOD:
		return ""
	var old_len := bytes[1] & 0x3F
	var out := PackedByteArray([bytes[0], chain.size()])
	for node: MeshNode in chain:
		out.append(node.pubkey.substr(0, 2).hex_to_int())
	out.append_array(bytes.slice(2 + old_len))
	return out.hex_encode().to_upper()


func _with_src(origin: MeshNode, extra: int) -> PackedByteArray:
	var payload := PackedByteArray([_rng.randi_range(0, 255), origin.pubkey.substr(0, 2).hex_to_int()])
	payload.append_array(_random_bytes(extra))
	return payload


func _random_bytes(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	for i in n:
		out.append(_rng.randi_range(0, 255))
	return out
