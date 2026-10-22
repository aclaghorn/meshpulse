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
	_test_region_selection()
	_test_config_migration()
	_test_parse_iatas()
	_test_beacon_feed_packet()
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


func _test_region_selection() -> void:
	var config: GDScript = load("res://scripts/core/app_config.gd")
	var app = config.new()
	var many: PackedStringArray = config.normalize_iatas(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH", "III", "JJJ", "KKK", "LLL"])
	eq(many.size(), 10, "regions are capped at MAX_IATAS (10)")
	eq(many[9], "JJJ", "the first MAX_IATAS regions are kept")
	app.selected_iatas = config.normalize_iatas(["sea", "PDX", "SEA", " sjc ", "BOS", "DEN"])
	eq(app.selected_iatas, PackedStringArray(["SEA", "PDX", "SJC", "BOS", "DEN"]), "regions are upper-cased and de-duplicated")
	eq(app.iatas_query(), "SEA,PDX,SJC,BOS,DEN", "regions join into the iatas query")
	eq(app.expand_topics("meshcore/{iata}/+/packets"), PackedStringArray([
		"meshcore/SEA/+/packets", "meshcore/PDX/+/packets", "meshcore/SJC/+/packets",
		"meshcore/BOS/+/packets", "meshcore/DEN/+/packets"]), "{iata} topic expands once per region")
	eq(app.expand_topics(" custom/# , meshcore/{iata}/x/status"), PackedStringArray([
		"custom/#", "meshcore/SEA/x/status", "meshcore/PDX/x/status", "meshcore/SJC/x/status",
		"meshcore/BOS/x/status", "meshcore/DEN/x/status"]), "topics without {iata} pass through")
	app.selected_iatas = PackedStringArray()
	check(not app.has_regions(), "no regions selected")
	eq(app.expand_topics("meshcore/{iata}/+/packets"), PackedStringArray(), "no regions, no region topics")
	app.free()


func _test_config_migration() -> void:
	var config: GDScript = load("res://scripts/core/app_config.gd")
	var app = config.new()
	app.beacons.assign([{"enabled": true, "name": "Sierra Mesh Beacon", "url": "https://beacon.sierrame.sh/", "iatas": "SEA"}])
	app.brokers.assign([
		{"enabled": true, "name": "GoMesh", "url": "wss://mqtt.gomesh.dev", "topic": "meshcore/+/+/packets"},
		{"enabled": true, "name": "Mine", "url": "mqtt://localhost", "topic": "custom/#"},
	])
	app._migrate()
	eq(app.beacons.size(), 1, "Sierra beacon is replaced, not duplicated")
	eq(app.beacons[0].url, config.MESHMAPPER_URL, "Sierra beacon moves to MeshMapper")
	check(app.beacons[0].live and not app.beacons[0].has("iatas"), "migrated beacon streams live and drops its IATA filter")
	check(not app.brokers[0].enabled, "GoMesh is switched off")
	eq(app.brokers[0].topic, "meshcore/{iata}/+/packets", "GoMesh subscribes per region")
	check(app.brokers[1].enabled and app.brokers[1].topic == "custom/#", "custom broker is left alone")

	app.beacons.assign([{"enabled": true, "name": "Own", "url": "https://beacon.example.com", "iatas": ""}])
	app._migrate()
	eq(app.beacons.size(), 2, "MeshMapper is added alongside a custom beacon")
	eq(app.beacons[0].url, config.MESHMAPPER_URL, "MeshMapper goes first")
	check(not app.beacons[1].live, "custom beacon doesn't get a live feed")
	app.free()


func _test_parse_iatas() -> void:
	var client: GDScript = load("res://scripts/net/beacon_client.gd")
	var regions: Array[Dictionary] = client.parse_iatas([
		{"iata": "sea", "displayName": "Seattle", "lat": 47.6, "lon": -122.3},
		{"iata": "AAB", "displayName": null, "lat": null, "lon": null},
		{"iata": ""}, "junk",
	])
	eq(regions.size(), 2, "malformed regions are skipped")
	eq(regions[0].iata, "AAB", "regions sort by code")
	eq(regions[1].iata, "SEA", "codes are upper-cased")
	eq(client.parse_iatas({"error": "nope"}).size(), 0, "non-array body gives no regions")
	var feed: GDScript = load("res://scripts/net/beacon_feed.gd")
	eq(feed.feed_url("https://analyzer.meshmapper.net/"), "wss://analyzer.meshmapper.net/ws", "https Beacon -> wss feed")
	eq(feed.feed_url("http://localhost:8080/api/v1"), "ws://localhost:8080/ws", "http Beacon -> ws feed, path dropped")
	eq(feed.feed_url("beacon.example.com"), "", "URL without scheme is rejected")


func _test_beacon_feed_packet() -> void:
	var feed: GDScript = load("res://scripts/net/beacon_feed.gd")
	# Captured from wss://analyzer.meshmapper.net/ws (trimmed).
	var event: Dictionary = JSON.parse_string('''{"packetHash":"D5E09F0EC8F62944","packet":{"payloadType":4,"payloadTypeName":"ADVERT","routeType":1,"routeTypeName":"FLOOD","isFirstObservation":false,"observationCount":5,"summary":"GUCI - BonGucci"},"observation":{"observerId":"a0d8004f-d44c-4364-882b-6f22ece2f402","observerName":"BOS - Eastie MQTT","observerPublicKey":"8E4DFF403FC5E1A27EA1E1D3E74C35786E47D57063DCE27AE06219C9B5929679","iata":"bos","heardAt":1792543695568,"rssi":-74,"snr":11.75,"sourceBroker":"mqtt1","pathBytes":"757910c9a82a7f42ea57","pathLength":{"raw":"45","hashSize":2,"hopCount":5},"propagationTimeMs":0,"resolvedPath":null,"resolvedSource":{"confidence":"high","nodes":[{"id":"dd0427ee","name":"GUCI - BonGucci","publicKey":"D18F0D1497CE181C9B0C92929507F165D2A2B3858A3795AD186B5DDE52F1B998","latitude":42.285,"longitude":-71.345}]}}}''')
	var pkt: Dictionary = feed.to_packet(event)
	eq(pkt.payload_type, PacketDecoder.Payload.ADVERT, "feed payload type")
	eq(pkt.type_name, "ADVERT", "feed type name")
	eq(pkt.route, PacketDecoder.Route.FLOOD, "feed route")
	eq(pkt.hops, ["7579", "10C9", "A82A", "7F42", "EA57"], "feed path splits into 2-byte hops")
	eq(pkt.hash, "d5e09f0ec8f62944", "feed packet hash is the dedupe key")
	eq(pkt.iata, "BOS", "feed IATA")
	eq(pkt.observer, "8e4dff403fc5e1a27ea1e1d3e74c35786e47d57063dce27ae06219c9b5929679", "feed observer key, lower-cased")
	eq(pkt.observer_name, "BOS - Eastie MQTT", "feed observer name")
	check(is_equal_approx(pkt.snr, 11.75) and pkt.rssi == -74, "feed signal")
	eq(pkt.origin_pubkey, "d18f0d1497ce181c9b0c92929507f165d2a2b3858a3795ad186b5dde52f1b998", "high-confidence source becomes the origin")

	event.observation.resolvedSource.confidence = "ambiguous"
	eq(feed.to_packet(event).origin_pubkey, "", "ambiguous source is not trusted")
	event.packet.payloadType = PacketDecoder.Payload.TRACE
	var trace: Dictionary = feed.to_packet(event)
	check(trace.hops.is_empty() and trace.trace_completed == 0, "TRACE path bytes (SNRs) aren't read as hops")
	eq(feed.to_packet({"packet": {}}), {}, "event without hash or observation is dropped")
