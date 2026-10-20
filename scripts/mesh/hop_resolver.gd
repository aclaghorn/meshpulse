class_name HopResolver
extends RefCounted
## Turns a decoded observation into the ordered list of located nodes the packet travelled through.
##
## Path hashes are only 1-3 bytes of a public key, so a hash can match several nodes. Ambiguous hops
## are settled by picking the candidate closest to the already-known neighbours on either side.

## A hop further than this from both of its neighbours is treated as a mis-resolution and dropped.
const MAX_HOP_KM := 250.0


## Returns {nodes: Array[MeshNode], projected: bool}. `projected` marks DIRECT packets, whose path
## lists hops still ahead of the packet rather than hops already crossed.
static func resolve(pkt: Dictionary, registry: Node) -> Dictionary:
	var hops: Array = pkt.get("hops", [])
	var route: int = pkt.get("route", PacketDecoder.Route.FLOOD)
	var is_trace: bool = pkt.get("payload_type", -1) == PacketDecoder.Payload.TRACE
	var projected := false

	var observer_slot := _known(registry.find(str(pkt.get("observer", ""))))
	var origin_slot: Array[MeshNode] = []
	if str(pkt.get("origin_pubkey", "")) != "":
		origin_slot = _known(registry.find(pkt.origin_pubkey))
	elif str(pkt.get("origin_hash", "")) != "":
		origin_slot = _located(registry.candidates(pkt.origin_hash), false)

	var hop_slots: Array = []
	for h in hops:
		hop_slots.append(_located(registry.candidates(h), true))

	var slots: Array = []
	if is_trace:
		var completed: int = clampi(pkt.get("trace_completed", hops.size()), 0, hops.size())
		slots.append_array(hop_slots.slice(0, completed))
		slots.append(observer_slot)
	elif route == PacketDecoder.Route.DIRECT or route == PacketDecoder.Route.TRANSPORT_DIRECT:
		# Each repeater strips itself from a direct path, so what's left is the road ahead.
		projected = true
		slots.append(observer_slot)
		slots.append_array(hop_slots)
	else:
		slots.append(origin_slot)
		slots.append_array(hop_slots)
		slots.append(observer_slot)

	var chosen := _disambiguate(slots)
	return {"nodes": _clean(chosen), "projected": projected}


static func _known(node: MeshNode) -> Array[MeshNode]:
	var out: Array[MeshNode] = []
	if node != null and node.has_location:
		out.append(node)
	return out


## Located candidates, preferring nodes that can actually repeat when asked to.
static func _located(nodes: Array[MeshNode], prefer_repeaters: bool) -> Array[MeshNode]:
	var located: Array[MeshNode] = []
	var repeaters: Array[MeshNode] = []
	for node in nodes:
		if node.has_location:
			located.append(node)
			if node.can_repeat():
				repeaters.append(node)
	if prefer_repeaters and not repeaters.is_empty():
		return repeaters
	return located


## Resolves each slot to one node (or null), fixing unique slots first and then picking the
## closest candidate to the nearest fixed neighbours, left to right.
static func _disambiguate(slots: Array) -> Array:
	var chosen: Array = []
	chosen.resize(slots.size())
	for i in slots.size():
		if slots[i].size() == 1:
			chosen[i] = slots[i][0]
	for i in slots.size():
		var options: Array = slots[i]
		if options.size() < 2:
			continue
		var left: MeshNode = _nearest_fixed(chosen, i, -1)
		var right: MeshNode = _nearest_fixed(chosen, i, 1)
		var best: MeshNode = null
		var best_score := INF
		for node: MeshNode in options:
			var score := 0.0
			if left != null:
				score += _km(node, left)
			if right != null:
				score += _km(node, right)
			if score < best_score:
				best_score = score
				best = node
		chosen[i] = best
	return chosen


static func _nearest_fixed(chosen: Array, from: int, step: int) -> MeshNode:
	var i := from + step
	while i >= 0 and i < chosen.size():
		if chosen[i] != null:
			return chosen[i]
		i += step
	return null


## Drops unresolved slots, repeated nodes and hops that are implausibly far from both neighbours.
static func _clean(chosen: Array) -> Array[MeshNode]:
	var seq: Array[MeshNode] = []
	for node in chosen:
		if node != null and (seq.is_empty() or seq.back() != node):
			seq.append(node)
	if seq.size() < 3:
		return seq
	var out: Array[MeshNode] = [seq[0]]
	for i in range(1, seq.size()):
		var node := seq[i]
		var prev := out.back() as MeshNode
		var next: MeshNode = seq[i + 1] if i + 1 < seq.size() else null
		var far_prev := _km(node, prev) > MAX_HOP_KM
		var far_next := next == null or _km(node, next) > MAX_HOP_KM
		if far_prev and far_next:
			continue
		out.append(node)
	return out


static func _km(a: MeshNode, b: MeshNode) -> float:
	return Geo.distance_km(a.lat, a.lon, b.lat, b.lon)
