class_name MqttClient
extends Node
## Minimal MQTT 3.1.1 subscriber over TCP, TLS or WebSocket, polled from _process.
##
## URL schemes: mqtt:// (1883), mqtts:// (8883), ws:// (80), wss:// (443). WebSocket URLs keep their path.
## Reconnects with exponential backoff.

signal status_changed(state: State, detail: String)
signal message_received(topic: String, payload: PackedByteArray)

enum State { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

const CONNECT := 1
const CONNACK := 2
const PUBLISH := 3
const PUBACK := 4
const PUBREC := 5
const PUBREL := 6
const PUBCOMP := 7
const SUBSCRIBE := 8
const SUBACK := 9
const PINGREQ := 12
const PINGRESP := 13
const DISCONNECT := 14

const CONNACK_ERRORS := ["", "unacceptable protocol version", "client id rejected", "server unavailable", "bad username or password", "not authorized"]

var url := ""
var topics := PackedStringArray()
var username := ""
var password := ""
var client_id := "meshpulse-%08x" % randi()
var keepalive_seconds := 60
var state := State.DISCONNECTED

var _scheme := ""
var _host := ""
var _port := 0
var _path := "/"
var _tcp: StreamPeerTCP
var _tls: StreamPeerTLS
var _ws: WebSocketPeer
var _rx := PackedByteArray()
var _handshake_sent := false
var _last_send_ms := 0
var _last_recv_ms := 0
var _next_packet_id := 1
var _running := false
var _backoff := 1.0
var _reconnect_at_ms := 0


func start() -> void:
	var err := parse_url(url)
	if err != "":
		_set_state(State.ERROR, err)
		return
	_running = true
	_open()


func stop() -> void:
	_running = false
	if state == State.CONNECTED:
		_send(PackedByteArray([DISCONNECT << 4, 0]))
	_close()
	_set_state(State.DISCONNECTED, "stopped")


## Fills host/port/path from `url`; returns an error message, or "" when valid.
func parse_url(value: String) -> String:
	var u := value.strip_edges()
	var sep := u.find("://")
	if sep < 0:
		return "URL needs a scheme (mqtt://, mqtts://, ws:// or wss://)"
	_scheme = u.substr(0, sep).to_lower()
	var rest := u.substr(sep + 3)
	var slash := rest.find("/")
	var authority := rest if slash < 0 else rest.substr(0, slash)
	_path = "/" if slash < 0 else rest.substr(slash)
	var default_ports := {"mqtt": 1883, "tcp": 1883, "mqtts": 8883, "ssl": 8883, "tls": 8883, "ws": 80, "wss": 443}
	if not default_ports.has(_scheme):
		return "Unsupported scheme '%s'" % _scheme
	if OS.has_feature("web") and not _is_websocket():
		return "Browsers can only reach brokers over ws:// or wss://"
	var colon := authority.rfind(":")
	if colon > 0 and not authority.ends_with("]"):
		_host = authority.substr(0, colon)
		_port = authority.substr(colon + 1).to_int()
	else:
		_host = authority
		_port = default_ports[_scheme]
	_host = _host.trim_prefix("[").trim_suffix("]")
	if _host == "" or _port <= 0 or _port > 65535:
		return "Invalid host or port"
	return ""


func _is_websocket() -> bool:
	return _scheme == "ws" or _scheme == "wss"


func _uses_tls() -> bool:
	return _scheme in ["mqtts", "ssl", "tls", "wss"]


func _open() -> void:
	_close()
	_rx.clear()
	_handshake_sent = false
	_set_state(State.CONNECTING, "%s:%d" % [_host, _port])
	var err := OK
	if _is_websocket():
		_ws = WebSocketPeer.new()
		_ws.supported_protocols = PackedStringArray(["mqtt"])
		_ws.inbound_buffer_size = 1 << 20
		var tls_opts := TLSOptions.client() if _uses_tls() else null
		err = _ws.connect_to_url("%s://%s:%d%s" % [_scheme, _host, _port, _path], tls_opts)
	else:
		_tcp = StreamPeerTCP.new()
		err = _tcp.connect_to_host(_host, _port)
	if err != OK:
		_fail("connect failed: %s" % error_string(err))


func _close() -> void:
	if _ws:
		_ws.close()
	if _tls:
		_tls.disconnect_from_stream()
	if _tcp:
		_tcp.disconnect_from_host()
	_ws = null
	_tls = null
	_tcp = null


func _fail(detail: String) -> void:
	_close()
	_set_state(State.ERROR, detail)
	if _running:
		_reconnect_at_ms = Time.get_ticks_msec() + int(_backoff * 1000.0)
		_backoff = minf(_backoff * 2.0, 30.0)


func _set_state(new_state: State, detail: String) -> void:
	state = new_state
	status_changed.emit(new_state, detail)


func _process(_delta: float) -> void:
	if not _running:
		return
	var now := Time.get_ticks_msec()
	if _ws == null and _tcp == null:
		if now >= _reconnect_at_ms:
			_open()
		return

	if not _poll_transport():
		return

	if not _handshake_sent:
		_handshake_sent = true
		_send(build_connect(client_id, username, password, keepalive_seconds))
		_last_recv_ms = now

	_parse_incoming()

	if state == State.CONNECTED and now - _last_send_ms > keepalive_seconds * 500:
		_send(PackedByteArray([PINGREQ << 4, 0]))
	if now - _last_recv_ms > keepalive_seconds * 1500:
		_fail("timed out")


## Advances the transport; returns true once it can carry MQTT bytes. Drains received bytes into _rx.
func _poll_transport() -> bool:
	if _ws:
		_ws.poll()
		match _ws.get_ready_state():
			WebSocketPeer.STATE_CONNECTING:
				return false
			WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
				var reason := _ws.get_close_reason()
				_fail("websocket closed (%d%s)" % [_ws.get_close_code(), ": " + reason if reason != "" else ""])
				return false
		while _ws.get_available_packet_count() > 0:
			_rx.append_array(_ws.get_packet())
			_last_recv_ms = Time.get_ticks_msec()
		return true

	_tcp.poll()
	var tcp_status := _tcp.get_status()
	if tcp_status == StreamPeerTCP.STATUS_CONNECTING:
		return false
	if tcp_status != StreamPeerTCP.STATUS_CONNECTED:
		_fail("tcp connection lost" if _handshake_sent else "tcp connect failed")
		return false

	var stream: StreamPeer = _tcp
	if _uses_tls():
		if _tls == null:
			_tls = StreamPeerTLS.new()
			var err := _tls.connect_to_stream(_tcp, _host, TLSOptions.client())
			if err != OK:
				_fail("tls setup failed: %s" % error_string(err))
				return false
		_tls.poll()
		match _tls.get_status():
			StreamPeerTLS.STATUS_HANDSHAKING:
				return false
			StreamPeerTLS.STATUS_CONNECTED:
				pass
			StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
				_fail("tls hostname mismatch")
				return false
			_:
				_fail("tls handshake failed")
				return false
		stream = _tls

	var available := stream.get_available_bytes()
	if available > 0:
		var res := stream.get_data(available)
		if res[0] == OK:
			_rx.append_array(res[1])
			_last_recv_ms = Time.get_ticks_msec()
	return true


func _send(bytes: PackedByteArray) -> void:
	_last_send_ms = Time.get_ticks_msec()
	if _ws:
		_ws.send(bytes)
	elif _tls:
		_tls.put_data(bytes)
	elif _tcp:
		_tcp.put_data(bytes)


func _parse_incoming() -> void:
	while _rx.size() >= 2:
		var length := 0
		var multiplier := 1
		var i := 1
		var complete := false
		while i < _rx.size() and i <= 4:
			var b := _rx[i]
			length += (b & 0x7F) * multiplier
			multiplier *= 128
			i += 1
			if (b & 0x80) == 0:
				complete = true
				break
		if not complete:
			if i > 4:
				_fail("malformed packet length")
			return
		if _rx.size() < i + length:
			return
		var packet_type := _rx[0] >> 4
		var flags := _rx[0] & 0x0F
		var body := _rx.slice(i, i + length)
		_rx = _rx.slice(i + length)
		_handle_packet(packet_type, flags, body)
		if _ws == null and _tcp == null:
			return


func _handle_packet(packet_type: int, flags: int, body: PackedByteArray) -> void:
	match packet_type:
		CONNACK:
			var code := body[1] if body.size() >= 2 else 255
			if code != 0:
				var reason: String = CONNACK_ERRORS[code] if code < CONNACK_ERRORS.size() else "refused (%d)" % code
				_fail("broker refused: %s" % reason)
				return
			_backoff = 1.0
			_set_state(State.CONNECTED, "%s:%d" % [_host, _port])
			if not topics.is_empty():
				_send(build_subscribe(_take_packet_id(), topics))
		PUBLISH:
			var qos := (flags >> 1) & 0x03
			if body.size() < 2:
				return
			var topic_len := (body[0] << 8) | body[1]
			var pos := 2 + topic_len
			if body.size() < pos:
				return
			var topic := body.slice(2, pos).get_string_from_utf8()
			if qos > 0:
				var pid_bytes := body.slice(pos, pos + 2)
				pos += 2
				var ack_type := PUBACK if qos == 1 else PUBREC
				var ack := PackedByteArray([ack_type << 4, 2])
				ack.append_array(pid_bytes)
				_send(ack)
			message_received.emit(topic, body.slice(pos))
		PUBREL:
			var comp := PackedByteArray([PUBCOMP << 4, 2])
			comp.append_array(body.slice(0, 2))
			_send(comp)
		SUBACK:
			for code in body.slice(2):
				if code == 0x80:
					_set_state(State.CONNECTED, "subscription rejected by broker")
		PINGRESP:
			pass


func _take_packet_id() -> int:
	var id := _next_packet_id
	_next_packet_id = _next_packet_id % 65535 + 1
	return id


static func encode_string(s: String) -> PackedByteArray:
	var utf8 := s.to_utf8_buffer()
	var out := PackedByteArray([utf8.size() >> 8, utf8.size() & 0xFF])
	out.append_array(utf8)
	return out


static func encode_remaining_length(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	while true:
		var digit := n % 128
		n /= 128
		if n > 0:
			digit |= 0x80
		out.append(digit)
		if n == 0:
			break
	return out


static func build_connect(id: String, user: String, pwd: String, keepalive: int) -> PackedByteArray:
	var flags := 0x02  # clean session
	if user != "":
		flags |= 0x80
		if pwd != "":
			flags |= 0x40
	var body := encode_string("MQTT")
	body.append_array(PackedByteArray([4, flags, keepalive >> 8, keepalive & 0xFF]))
	body.append_array(encode_string(id))
	if user != "":
		body.append_array(encode_string(user))
		if pwd != "":
			body.append_array(encode_string(pwd))
	return _frame(CONNECT << 4, body)


static func build_subscribe(packet_id: int, topic_filters: PackedStringArray, qos := 0) -> PackedByteArray:
	var body := PackedByteArray([packet_id >> 8, packet_id & 0xFF])
	for t in topic_filters:
		body.append_array(encode_string(t))
		body.append(qos)
	return _frame((SUBSCRIBE << 4) | 0x02, body)


static func _frame(first_byte: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([first_byte])
	out.append_array(encode_remaining_length(body.size()))
	out.append_array(body)
	return out
