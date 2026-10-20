class_name PacketAnimator
extends Node3D
## Launches a PacketTrail per observation and draws the pulse rings where packets land.
##
## The same packet is usually heard by several observers. Their routes share a prefix, so a later
## observation only animates from the point where its route branches off, timed to leave that node
## when the first flight passed through it.

signal hop_reached(node: MeshNode, color: Color)

const MAX_ACTIVE := 200
const FLIGHT_MEMORY_MS := 45000
const PULSE_SECONDS := 0.65
const PULSE_SIZE := 0.07

@export var markers: NodeMarkers

var active_count := 0
var dropped_count := 0

var _laser_mat := ShaderMaterial.new()
var _head_mat := ShaderMaterial.new()
var _ring_mat := ShaderMaterial.new()
var _flights := {}  # packet hash -> {start, seen, arrivals: {pubkey: seconds}, edges: {key: true}}
var _pulses: Array = []  # [Vector3, Color, age]
var _pulse_mesh := ImmediateMesh.new()
var _cleanup_timer := 5.0


func _ready() -> void:
	_laser_mat.shader = preload("res://shaders/laser.gdshader")
	var glow: Shader = preload("res://shaders/glow_sprite.gdshader")
	_head_mat.shader = glow
	_ring_mat.shader = glow
	_ring_mat.set_shader_parameter("ring", true)
	_ring_mat.set_shader_parameter("energy", 2.5)
	var pulses := MeshInstance3D.new()
	pulses.mesh = _pulse_mesh
	pulses.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pulses)


func launch(pkt: Dictionary, nodes: Array[MeshNode], projected: bool) -> void:
	if nodes.is_empty():
		return
	var color := PacketStyle.color_for(pkt.payload_type)
	if nodes.size() == 1:
		_on_hop(nodes[0], markers.world_of(nodes[0]), color)
		return
	if active_count >= MAX_ACTIVE:
		dropped_count += 1
		return

	var now := Time.get_ticks_msec() / 1000.0
	var key: String = pkt.get("hash", "")
	var flight: Dictionary = _flights.get(key, {})
	var first := 0
	var delay := 0.0
	if flight.is_empty():
		flight = {"start": now, "arrivals": {nodes[0].pubkey: 0.0}, "edges": {}}
		if key != "":
			_flights[key] = flight
	else:
		while first + 1 < nodes.size() and flight.edges.has(_edge(nodes[first], nodes[first + 1])):
			first += 1
		if first == nodes.size() - 1:
			return  # every hop of this route is already on screen
		var offset: float = flight.arrivals.get(nodes[first].pubkey, now - flight.start)
		delay = maxf(0.0, flight.start + offset - now)
	flight.seen = Time.get_ticks_msec()

	var route := nodes.slice(first)
	var points: Array[Vector3] = []
	for node in route:
		points.append(markers.world_of(node))
	var t: float = now + delay - flight.start
	for i in route.size() - 1:
		flight.edges[_edge(route[i], route[i + 1])] = true
		t += PacketTrail.segment_duration(points[i], points[i + 1])
		if not flight.arrivals.has(route[i + 1].pubkey):
			flight.arrivals[route[i + 1].pubkey] = t
		t += PacketTrail.HOP_PAUSE

	var trail := PacketTrail.new()
	trail.color = color
	trail.projected = projected
	add_child(trail)
	trail.setup(points, delay, _laser_mat, _head_mat)
	var branch := first > 0
	trail.hop_reached.connect(func(i: int) -> void:
		if not (branch and i == 0):
			_on_hop(route[i], points[i], color))
	trail.tree_exited.connect(func() -> void: active_count -= 1)
	active_count += 1


func _on_hop(node: MeshNode, point: Vector3, color: Color) -> void:
	markers.flash(node, color)
	_pulses.append([point, color, 0.0])
	hop_reached.emit(node, color)


static func _edge(a: MeshNode, b: MeshNode) -> String:
	return a.pubkey + ">" + b.pubkey


func _process(delta: float) -> void:
	_cleanup_timer -= delta
	if _cleanup_timer <= 0.0:
		_cleanup_timer = 5.0
		var cutoff := Time.get_ticks_msec() - FLIGHT_MEMORY_MS
		for key in _flights.keys():
			if _flights[key].seen < cutoff:
				_flights.erase(key)
	_draw_pulses(delta)


func _draw_pulses(delta: float) -> void:
	_pulse_mesh.clear_surfaces()
	for p in _pulses:
		p[2] += delta
	_pulses = _pulses.filter(func(p: Array) -> bool: return p[2] < PULSE_SECONDS)
	var cam := get_viewport().get_camera_3d()
	if _pulses.is_empty() or cam == null:
		return
	var right_axis := cam.global_basis.x
	var up_axis := cam.global_basis.y
	_pulse_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _ring_mat)
	for p in _pulses:
		var t: float = p[2] / PULSE_SECONDS
		var pos: Vector3 = p[0]
		var size := cam.global_position.distance_to(pos) * PULSE_SIZE * (0.2 + 0.8 * sqrt(t))
		var r := right_axis * size * 0.5
		var u := up_axis * size * 0.5
		var col := Color(p[1], (1.0 - t) * (1.0 - t))
		for v in [[-r - u, Vector2(0, 1)], [r - u, Vector2(1, 1)], [r + u, Vector2(1, 0)], [-r - u, Vector2(0, 1)], [r + u, Vector2(1, 0)], [-r + u, Vector2(0, 0)]]:
			_pulse_mesh.surface_set_color(col)
			_pulse_mesh.surface_set_uv(v[1])
			_pulse_mesh.surface_add_vertex(pos + v[0])
	_pulse_mesh.surface_end()
