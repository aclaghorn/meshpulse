class_name PacketFeed
extends Node
## Owns one MqttClient per enabled broker and one BeaconFeed per live Beacon server (plus the simulator
## in demo mode), all scoped to the selected IATA regions, and emits one `observation` per packet heard
## by an observer. MQTT messages are decoded from raw bytes; Beacon events arrive already decoded.

signal observation(pkt: Dictionary)
signal broker_status_changed(index: int, name: String, state: MqttClient.State, detail: String)

var clients: Array[Node] = []
var received_total := 0
var _recent_ms: Array[int] = []


func start() -> void:
	for i in AppConfig.beacons.size():
		var cfg: Dictionary = AppConfig.beacons[i]
		if not cfg.get("enabled", true) or not cfg.get("live", false) or not AppConfig.has_regions():
			continue
		var feed := BeaconFeed.new()
		feed.name = "BeaconFeed%d" % i
		feed.url = cfg.get("url", "")
		feed.iatas = AppConfig.selected_iatas
		feed.observation_received.connect(_on_beacon_observation)
		feed.node_received.connect(_on_beacon_node)
		_add_client(feed, "%s live" % cfg.get("name", "Beacon"))

	for i in AppConfig.brokers.size():
		var cfg: Dictionary = AppConfig.brokers[i]
		if not cfg.get("enabled", true):
			continue
		var topic_list := AppConfig.expand_topics(str(cfg.get("topic", AppConfig.default_broker().topic)))
		if topic_list.is_empty():
			continue
		var client := MqttClient.new()
		client.name = "Mqtt%d" % i
		client.url = cfg.get("url", "")
		client.topics = topic_list
		client.username = cfg.get("username", "")
		client.password = cfg.get("password", "")
		client.message_received.connect(_on_mqtt_message)
		_add_client(client, cfg.get("name", "Broker %d" % (i + 1)))

	if AppConfig.demo_mode:
		var sim := TrafficSimulator.new()
		sim.name = "Simulator"
		sim.message.connect(_on_json)
		add_child(sim)


## Starts a MqttClient or BeaconFeed, reporting its status under its own HUD slot.
func _add_client(client: Node, label: String) -> void:
	var index := clients.size()
	client.status_changed.connect(func(state, detail): broker_status_changed.emit(index, label, state, detail))
	add_child(client)
	clients.append(client)
	client.start()


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
	var observer := str(data.get("origin_id", ""))
	if observer == "" and parts.size() >= 4:
		observer = parts[2]
	pkt.observer = observer.to_lower()
	pkt.observer_name = str(data.get("origin", ""))
	pkt.snr = str(data.get("SNR", "")).to_float()
	pkt.rssi = str(data.get("RSSI", "")).to_int()
	# Our own content hash, so packets dedupe the same way whichever capture tool sent them.
	pkt.hash = pkt.content_hash
	_emit_packet(pkt)


func _on_beacon_observation(data: Dictionary) -> void:
	var pkt := BeaconFeed.to_packet(data)
	if not pkt.is_empty():
		_emit_packet(pkt)


## Beacon pushes node changes (new adverts, moves) in the same shape as its /nodes items.
func _on_beacon_node(data: Dictionary) -> void:
	MeshData.upsert_from_beacon(data)


func _emit_packet(pkt: Dictionary) -> void:
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
