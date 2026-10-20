class_name PacketTrail
extends MeshInstance3D
## One packet's flight along a route: a glowing head arcs from node to node, one hop at a time,
## dragging a laser trail and drawing the route line behind it, which lingers and fades out.

signal hop_reached(index: int)

const TRAIL_SECONDS := 0.3
const LINGER_SECONDS := 4.5
const ARC_SAMPLES := 20
const HOP_PAUSE := 0.05
## Ribbon and head sizes as a fraction of the distance to the camera, so they read the same at any zoom.
const TRAIL_WIDTH := 0.0045
const ROUTE_WIDTH := 0.0016
const HEAD_SIZE := 0.024
const ROUTE_ALPHA := 0.4

var color := Color.WHITE
## Projected routes (DIRECT packets) show the road ahead, drawn fainter.
var projected := false

var _points: Array[Vector3] = []
var _seg_start := PackedFloat32Array()
var _seg_dur := PackedFloat32Array()
var _end_time := 0.0
var _clock := 0.0
var _next_arrival := 0
var _history: Array = []  # [Vector3, float clock]
var _im := ImmediateMesh.new()
var _laser_mat: Material
var _head_mat: Material


static func segment_duration(a: Vector3, b: Vector3) -> float:
	return clampf(0.22 + a.distance_to(b) * 0.012, 0.22, 0.9)


static func arc_point(a: Vector3, b: Vector3, f: float) -> Vector3:
	var height := a.distance_to(b) * 0.18 + 0.02
	return a.lerp(b, f) + Vector3.UP * sin(PI * f) * height


func setup(points: Array[Vector3], delay: float, laser_mat: Material, head_mat: Material) -> void:
	_points = points
	_clock = -delay
	_laser_mat = laser_mat
	_head_mat = head_mat
	var t := 0.0
	for i in points.size() - 1:
		var dur := segment_duration(points[i], points[i + 1])
		_seg_start.append(t)
		_seg_dur.append(dur)
		t += dur + HOP_PAUSE
	_end_time = t
	mesh = _im
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _arrival_time(i: int) -> float:
	return 0.0 if i == 0 else _seg_start[i - 1] + _seg_dur[i - 1]


func _process(delta: float) -> void:
	_clock += delta
	if _clock < 0.0:
		return
	while _next_arrival < _points.size() and _clock >= _arrival_time(_next_arrival):
		hop_reached.emit(_next_arrival)
		_next_arrival += 1

	var flying := _clock < _end_time
	var fade := 1.0
	if not flying:
		fade = 1.0 - (_clock - _end_time) / LINGER_SECONDS
		if fade <= 0.0:
			queue_free()
			return

	var seg := _current_segment()
	var f := _segment_progress(seg)
	var head := arc_point(_points[seg], _points[seg + 1], f)
	if flying:
		_history.append([head, _clock])
	while not _history.is_empty() and _clock - _history[0][1] > TRAIL_SECONDS:
		_history.pop_front()
	_draw(seg, f, head, flying, fade)


func _current_segment() -> int:
	for i in _seg_start.size():
		if _clock < _seg_start[i] + _seg_dur[i] + HOP_PAUSE:
			return i
	return _seg_start.size() - 1


## Eased 0..1 progress along a segment; holds at 1 during the pause at the next hop.
func _segment_progress(seg: int) -> float:
	var f := clampf((_clock - _seg_start[seg]) / _seg_dur[seg], 0.0, 1.0)
	return lerpf(f, f * f * (3.0 - 2.0 * f), 0.6)


func _draw(seg: int, f: float, head: Vector3, flying: bool, fade: float) -> void:
	_im.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var route_color := color.lerp(Color.WHITE, 0.25 if projected else 0.0)

	# Route line: every finished segment plus the part of the current one already flown.
	var line := PackedVector3Array()
	for i in seg + 1:
		var end_f := 1.0 if i < seg else f
		var samples := maxi(2, int(ARC_SAMPLES * end_f))
		for s in samples + 1:
			if i > 0 and s == 0:
				continue
			line.append(arc_point(_points[i], _points[i + 1], end_f * s / samples))
	var route_alpha := ROUTE_ALPHA * fade * (0.55 if projected else 1.0)
	var alphas := PackedFloat32Array()
	alphas.resize(line.size())
	alphas.fill(route_alpha)

	var trail := PackedVector3Array()
	var trail_alpha := PackedFloat32Array()
	for h in _history:
		trail.append(h[0])
		trail_alpha.append(pow(1.0 - (_clock - h[1]) / TRAIL_SECONDS, 1.5))

	var has_route := line.size() >= 2 and route_alpha > 0.0
	var has_trail := trail.size() >= 2
	if has_route or has_trail:
		_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _laser_mat)
		if has_route:
			_ribbon(line, alphas, ROUTE_WIDTH, route_color, cam_pos)
		if has_trail:
			_ribbon(trail, trail_alpha, TRAIL_WIDTH, color, cam_pos)
		_im.surface_end()

	if flying:
		_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _head_mat)
		var size := cam_pos.distance_to(head) * HEAD_SIZE
		var right := cam.global_basis.x * size * 0.5
		var up := cam.global_basis.y * size * 0.5
		_quad(head - right - up, head + right - up, head + right + up, head - right + up, Color(color, 1.0))
		_im.surface_end()


## Camera-facing triangle ribbon along a polyline; width scales with distance to the camera.
func _ribbon(pts: PackedVector3Array, alpha: PackedFloat32Array, width: float, col: Color, cam_pos: Vector3) -> void:
	var n := pts.size()
	var sides := PackedVector3Array()
	sides.resize(n)
	for i in n:
		var tangent := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		var side := tangent.cross(cam_pos - pts[i])
		if side.length_squared() < 1e-12:
			side = Vector3.RIGHT
		var w := cam_pos.distance_to(pts[i]) * width * (0.35 + 0.65 * alpha[i])
		sides[i] = side.normalized() * w * 0.5
	for i in n - 1:
		var c0 := Color(col, alpha[i])
		var c1 := Color(col, alpha[i + 1])
		var a0 := pts[i] - sides[i]
		var b0 := pts[i] + sides[i]
		var a1 := pts[i + 1] - sides[i + 1]
		var b1 := pts[i + 1] + sides[i + 1]
		_vertex(a0, Vector2(0, 0), c0)
		_vertex(b0, Vector2(0, 1), c0)
		_vertex(b1, Vector2(1, 1), c1)
		_vertex(a0, Vector2(0, 0), c0)
		_vertex(b1, Vector2(1, 1), c1)
		_vertex(a1, Vector2(1, 0), c1)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_vertex(a, Vector2(0, 1), col)
	_vertex(b, Vector2(1, 1), col)
	_vertex(c, Vector2(1, 0), col)
	_vertex(a, Vector2(0, 1), col)
	_vertex(c, Vector2(1, 0), col)
	_vertex(d, Vector2(0, 0), col)


func _vertex(p: Vector3, uv: Vector2, col: Color) -> void:
	_im.surface_set_color(col)
	_im.surface_set_uv(uv)
	_im.surface_add_vertex(p)
