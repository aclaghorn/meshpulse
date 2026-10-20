extends SceneTree
## Integration test against tools/fake_broker.py:
##   python3 tools/fake_broker.py --port 18830 --count 4 --interval 0.2 &
##   godot --headless --path . -s tests/mqtt_live_test.gd
## Or against a real broker (waits up to 20 s for --min messages):
##   godot --headless --path . -s tests/mqtt_live_test.gd -- --url=wss://host --user=u --pass=p --min=1

var client: MqttClient
var received: Array = []
var states: Array = []
var _deadline := 0
var _min := 4


func _initialize() -> void:
	client = MqttClient.new()
	client.url = "mqtt://localhost:18830"
	client.topics = PackedStringArray(["meshcore/+/+/packets"])
	client.username = "tester"
	client.password = "secret"
	var timeout_ms := 8000
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"url": client.url = kv[1]; timeout_ms = 20000
			"user": client.username = kv[1]
			"pass": client.password = kv[1]
			"min": _min = kv[1].to_int()
	client.status_changed.connect(func(s, d): states.append(s); print("state ", MqttClient.State.keys()[s], " ", d))
	client.message_received.connect(func(t, p): received.append([t, p]))
	root.add_child(client)
	client.start()
	_deadline = Time.get_ticks_msec() + timeout_ms


func _process(_delta: float) -> bool:
	if received.size() >= _min or Time.get_ticks_msec() > _deadline:
		var ok := received.size() >= _min and MqttClient.State.CONNECTED in states
		for r in received:
			var data = JSON.parse_string(r[1].get_string_from_utf8())
			if data is Dictionary and data.has("raw"):
				var pkt := PacketDecoder.decode(data.raw)
				print("got ", r[0], " -> ", pkt.get("type_name"), " hops=", pkt.get("hops"))
			else:
				print("got ", r[0], " (non-packet message)")
		client.stop()
		print("PASS" if ok else "FAIL: received %d messages" % received.size())
		quit(0 if ok else 1)
	return false
