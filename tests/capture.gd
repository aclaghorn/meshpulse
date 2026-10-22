extends SceneTree
## Dev helper: runs the app windowed with the configured sources and saves screenshots of the loading
## overlay, the top-down map and a 3D close-up. Also checks screen picking round-trips on this display.
## With --regions it shoots the region picker instead, at desktop and phone sizes (nothing is saved).
##   godot --path . -s tests/capture.gd -- --out=/some/dir [--regions]

var _out := "user://captures"
var _t := 0.0
var _step := 0
var _regions := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	_regions = "--regions" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(_out)
	change_scene_to_file("res://scenes/region_screen.tscn" if _regions else "res://scenes/main.tscn")


func _process(delta: float) -> bool:
	_t += delta
	if _regions:
		return _process_regions()
	match _step:
		0:
			if _t > 0.5:
				_shot("1_loading")
				_step = 1
		1:
			if _t > 14.0:
				_shot("2_topdown")
				_check_picking()
				var main := current_scene
				var busiest: MeshNode = null
				for n: MeshNode in root.get_node("MeshData").located_nodes():
					if n.can_repeat() and (busiest == null or n.world.distance_to(Vector3.ZERO) < busiest.world.distance_to(Vector3.ZERO)):
						busiest = n
				main.markers.set_selected(busiest)
				main.hud.show_node(busiest, 0)
				main.camera.fly_to(busiest.world, 14.0)
				_step = 2
		2:
			if _t > 26.0:
				_shot("3_3d")
				_step = 3
		3:
			return true
	return false


func _process_regions() -> bool:
	match _step:
		0:
			if _t > 1.0:
				# Tick two regions the way a click on the list or map would.
				for code in ["SEA", "PDX"]:
					current_scene._toggle(code, true)
				current_scene._map.focus("SEA")
				_step = 1
		1:
			if _t > 9.0:
				_shot("regions_desktop")
				DisplayServer.window_set_size(Vector2i(400, 860))
				_step = 2
		2:
			if _t > 14.0:
				_shot("regions_phone")
				_step = 3
		3:
			return true
	return false


func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	img.save_png(path)
	print("saved ", path, " ", img.get_size())


func _check_picking() -> void:
	var main := current_scene
	var cam: Camera3D = main.camera
	var nodes: Array[MeshNode] = root.get_node("MeshData").located_nodes()
	var n: MeshNode = nodes[nodes.size() / 2]
	var screen := cam.unproject_position(n.world)
	var hit = Plane(Vector3.UP, n.world.y).intersects_ray(cam.project_ray_origin(screen), cam.project_ray_normal(screen))
	print("content_scale=", root.content_scale_factor, " window=", root.size, " visible_rect=", root.get_visible_rect().size)
	print("pick round-trip error (km): ", (hit - n.world).length() if hit != null else -1.0, " picked=", main.markers.pick(screen) == n)
