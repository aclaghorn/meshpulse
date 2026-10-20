class_name PacketDecoder
extends RefCounted
## Decodes a raw MeshCore packet (hex) into its header fields, hop path and origin hints.
##
## Layout (MeshCore Packet.cpp):
##   header(1) [transport codes(4) for TRANSPORT_* routes] path_len(1) path(n) payload(...)
##   header: bits 0-1 route type, bits 2-5 payload type, bits 6-7 payload version
##   path_len: low 6 bits hop count, high 2 bits (bytes per hop - 1)

enum Route { TRANSPORT_FLOOD, FLOOD, DIRECT, TRANSPORT_DIRECT }
enum Payload { REQ, RESPONSE, TXT_MSG, ACK, ADVERT, GRP_TXT, GRP_DATA, ANON_REQ, PATH, TRACE, MULTIPART, CONTROL, RESERVED_12, RESERVED_13, RESERVED_14, RAW_CUSTOM }

const ROUTE_NAMES := ["TRANSPORT_FLOOD", "FLOOD", "DIRECT", "TRANSPORT_DIRECT"]
const PAYLOAD_NAMES := ["REQ", "RESPONSE", "TXT_MSG", "ACK", "ADVERT", "GRP_TXT", "GRP_DATA", "ANON_REQ", "PATH", "TRACE", "MULTIPART", "CONTROL", "TYPE_12", "TYPE_13", "TYPE_14", "RAW_CUSTOM"]

const ADVERT_HAS_LOCATION := 0x10
const ADVERT_HAS_FEAT1 := 0x20
const ADVERT_HAS_FEAT2 := 0x40
const ADVERT_HAS_NAME := 0x80


## Returns {} when the packet is malformed or uses an unknown payload version. Otherwise:
##   route, route_name, payload_type, type_name, hash_size,
##   hops: Array[String] of uppercase hex path hashes in travel order,
##   trace_completed: for TRACE, how many of `hops` the packet has already crossed (else -1),
##   origin_pubkey: full sender key when the payload carries it (ADVERT, ANON_REQ),
##   origin_hash: 1-byte sender hash for REQ/RESPONSE/TXT_MSG/PATH,
##   advert: {name, lat, lon, node_type} for ADVERT,
##   content_hash: 16 hex chars identifying the packet across observers.
static func decode(raw_hex: String) -> Dictionary:
	var bytes := raw_hex.strip_edges().hex_decode()
	if bytes.size() < 2:
		return {}
	var header := bytes[0]
	var route := header & 0x03
	var payload_type := (header >> 2) & 0x0F
	if (header >> 6) & 0x03 != 0:
		return {}

	var offset := 1
	if route == Route.TRANSPORT_FLOOD or route == Route.TRANSPORT_DIRECT:
		offset += 4
	if bytes.size() <= offset:
		return {}
	var path_len_byte := bytes[offset]
	offset += 1
	var hop_count := path_len_byte & 0x3F
	var hash_size := (path_len_byte >> 6) + 1
	if hash_size == 4:
		# Reserved mode in firmware; fall back to the legacy one-byte-per-hop reading.
		hash_size = 1
		hop_count = path_len_byte
	var path_bytes_len := hop_count * hash_size
	if bytes.size() < offset + path_bytes_len:
		return {}
	var path_bytes := bytes.slice(offset, offset + path_bytes_len)
	offset += path_bytes_len
	var payload := bytes.slice(offset)

	var result := {
		"route": route,
		"route_name": ROUTE_NAMES[route],
		"payload_type": payload_type,
		"type_name": PAYLOAD_NAMES[payload_type],
		"hash_size": hash_size,
		"hops": [],
		"trace_completed": -1,
		"origin_pubkey": "",
		"origin_hash": "",
		"content_hash": _content_hash(payload_type, payload),
	}

	if payload_type == Payload.TRACE:
		# For TRACE the header path holds one SNR byte per hop crossed so far;
		# the intended route lives in the payload: tag(4) auth(4) flags(1) hashes...
		if payload.size() >= 9:
			var trace_hash_size := 1 << (payload[8] & 0x03)
			result.hash_size = trace_hash_size
			result.hops = _split_hops(payload.slice(9), trace_hash_size)
		result.trace_completed = hop_count
	else:
		result.hops = _split_hops(path_bytes, hash_size)

	match payload_type:
		Payload.ADVERT:
			if payload.size() >= 32:
				result.origin_pubkey = payload.slice(0, 32).hex_encode()
				result.advert = _parse_advert_appdata(payload)
		Payload.ANON_REQ:
			# dest_hash(1) sender_pubkey(32) ...
			if payload.size() >= 33:
				result.origin_pubkey = payload.slice(1, 33).hex_encode()
		Payload.REQ, Payload.RESPONSE, Payload.TXT_MSG, Payload.PATH:
			# dest_hash(1) src_hash(1) ...
			if payload.size() >= 2:
				result.origin_hash = "%02X" % payload[1]
	return result


static func _split_hops(bytes: PackedByteArray, size: int) -> Array[String]:
	var hops: Array[String] = []
	var i := 0
	while i + size <= bytes.size():
		hops.append(bytes.slice(i, i + size).hex_encode().to_upper())
		i += size
	return hops


## ADVERT payload: pubkey(32) timestamp(4) signature(64) flags(1) [lat(4) lon(4)] [feat1(2)] [feat2(2)] [name]
static func _parse_advert_appdata(payload: PackedByteArray) -> Dictionary:
	var out := {"name": "", "lat": 0.0, "lon": 0.0, "node_type": 0, "has_location": false}
	var pos := 100
	if payload.size() <= pos:
		return out
	var flags := payload[pos]
	pos += 1
	out.node_type = flags & 0x0F
	if flags & ADVERT_HAS_LOCATION:
		if payload.size() < pos + 8:
			return out
		out.lat = payload.decode_s32(pos) / 1e6
		out.lon = payload.decode_s32(pos + 4) / 1e6
		out.has_location = true
		pos += 8
	if flags & ADVERT_HAS_FEAT1:
		pos += 2
	if flags & ADVERT_HAS_FEAT2:
		pos += 2
	if flags & ADVERT_HAS_NAME and payload.size() > pos:
		out.name = payload.slice(pos).get_string_from_utf8().strip_edges()
	return out


## Stable id for one packet regardless of which observer heard it or how far it travelled.
static func _content_hash(payload_type: int, payload: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(PackedByteArray([payload_type]))
	ctx.update(payload)
	return ctx.finish().slice(0, 8).hex_encode()
