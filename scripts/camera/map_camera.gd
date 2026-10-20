class_name MapCamera
extends Camera3D
## Map-style orbit camera around a ground target. Top-down by default; tilts into a 3D view as you
## zoom in close (or on demand), like Google Maps.
##
## Left-drag pans (the ground point under the cursor stays put), wheel/pinch zooms toward the cursor,
## right/middle-drag or shift+left-drag orbits, V toggles 3D, R resets north-up.
## Touch: one finger pans (via Godot's mouse emulation), pinch zooms, twist rotates and a two-finger
## vertical drag tilts.

signal clicked(screen_pos: Vector2)
signal double_clicked(screen_pos: Vector2)
signal hovered(screen_pos: Vector2)
signal view_mode_changed(is_3d: bool)

const TOPDOWN_PITCH := -89.5
const TILTED_PITCH := -48.0
const MIN_PITCH := -89.5
const MAX_PITCH := -12.0
## Zooming below these distances (km) eases the camera from top-down to tilted.
const AUTO_TILT_START_KM := 30.0
const AUTO_TILT_FULL_KM := 3.0
const CLICK_SLOP_PX := 5.0

@export var min_distance := 0.25
@export var max_distance := 6000.0
@export var smoothing := 12.0

var target := Vector3.ZERO
var distance := 80.0
var yaw := 0.0
var pitch := TOPDOWN_PITCH
## True once the user orbits or asks for 3D; auto-tilt stops overriding pitch.
var free_3d := false

var _goal_target := Vector3.ZERO
var _goal_distance := 80.0
var _goal_yaw := 0.0
var _goal_pitch := TOPDOWN_PITCH
var _panning := false
var _orbiting := false
var _pan_plane_y := 0.0
var _pan_anchor := Vector3.ZERO
var _press_pos := Vector2.ZERO
var _dragged := false
var _touches := {}  # finger index -> screen position
var _touch_motion := {}  # finger index -> last drag delta


func _ready() -> void:
	fov = 50.0
	_apply()


func is_3d() -> bool:
	return pitch > -80.0


## Frames the given world points from top-down, ignoring the outer 5% on each axis so a few
## far-flung nodes don't zoom the view out to a whole continent.
func frame_points(points: Array[Vector3]) -> void:
	if points.is_empty():
		jump_to(Vector3.ZERO, 120.0)
		return
	var xs: Array[float] = []
	var zs: Array[float] = []
	for p in points:
		xs.append(p.x)
		zs.append(p.z)
	xs.sort()
	zs.sort()
	var lo := int(points.size() * 0.05)
	var hi := points.size() - 1 - lo
	var center := Vector3((xs[lo] + xs[hi]) * 0.5, 0.0, (zs[lo] + zs[hi]) * 0.5)
	var span := maxf(xs[hi] - xs[lo], zs[hi] - zs[lo])
	jump_to(center, clampf(span * 1.1, 5.0, max_distance))


func jump_to(point: Vector3, dist: float) -> void:
	target = point
	_goal_target = point
	distance = dist
	_goal_distance = dist
	_apply()


## Glides to a point and tilts into 3D, used when focusing a node.
func fly_to(point: Vector3, dist := 4.0) -> void:
	_goal_target = point
	_goal_distance = clampf(dist, min_distance, max_distance)
	set_3d(true)


func set_3d(enabled: bool) -> void:
	free_3d = enabled
	_goal_pitch = TILTED_PITCH if enabled else TOPDOWN_PITCH
	if not enabled:
		_goal_yaw = _north_yaw()
	view_mode_changed.emit(enabled)


func _process(delta: float) -> void:
	if not free_3d:
		var t := inverse_lerp(log(AUTO_TILT_START_KM), log(AUTO_TILT_FULL_KM), log(_goal_distance))
		_goal_pitch = lerpf(TOPDOWN_PITCH, TILTED_PITCH, smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0)))
	var k := 1.0 - exp(-delta * smoothing)
	if not _panning:
		target = target.lerp(_goal_target, k)
	distance = exp(lerpf(log(distance), log(_goal_distance), k))
	# Plain lerp: yaw is unbounded degrees (lerp_angle wants radians and would wrap the wrong way).
	yaw = lerpf(yaw, _goal_yaw, k)
	pitch = lerpf(pitch, _goal_pitch, k)
	_follow_ground(delta)
	_apply()


## Keeps the orbit target on the terrain surface so 3D views pivot around the ground, not sea level.
func _follow_ground(delta: float) -> void:
	var latlon := Geo.world_to_latlon(_goal_target)
	var elev := Tiles.sample_elevation_km(latlon.x, latlon.y, distance < 40.0)
	if is_nan(elev):
		return
	var y := elev * Geo.vertical_scale
	var k := 1.0 - exp(-delta * 4.0)
	_goal_target.y = lerpf(_goal_target.y, y, k)
	if not _panning:
		target.y = lerpf(target.y, y, k)


func _apply() -> void:
	var rot := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(pitch))
	transform = Transform3D(rot, target + rot * Vector3(0.0, 0.0, distance))
	near = clampf(distance * 0.002, 0.002, 5.0)
	far = clampf(distance * 80.0 + 200.0, 500.0, 60000.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventPanGesture:
		# Two-finger trackpad scroll on macOS.
		_zoom_at(event.position, pow(1.04, event.delta.y))
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_touch_drag(event)
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, 1.0 / event.factor)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_V:
				set_3d(not free_3d and not is_3d())
			KEY_R:
				_goal_yaw = _north_yaw()
			KEY_EQUAL, KEY_KP_ADD:
				_goal_distance = clampf(_goal_distance * 0.7, min_distance, max_distance)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_goal_distance = clampf(_goal_distance / 0.7, min_distance, max_distance)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.double_click:
				double_clicked.emit(event.position)
				get_viewport().set_input_as_handled()
				return
			# Shift+left-drag orbits like the middle button, for trackpads and one-button mice.
			if event.pressed and event.shift_pressed:
				_orbiting = true
				get_viewport().set_input_as_handled()
				return
			if not event.pressed and _orbiting and not _panning:
				_orbiting = false
				get_viewport().set_input_as_handled()
				return
			if event.pressed:
				_panning = true
				_dragged = false
				_press_pos = event.position
				_pan_plane_y = target.y
				_goal_target = target
				var hit = _ground_point(event.position, _pan_plane_y)
				_panning = hit != null
				if hit != null:
					_pan_anchor = hit
			else:
				if _panning and not _dragged:
					clicked.emit(event.position)
				_panning = false
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
			_orbiting = event.pressed
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_at(event.position, 0.85)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_at(event.position, 1.0 / 0.85)
			get_viewport().set_input_as_handled()


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		if event.position.distance_to(_press_pos) > CLICK_SLOP_PX:
			_dragged = true
		var hit = _ground_point(event.position, _pan_plane_y)
		if hit != null:
			target += _pan_anchor - hit
			_goal_target = target
			_apply()
		get_viewport().set_input_as_handled()
	elif _orbiting:
		_goal_yaw -= event.relative.x * 0.3
		_goal_pitch = clampf(_goal_pitch - event.relative.y * 0.25, MIN_PITCH, MAX_PITCH)
		_enter_free_3d()
		get_viewport().set_input_as_handled()
	else:
		hovered.emit(event.position)


## The north-up yaw nearest the current heading, so resetting never spins through extra turns.
func _north_yaw() -> float:
	return yaw - wrapf(yaw, -180.0, 180.0)


func _enter_free_3d() -> void:
	if not free_3d:
		free_3d = true
		view_mode_changed.emit(true)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
	else:
		_touches.erase(event.index)
	_touch_motion.clear()
	if _touches.size() >= 2:
		# The first finger also drives the emulated mouse; stop it panning, and lifting it later
		# shouldn't count as a tap.
		_panning = false
		_dragged = true


## With two fingers down: both moving vertically together tilts; otherwise pinch zooms around the
## midpoint and twisting rotates.
func _on_touch_drag(event: InputEventScreenDrag) -> void:
	if _touches.size() < 2 or not _touches.has(event.index):
		_touches[event.index] = event.position
		return
	var other_index: int = _touches.keys().filter(func(i: int) -> bool: return i != event.index)[0]
	var other: Vector2 = _touches[other_index]
	var before: Vector2 = _touches[event.index]
	var after := event.position
	_touches[event.index] = after
	_touch_motion[event.index] = event.relative
	var other_motion: Vector2 = _touch_motion.get(other_index, Vector2.ZERO)
	if _is_tilt_gesture(event.relative, other_motion):
		# Each finger reports its own drag, so each contributes half the tilt.
		_goal_pitch = clampf(_goal_pitch - event.relative.y * 0.15, MIN_PITCH, MAX_PITCH)
		_enter_free_3d()
	else:
		var d0 := before.distance_to(other)
		var d1 := after.distance_to(other)
		if d0 > 1.0 and d1 > 1.0:
			_zoom_at((after + other) * 0.5, d0 / d1)
		var twist := wrapf((after - other).angle() - (before - other).angle(), -PI, PI)
		_goal_yaw += rad_to_deg(twist)
	get_viewport().set_input_as_handled()


static func _is_tilt_gesture(a: Vector2, b: Vector2) -> bool:
	var vertical := func(v: Vector2) -> bool: return absf(v.y) > 0.5 and absf(v.y) > absf(v.x) * 1.5
	return vertical.call(a) and vertical.call(b) and signf(a.y) == signf(b.y)


## Zooms by `factor` (<1 = in) keeping the ground point under the cursor roughly fixed.
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var new_distance := clampf(_goal_distance * factor, min_distance, max_distance)
	var applied := new_distance / _goal_distance
	var hit = _ground_point(screen_pos, _goal_target.y)
	if hit != null:
		_goal_target += (hit - _goal_target) * (1.0 - applied) * Vector3(1, 0, 1)
	_goal_distance = new_distance


func _ground_point(screen_pos: Vector2, plane_y: float):
	var origin := project_ray_origin(screen_pos)
	var dir := project_ray_normal(screen_pos)
	return Plane(Vector3.UP, plane_y).intersects_ray(origin, dir)
