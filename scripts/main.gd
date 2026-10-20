extends Node3D
## The live map: wires the packet feed through hop resolution into the animator, and connects
## camera picking, the HUD and the environment.

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
	Geo.vertical_scale = AppConfig.vertical_exaggeration
	if not MeshData.origin_set:
		MeshData.set_origin_from_nodes()
	world_env.environment = _build_environment()
	markers.rebuild()

	var points: Array[Vector3] = []
	for node in MeshData.located_nodes():
		points.append(Geo.latlon_to_world(node.lat, node.lon))
	camera.frame_points(points)

	camera.clicked.connect(_on_clicked)
	camera.double_clicked.connect(_on_double_clicked)
	camera.hovered.connect(_on_hovered)
	camera.view_mode_changed.connect(hud.set_view_3d)
	hud.view_3d_requested.connect(camera.set_3d)
	hud.setup_requested.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/setup_screen.tscn"))
	hud.fly_to_requested.connect(func(node: MeshNode) -> void: camera.fly_to(markers.world_of(node), 4.0))
	hud.selection_cleared.connect(func() -> void: markers.set_selected(null))
	animator.hop_reached.connect(func(node: MeshNode, _c: Color) -> void:
		_relay_counts[node.pubkey] = _relay_counts.get(node.pubkey, 0) + 1)
	feed.observation.connect(_on_observation)
	feed.broker_status_changed.connect(hud.set_broker_status)

	var beacons := AppConfig.beacons.filter(func(b: Dictionary) -> bool: return b.get("enabled", true))
	if not beacons.is_empty():
		hud.add_source_note("● Beacon — %d nodes" % MeshData.nodes.size(), UiTheme.ACCENT)
	if AppConfig.demo_mode:
		hud.add_source_note("● Simulated traffic", UiTheme.WARN)
	feed.start()


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
