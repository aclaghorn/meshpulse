extends Node3D
## The live map and the app's entry point. Loads nodes from the configured sources behind a loading
## overlay (first launch, or after the sources changed), then wires the packet feed through hop
## resolution into the animator. Command-line user arg (after `--`): --demo.

@onready var camera: MapCamera = $MapCamera
@onready var terrain: Node3D = $TerrainMap
@onready var markers: NodeMarkers = $NodeMarkers
@onready var animator: PacketAnimator = $PacketAnimator
@onready var feed: PacketFeed = $PacketFeed
@onready var hud: CanvasLayer = $HUD
@onready var world_env: WorldEnvironment = $WorldEnvironment

var _relay_counts := {}  # pubkey -> packets relayed this session
var _stats_timer := 0.0


func _ready() -> void:
	if "--demo" in OS.get_cmdline_user_args():
		AppConfig.demo_mode = true
	world_env.environment = _build_environment()
	_connect_signals()
	if not MeshData.loaded:
		# Nothing on the map can be placed until the nodes (and so the world origin) are known.
		_set_map_running(false)
		hud.show_loading("Loading nodes…")
		var loader := SourceLoader.new()
		add_child(loader)
		loader.status.connect(hud.show_loading)
		var warnings: Array[String] = await loader.load_nodes()
		loader.queue_free()
		for w in warnings:
			hud.add_source_note("● " + w, UiTheme.BAD)
		hud.hide_loading()
	_start_map()


func _set_map_running(running: bool) -> void:
	for node: Node in [camera, terrain, markers, animator, feed]:
		node.process_mode = Node.PROCESS_MODE_INHERIT if running else Node.PROCESS_MODE_DISABLED


func _start_map() -> void:
	Geo.vertical_scale = AppConfig.vertical_exaggeration
	markers.rebuild()
	var points: Array[Vector3] = []
	for node in MeshData.located_nodes():
		points.append(Geo.latlon_to_world(node.lat, node.lon))
	camera.frame_points(points)
	var beacons := AppConfig.beacons.filter(func(b: Dictionary) -> bool: return b.get("enabled", true))
	if not AppConfig.has_regions():
		hud.add_source_note("● No regions selected", UiTheme.WARN)
		if not AppConfig.demo_mode:
			hud.show_region_prompt()
	elif not beacons.is_empty():
		hud.add_source_note("● Beacon — %d nodes" % MeshData.nodes.size(), UiTheme.ACCENT)
	if AppConfig.demo_mode:
		hud.add_source_note("● Simulated traffic", UiTheme.WARN)
	_set_map_running(true)
	feed.start()


func _connect_signals() -> void:
	camera.clicked.connect(_on_clicked)
	camera.double_clicked.connect(_on_double_clicked)
	camera.hovered.connect(_on_hovered)
	camera.view_mode_changed.connect(hud.set_view_3d)
	hud.view_3d_requested.connect(camera.set_3d)
	hud.settings_requested.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/settings_screen.tscn"))
	hud.regions_requested.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/region_screen.tscn"))
	hud.fly_to_requested.connect(func(node: MeshNode) -> void: camera.fly_to(markers.world_of(node), 4.0))
	hud.selection_cleared.connect(func() -> void: markers.set_selected(null))
	animator.hop_reached.connect(func(node: MeshNode, _c: Color) -> void:
		_relay_counts[node.pubkey] = _relay_counts.get(node.pubkey, 0) + 1)
	feed.observation.connect(_on_observation)
	feed.broker_status_changed.connect(hud.set_broker_status)


func _process(delta: float) -> void:
	# Fog scales with zoom so the edge of the streamed area fades into the background at any altitude.
	world_env.environment.fog_density = 0.07 / maxf(camera.distance, 0.1)
	_stats_timer -= delta
	if _stats_timer <= 0.0:
		_stats_timer = 0.5
		hud.set_stats(MeshData.nodes.size(), markers._order.size(), feed.rate_per_minute(), animator.active_count, animator.dropped_count)


func _on_observation(pkt: Dictionary) -> void:
	var result := HopResolver.resolve(pkt, MeshData)
	var nodes: Array[MeshNode] = result.nodes
	hud.log_packet(pkt, nodes.size())
	if hud.is_type_enabled(pkt.payload_type):
		animator.launch(pkt, nodes, result.projected)


func _on_clicked(screen_pos: Vector2) -> void:
	var node := markers.pick(screen_pos)
	markers.set_selected(node)
	hud.show_node(node, _relay_counts.get(node.pubkey, 0) if node else 0)


func _on_double_clicked(screen_pos: Vector2) -> void:
	var node := markers.pick(screen_pos)
	if node == null:
		return
	markers.set_selected(node)
	hud.show_node(node, _relay_counts.get(node.pubkey, 0))
	camera.fly_to(markers.world_of(node), 4.0)


func _on_hovered(screen_pos: Vector2) -> void:
	var node := markers.pick(screen_pos)
	if node != markers.hovered:
		markers.hovered = node
	hud.show_tooltip(node, screen_pos)


func _build_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = UiTheme.BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = true
	env.glow_intensity = 1.0
	env.glow_strength = 1.1
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	for level in 7:
		env.set_glow_level(level, 1.0 if level in [1, 2, 3, 4] else 0.0)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = UiTheme.BG
	env.fog_light_energy = 1.0
	env.fog_sky_affect = 0.0
	return env
