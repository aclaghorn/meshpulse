class_name PacketFeed
extends Node
## Owns one MqttClient per enabled broker (plus the simulator in demo mode), decodes every
## meshcore-packet-capture message and emits one `observation` per packet heard by an observer.

signal observation(pkt: Dictionary)
signal broker_status_changed(index: int, name: String, state: MqttClient.State, detail: String)

var clients: Array[MqttClient] = []
var received_total := 0
var _recent_ms: Array[int] = []


func start() -> void:
	for i in AppConfig.brokers.size():
		var cfg: Dictionary = AppConfig.brokers[i]
		if not cfg.get("enabled", true):
			continue
		var client := MqttClient.new()
		client.name = "Mqtt%d" % i
		client.url = cfg.get("url", "")
		var topic_list := PackedStringArray()
		for t in str(cfg.get("topic", "meshcore/+/+/packets")).split(","):
			if t.strip_edges() != "":
				topic_list.append(t.strip_edges())
		client.topics = topic_list
		client.username = cfg.get("username", "")
		client.password = cfg.get("password", "")
		var label: String = cfg.get("name", "Broker %d" % (i + 1))
		var index := clients.size()
		client.status_changed.connect(func(state, detail): broker_status_changed.emit(index, label, state, detail))
		client.message_received.connect(_on_mqtt_message)
		add_child(client)
		clients.append(client)
		client.start()

	if AppConfig.demo_mode:
		var sim := TrafficSimulator.new()
		sim.name = "Simulator"
		sim.message.connect(_on_json)
		add_child(sim)


## Packets per minute over the last 60 seconds.
func rate_per_minute() -> int:
	var cutoff := Time.get_ticks_msec() - 60000
	while not _recent_ms.is_empty() and _recent_ms[0] < cutoff:
		_recent_ms.pop_front()
	return _recent_ms.size()


func _on_mqtt_message(topic: String, payload: PackedByteArray) -> void:
	var data = JSON.parse_string(payload.get_string_from_utf8())
	if data is Dictionary:
		_on_json(topic, data)


func _on_json(topic: String, data: Dictionary) -> void:
	# Status and other message types share the broker; only packet captures carry a raw frame.
	if str(data.get("type", "PACKET")) != "PACKET":
		return
	var raw := str(data.get("raw", ""))
	if raw == "":
		return
	var pkt := PacketDecoder.decode(raw)
	if pkt.is_empty():
		return

	# Topic template: meshcore/{IATA}/{OBSERVER_PUBKEY}/packets
	var parts := topic.split("/")
	pkt.iata = parts[1] if parts.size() >= 4 else ""
	if AppConfig.is_iata_excluded(pkt.iata):
		return
	var observer := str(data.get("origin_id", ""))
	if observer == "" and parts.size() >= 4:
		observer = parts[2]
	pkt.observer = observer.to_lower()
	pkt.observer_name = str(data.get("origin", ""))
	pkt.snr = str(data.get("SNR", "")).to_float()
	pkt.rssi = str(data.get("RSSI", "")).to_int()
	# Our own content hash, so packets dedupe the same way whichever capture tool sent them.
	pkt.hash = pkt.content_hash

	if pkt.has("advert"):
		_learn_advert(pkt)

	received_total += 1
	_recent_ms.append(Time.get_ticks_msec())
	observation.emit(pkt)


## Adverts carry name, type and location, so nodes missing from Beacon still show up.
func _learn_advert(pkt: Dictionary) -> void:
	var advert: Dictionary = pkt.advert
	var existing := MeshData.find(pkt.origin_pubkey)
	if existing != null and existing.source != "advert" and existing.has_location:
		return
	if advert.has_location or existing == null:
		MeshData.upsert(pkt.origin_pubkey, advert.name, advert.lat, advert.lon, advert.node_type, "advert")
