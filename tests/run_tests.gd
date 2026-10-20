extends SceneTree
## Headless unit tests: godot --headless --path . -s tests/run_tests.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_scripts_compile()
	_test_decode_advert()
	_test_decode_multibyte_path()
	_test_decode_transport_flood()
	_test_decode_trace()
	_test_decode_rejects_bad_input()
	_test_mqtt_encoding()
	_test_mqtt_parses_publish()
	_test_mqtt_url_parsing()
	_test_geo_round_trip()
	_test_resolver()
	_test_iata_filter()
	# Needs a camera inside the scene tree, which only exists once the main loop runs.
	_finish.call_deferred()


func _finish() -> void:
	await process_frame
	_test_touch_gestures()
	print("\n%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("FAIL: " + what)


func eq(actual, expected, what: String) -> void:
	check(actual == expected, "%s: expected %s, got %s" % [what, expected, actual])


func _test_scripts_compile() -> void:
	for path in _gd_files("res://scripts"):
		var script: GDScript = load(path)
		check(script != null and script.can_instantiate(), "script compiles: " + path)


func _gd_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_gd_files(dir.path_join(d)))
	return out


# Real ADVERT captured by CoreScope (FLOOD, 2 hops, repeater with location and name).
const ADVERT_RAW := "11023AFA3811EF9726FBC987F4CDD0065B971A51DB1FE578E9570F2C6C888C89C6EF10AF51E84466CCF597A7F9648C0CC541AA581D3BF8DAF606EA6CB08B9C639409A96D307EF1A502D58ED09F63416CC7314E11A270DEDE4F3DC988C7A7FA60F7B951874755FB0B9294EA3302DEBADCF86D657368636F726540656573636F6261722E636F6D"


func _test_decode_advert() -> void:
	var p := PacketDecoder.decode(ADVERT_RAW)
	eq(p.route, PacketDecoder.Route.FLOOD, "advert route")
	eq(p.payload_type, PacketDecoder.Payload.ADVERT, "advert type")
	eq(p.hops, ["3A", "FA"], "advert hops")
	eq(p.origin_pubkey, "3811ef9726fbc987f4cdd0065b971a51db1fe578e9570f2c6c888c89c6ef10af", "advert origin")
	eq(p.advert.name, "meshcore@eescobar.com", "advert name")
	check(absf(p.advert.lat - 36.95682) < 1e-5 and absf(p.advert.lon + 119.75197) < 1e-5, "advert location %s,%s" % [p.advert.lat, p.advert.lon])
	eq(p.advert.node_type, MeshNode.Type.REPEATER, "advert node type")
	eq(p.content_hash.length(), 16, "content hash length")
	# Same packet with a longer path must hash the same (dedupe across observers).
	var longer := "1103" + "3AFA77" + ADVERT_RAW.substr(8)
	eq(PacketDecoder.decode(longer).content_hash, p.content_hash, "hash ignores path")


func _test_decode_multibyte_path() -> void:
	# GRP_TXT flood, path_len 0x42 = 2 hops of 2 bytes.
	var p := PacketDecoder.decode("1542AABBCCDD0102030405")
	eq(p.payload_type, PacketDecoder.Payload.GRP_TXT, "grp type")
	eq(p.hash_size, 2, "2-byte hash size")
	eq(p.hops, ["AABB", "CCDD"], "2-byte hops")


func _test_decode_transport_flood() -> void:
	# TXT_MSG over TRANSPORT_FLOOD: header, 4 transport bytes, 1 hop, dest/src hashes.
	var p := PacketDecoder.decode("08" + "11223344" + "01" + "C8" + "7F2E" + "DEADBEEF")
	eq(p.route, PacketDecoder.Route.TRANSPORT_FLOOD, "transport route")
	eq(p.payload_type, PacketDecoder.Payload.TXT_MSG, "txt type")
	eq(p.hops, ["C8"], "transport hops")
	eq(p.origin_hash, "2E", "txt src hash")


func _test_decode_trace() -> void:
	# TRACE direct: path holds 2 SNR bytes; payload tag(4) auth(4) flags(1) + 3 route hashes.
	var p := PacketDecoder.decode("26" + "02" + "1020" + "01020304" + "05060708" + "00" + "A1B2C3")
	eq(p.payload_type, PacketDecoder.Payload.TRACE, "trace type")
	eq(p.hops, ["A1", "B2", "C3"], "trace route")
	eq(p.trace_completed, 2, "trace completed hops")
	# flags & 3 == 1 => 2-byte route hashes
	var wide := PacketDecoder.decode("26" + "00" + "01020304" + "05060708" + "01" + "A1A2B1B2")
	eq(wide.hops, ["A1A2", "B1B2"], "trace 2-byte route")


func _test_decode_rejects_bad_input() -> void:
	eq(PacketDecoder.decode(""), {}, "empty")
	eq(PacketDecoder.decode("11"), {}, "too short")
	eq(PacketDecoder.decode("1105AABB"), {}, "path longer than packet")
	eq(PacketDecoder.decode("D1003344"), {}, "unknown version")


func _test_mqtt_encoding() -> void:
	eq(MqttClient.encode_remaining_length(0), PackedByteArray([0]), "rl 0")
	eq(MqttClient.encode_remaining_length(127), PackedByteArray([127]), "rl 127")
	eq(MqttClient.encode_remaining_length(321), PackedByteArray([0xC1, 0x02]), "rl 321")
	var c := MqttClient.build_connect("id", "u", "p", 60)
	var expected := PackedByteArray([0x10, 20, 0, 4]) + "MQTT".to_ascii_buffer() + PackedByteArray([4, 0xC2, 0, 60, 0, 2]) + "id".to_ascii_buffer() + PackedByteArray([0, 1]) + "u".to_ascii_buffer() + PackedByteArray([0, 1]) + "p".to_ascii_buffer()
	eq(c, expected, "connect bytes")
	var anon := MqttClient.build_connect("id", "", "", 30)
	eq(anon[9], 0x02, "anonymous connect flags")
	var s := MqttClient.build_subscribe(7, PackedStringArray(["a/#"]))
	eq(s, PackedByteArray([0x82, 8, 0, 7, 0, 3]) + "a/#".to_ascii_buffer() + PackedByteArray([0]), "subscribe bytes")


func _test_mqtt_parses_publish() -> void:
	var client := MqttClient.new()
	var got := []
	client.message_received.connect(func(t, p): got.append([t, p.get_string_from_utf8()]))
	var topic := "meshcore/SEA/ABC/packets"
	var payload := '{"raw":"00"}'
	var body := MqttClient.encode_string(topic) + payload.to_utf8_buffer()
	var frame := PackedByteArray([0x30]) + MqttClient.encode_remaining_length(body.size()) + body
	# Two frames, the second split across reads.
	client._rx = frame + frame.slice(0, 5)
	client._parse_incoming()
	eq(got.size(), 1, "one complete publish parsed")
	client._rx.append_array(frame.slice(5))
	client._parse_incoming()
	eq(got.size(), 2, "split publish parsed")
	if got.size() == 2:
		eq(got[1], [topic, payload], "publish topic/payload")
	client.free()


func _test_mqtt_url_parsing() -> void:
	var c := MqttClient.new()
	eq(c.parse_url("mqtt://broker.local"), "", "mqtt url ok")
	eq([c._host, c._port], ["broker.local", 1883], "mqtt default port")
	eq(c.parse_url("wss://mqtt.example.com/mqtt"), "", "wss url ok")
	eq([c._host, c._port, c._path], ["mqtt.example.com", 443, "/mqtt"], "wss defaults")
	eq(c.parse_url("mqtts://10.0.0.5:8884"), "", "mqtts url ok")
	eq(c._port, 8884, "explicit port")
	check(c.parse_url("broker:1883") != "", "missing scheme rejected")
	check(c.parse_url("http://x") != "", "http rejected")
	c.free()


func _test_geo_round_trip() -> void:
	Geo.set_origin(47.6, -122.3)
	var p := Geo.latlon_to_world(47.7, -122.1)
	var back := Geo.world_to_latlon(p)
	check(absf(back.x - 47.7) < 1e-4 and absf(back.y + 122.1) < 1e-4, "geo round trip %s" % back)
	# World units should be close to true km near the origin.
	var km := Geo.distance_km(47.6, -122.3, 47.7, -122.1)
	check(absf(Vector2(p.x, p.z).length() - km) / km < 0.01, "world units ≈ km (%.3f vs %.3f)" % [Vector2(p.x, p.z).length(), km])
	check(p.z < 0.0 and p.x > 0.0, "north is -Z, east is +X")


func _test_resolver() -> void:
	var reg: Node = load("res://scripts/mesh/mesh_data.gd").new()
	var origin := "11" + "00".repeat(31)
	reg.upsert(origin, "Origin", 47.00, -122.00, MeshNode.Type.COMPANION)
	reg.upsert("3a" + "01".repeat(31), "Hop A", 47.05, -122.00, MeshNode.Type.REPEATER)
	reg.upsert("fa" + "02".repeat(31), "Hop B near", 47.10, -122.00, MeshNode.Type.REPEATER)
	reg.upsert("fa" + "03".repeat(31), "Hop B far", 40.00, -100.00, MeshNode.Type.REPEATER)
	reg.upsert("fa" + "04".repeat(31), "Companion with B prefix", 47.10, -122.01, MeshNode.Type.COMPANION)
	reg.upsert("bb" + "05".repeat(31), "Observer", 47.15, -122.00, MeshNode.Type.COMPANION)
	reg.upsert("cc" + "06".repeat(31), "No location", 0.0, 0.0, MeshNode.Type.REPEATER)

	var pkt := {
		"route": PacketDecoder.Route.FLOOD, "payload_type": PacketDecoder.Payload.ADVERT,
		"hops": ["3A", "FA", "CC"], "origin_pubkey": origin, "observer": "bb" + "05".repeat(31),
	}
	var res := HopResolver.resolve(pkt, reg)
	var names: Array = res.nodes.map(func(n): return n.name)
	eq(names, ["Origin", "Hop A", "Hop B near", "Observer"], "flood route resolution")
	eq(res.projected, false, "flood not projected")

	pkt.route = PacketDecoder.Route.DIRECT
	pkt.payload_type = PacketDecoder.Payload.TXT_MSG
	res = HopResolver.resolve(pkt, reg)
	eq(res.nodes.map(func(n): return n.name), ["Observer", "Hop A", "Hop B near"], "direct route is observer then remaining hops")
	eq(res.projected, true, "direct is projected")

	var trace := {"route": PacketDecoder.Route.DIRECT, "payload_type": PacketDecoder.Payload.TRACE,
		"hops": ["3A", "FA"], "trace_completed": 1, "observer": "bb" + "05".repeat(31)}
	eq(HopResolver.resolve(trace, reg).nodes.map(func(n): return n.name), ["Hop A", "Observer"], "trace only crossed hops")

	eq(reg.candidates("FA").size(), 3, "prefix candidates")
	eq(reg.candidates("fa02").size(), 1, "2-byte prefix candidates")
	reg.free()


func _touch(cam: Camera3D, index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	cam._unhandled_input(e)


func _drag(cam: Camera3D, index: int, from: Vector2, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = to
	e.relative = to - from
	cam._unhandled_input(e)


func _test_touch_gestures() -> void:
	Geo.set_origin(47.6, -122.3)
	# Loaded at runtime: naming MapCamera here would compile it before the Tiles autoload exists.
	var cam: Camera3D = load("res://scripts/camera/map_camera.gd").new()
	root.add_child(cam)
	cam.jump_to(Vector3.ZERO, 100.0)

	_touch(cam, 0, Vector2(700, 480), true)
	cam._panning = true  # as if the emulated mouse had started a pan
	_touch(cam, 1, Vector2(900, 480), true)
	eq(cam._panning, false, "second finger stops the one-finger pan")

	_drag(cam, 1, Vector2(900, 480), Vector2(1000, 480))
	check(cam._goal_distance < 70.0 and cam._goal_distance > 63.0, "pinch apart zooms in (%.1f)" % cam._goal_distance)
	eq(cam.free_3d, false, "pinch doesn't enter 3D")

	_drag(cam, 1, Vector2(1000, 480), Vector2(850, 330))
	check(absf(cam._goal_yaw + 45.0) < 0.5, "twist rotates (%.1f)" % cam._goal_yaw)

	var pitch_before: float = cam._goal_pitch
	_drag(cam, 0, Vector2(700, 480), Vector2(700, 460))
	_drag(cam, 1, Vector2(850, 330), Vector2(850, 310))
	check(cam._goal_pitch > pitch_before, "two-finger drag up tilts (%.1f -> %.1f)" % [pitch_before, cam._goal_pitch])
	eq(cam.free_3d, true, "tilting enters free 3D")

	_touch(cam, 1, Vector2(850, 310), false)
	eq(cam._touches.size(), 1, "lifted finger forgotten")

	# Orbiting: yaw must glide steadily toward the goal, never swing back.
	cam.yaw = 0.0
	cam._goal_yaw = 40.0
	var prev := 0.0
	var monotonic := true
	for i in 60:
		cam._process(1.0 / 60.0)
		monotonic = monotonic and cam.yaw >= prev - 1e-4
		prev = cam.yaw
	check(monotonic and absf(cam.yaw - 40.0) < 1.0, "yaw eases monotonically to goal (ended at %.2f)" % cam.yaw)
	cam.free()


func _test_iata_filter() -> void:
	var config: GDScript = load("res://scripts/core/app_config.gd")
	var patterns := "MCI,CAK,MCO,Y*"
	for code in ["MCI", "cak", "MCO", "YVR", "YYJ", "Y"]:
		check(config.iata_matches(code, patterns), "excluded: " + code)
	for code in ["SFO", "OAK", "SYD", "", "MCIX"]:
		check(not config.iata_matches(code, patterns), "kept: " + code)
	var app = config.new()
	app.excluded_iatas = patterns
	check(app.is_node_excluded([{"iata": "YVR"}, {"iata": "MCO"}]), "node only heard in excluded IATAs is dropped")
	check(not app.is_node_excluded([{"iata": "YVR"}, {"iata": "SFO"}]), "node also heard elsewhere is kept")
	check(not app.is_node_excluded([]), "node with no IATA history is kept")
	app.free()
