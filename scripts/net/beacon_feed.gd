class_name BeaconFeed
extends Node
## Live packet observations from a Beacon server's public WebSocket (GET /ws), scoped to IATA regions.
## No account is needed, but events carry decoded header fields and the hop path instead of raw bytes.
##
## Protocol (beacon-server internal/ws/handler.go): the server greets with `hello`; we send `configure`
## and `subscribe {scope}`, ping every 30 s (the server drops connections idle for 90 s), and receive
## {type: "event", event, data} messages. Reconnects with exponential backoff and jitter.

signal status_changed(state: MqttClient.State, detail: String)
signal observation_received(data: Dictionary)
signal node_received(data: Dictionary)

const PING_INTERVAL_MS := 30000
## Events usually stream continuously; a silent socket is presumed dead.
const SILENCE_TIMEOUT_MS := 65000
const MAX_BACKOFF := 30.0
## Close codes asking us to come back later (policy violation, try again later).
const SLOW_DOWN_CODES := [1008, 1013]

## Beacon base URL (https://host[/api/v1]); the feed lives at wss://host/ws.
var url := ""
var iatas := PackedStringArray()
var state := MqttClient.State.DISCONNECTED

var _ws: WebSocketPeer
var _running := false
var _subscribed := false
var _backoff := 1.0
var _reconnect_at_ms := 0
var _last_send_ms := 0
var _last_recv_ms := 0
var _next_id := 1


func start() -> void:
	if feed_url(url) == "":
		_set_state(MqttClient.State.ERROR, "invalid Beacon URL")
		return
	_running = true
	_open()


func stop() -> void:
	_running = false
	_close()
	_set_state(MqttClient.State.DISCONNECTED, "stopped")


## https://host/... -> wss://host/ws (http -> ws). Returns "" for anything else.
static func feed_url(base_url: String) -> String:
	var u := base_url.strip_edges()
	var sep := u.find("://")
	if sep < 0:
		return ""
	var scheme := u.substr(0, sep).to_lower()
	var ws_scheme: String = {"https": "wss", "http": "ws", "wss": "wss", "ws": "ws"}.get(scheme, "")
	var host := u.substr(sep + 3).get_slice("/", 0)
	if ws_scheme == "" or host == "":
		return ""
	return "%s://%s/ws" % [ws_scheme, host]


## Maps a packetObservation event onto the dictionary PacketDecoder.decode produces, plus the
## observer fields PacketFeed adds. Returns {} when the event is unusable.
static func to_packet(data: Dictionary) -> Dictionary:
	var packet: Dictionary = data.get("packet", {}) if data.get("packet") is Dictionary else {}
	var obs: Dictionary = data.get("observation", {}) if data.get("observation") is Dictionary else {}
	var packet_hash := str(data.get("packetHash", ""))
	if packet_hash == "" or obs.is_empty():
		return {}
	var payload_type := clampi(int(packet.get("payloadType", 0)), 0, PacketDecoder.PAYLOAD_NAMES.size() - 1)
	var route := clampi(int(packet.get("routeType", PacketDecoder.Route.FLOOD)), 0, PacketDecoder.ROUTE_NAMES.size() - 1)
	var path_length: Dictionary = obs.get("pathLength", {}) if obs.get("pathLength") is Dictionary else {}
	var hash_size := maxi(1, int(path_length.get("hashSize", 1)))
	var pkt := {
		"route": route,
		"route_name": PacketDecoder.ROUTE_NAMES[route],
		"payload_type": payload_type,
		"type_name": PacketDecoder.PAYLOAD_NAMES[payload_type],
		"hash_size": hash_size,
		"hops": [],
		"trace_completed": -1,
		"origin_pubkey": "",
		"origin_hash": "",
		"content_hash": packet_hash.to_lower(),
		"hash": packet_hash.to_lower(),
		"iata": str(obs.get("iata", "")).to_upper(),
		"observer": str(obs.get("observerPublicKey", "")).to_lower(),
		"observer_name": str(obs.get("observerName", "")),
		"snr": float(obs.get("snr", 0.0)) if obs.get("snr") != null else 0.0,
		"rssi": int(obs.get("rssi", 0)) if obs.get("rssi") != null else 0,
	}
	var path_bytes := str(obs.get("pathBytes", "")) if obs.get("pathBytes") != null else ""
	if payload_type == PacketDecoder.Payload.TRACE:
		# A TRACE's header path holds per-hop SNR bytes, not node hashes; its route isn't in the event.
		pkt.trace_completed = 0
	else:
		pkt.hops = PacketDecoder._split_hops(path_bytes.hex_decode(), hash_size)
	var source = obs.get("resolvedSource")
	if source is Dictionary and source.get("confidence") == "high" and source.get("nodes") is Array and source.nodes.size() == 1:
		pkt.origin_pubkey = str(source.nodes[0].get("publicKey", "")).to_lower()
	return pkt


func _open() -> void:
	_close()
	_subscribed = false
	var target := feed_url(url)
	_set_state(MqttClient.State.CONNECTING, target)
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 20
	var err := _ws.connect_to_url(target, TLSOptions.client() if target.begins_with("wss") else null)
	if err != OK:
		_fail("connect failed: %s" % error_string(err))
		return
	_last_recv_ms = Time.get_ticks_msec()


func _close() -> void:
	if _ws:
		_ws.close()
	_ws = null


func _fail(detail: String, slow_down := false) -> void:
	_close()
	_set_state(MqttClient.State.ERROR, detail)
	if _running:
		var wait := MAX_BACKOFF if slow_down else _backoff
		_reconnect_at_ms = Time.get_ticks_msec() + int(wait * randf_range(1.0, 1.25) * 1000.0)
		_backoff = minf(_backoff * 2.0, MAX_BACKOFF)


func _set_state(new_state: MqttClient.State, detail: String) -> void:
	state = new_state
	status_changed.emit(new_state, detail)


func _process(_delta: float) -> void:
	if not _running:
		return
	var now := Time.get_ticks_msec()
	if _ws == null:
		if now >= _reconnect_at_ms:
			_open()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if now - _last_recv_ms > SILENCE_TIMEOUT_MS:
				_fail("timed out connecting")
			return
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			_fail("feed closed (%d%s)" % [code, ": " + reason if reason != "" else ""], code in SLOW_DOWN_CODES)
			return
	while _ws != null and _ws.get_available_packet_count() > 0:
		_last_recv_ms = now
		_handle_message(_ws.get_packet().get_string_from_utf8())
	if _ws == null:
		return
	if _subscribed and now - _last_send_ms > PING_INTERVAL_MS:
		_send({"type": "ping"})
	if now - _last_recv_ms > SILENCE_TIMEOUT_MS:
		_fail("no data for %d s" % (SILENCE_TIMEOUT_MS / 1000))


func _handle_message(text: String) -> void:
	var msg = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	match str(msg.get("type", "")):
		"hello":
			_send({"type": "configure", "includeObserverKey": true})
			_send({"type": "subscribe", "scope": {"iatas": Array(iatas), "events": ["packetObservation", "nodeUpdate"]}})
		"subscribed":
			_subscribed = true
			_backoff = 1.0
			_set_state(MqttClient.State.CONNECTED, "%s · %s" % [feed_url(url), ",".join(iatas)])
		"event":
			var data = msg.get("data")
			if not data is Dictionary:
				return
			match str(msg.get("event", "")):
				"packetObservation":
					observation_received.emit(data)
				"nodeUpdate":
					node_received.emit(data)


func _send(msg: Dictionary) -> void:
	msg.v = 1
	msg.id = str(_next_id)
	_next_id += 1
	_last_send_ms = Time.get_ticks_msec()
	_ws.send_text(JSON.stringify(msg))
