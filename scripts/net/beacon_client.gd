class_name BeaconClient
extends Node
## Pulls the node directory (GET /api/v1/nodes, cursor paginated) and the IATA region list
## (GET /api/v1/iatas) from a MeshCore Beacon server.

signal progress(loaded: int)

const PAGE_LIMIT := 200
const MAX_PAGES := 250
const MAX_RETRIES := 3

var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 20.0
	_http.use_threads = true
	add_child(_http)


## Returns {ok: bool, nodes: Array[Dictionary], error: String}. On a mid-way failure `nodes`
## holds whatever pages were fetched before it.
func fetch_nodes(base_url: String, iatas := "") -> Dictionary:
	var base := api_base(base_url)
	var nodes: Array = []
	var page_cursor := ""
	var cursor := -1
	for page in MAX_PAGES:
		var query := "limit=%d" % PAGE_LIMIT
		if iatas.strip_edges() != "":
			query += "&iatas=" + iatas.replace(" ", "").uri_encode()
		if page_cursor != "":
			query += "&pageCursor=" + page_cursor.uri_encode()
		elif cursor >= 0:
			query += "&cursor=%d" % cursor
		var res := await _get_json("%s/nodes?%s" % [base, query])
		if not res.ok:
			return {"ok": false, "nodes": nodes, "error": res.error}
		var body: Dictionary = res.data if res.data is Dictionary else {}
		nodes.append_array(body.get("items", []))
		progress.emit(nodes.size())
		if not body.get("hasMore", false):
			break
		page_cursor = str(body.get("nextPageCursor", "")) if body.get("nextPageCursor") != null else ""
		cursor = int(body.get("nextCursor", -1)) if body.get("nextCursor") != null else -1
		if page_cursor == "" and cursor < 0:
			break
	return {"ok": true, "nodes": nodes, "error": ""}


## Returns {ok, iatas: Array[Dictionary], error}; each region is {iata, displayName, lat, lon},
## with displayName, lat and lon possibly null.
func fetch_iatas(base_url: String) -> Dictionary:
	var res := await _get_json(api_base(base_url) + "/iatas")
	if not res.ok:
		return {"ok": false, "iatas": [], "error": res.error}
	return {"ok": true, "iatas": parse_iatas(res.data), "error": ""}


## Keeps well-formed entries, upper-cases codes and sorts by code.
static func parse_iatas(data) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not data is Array:
		return out
	for item in data:
		if item is Dictionary and str(item.get("iata", "")).strip_edges() != "":
			var region: Dictionary = item.duplicate()
			region.iata = str(item.iata).strip_edges().to_upper()
			out.append(region)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.iata < b.iata)
	return out


## Accepts "https://host", "https://host/" or "https://host/api/v1".
static func api_base(base_url: String) -> String:
	var base := base_url.strip_edges().trim_suffix("/")
	if not base.ends_with("/api/v1"):
		base += "/api/v1"
	return base


func _get_json(url: String) -> Dictionary:
	for attempt in MAX_RETRIES:
		var request_headers := PackedStringArray(["Accept: application/json"])
		if not OS.has_feature("web"):
			request_headers.append("User-Agent: MeshPulse/0.1")
		var err := _http.request(url, request_headers)
		if err != OK:
			return {"ok": false, "error": "request failed: %s" % error_string(err)}
		var r: Array = await _http.request_completed
		var result: int = r[0]
		var code: int = r[1]
		var headers: PackedStringArray = r[2]
		var body: PackedByteArray = r[3]
		if result != HTTPRequest.RESULT_SUCCESS:
			return {"ok": false, "error": "network error (%s)" % _result_name(result)}
		if code == 429 or code == 503:
			var wait := 2.0
			for h in headers:
				if h.to_lower().begins_with("retry-after:"):
					wait = maxf(1.0, h.get_slice(":", 1).strip_edges().to_float())
			await get_tree().create_timer(wait).timeout
			continue
		if code != 200:
			return {"ok": false, "error": "HTTP %d from %s" % [code, url]}
		var data = JSON.parse_string(body.get_string_from_utf8())
		if data == null:
			return {"ok": false, "error": "invalid JSON from %s" % url}
		return {"ok": true, "data": data}
	return {"ok": false, "error": "rate limited by server"}


static func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT: return "can't connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "can't resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS handshake error"
		HTTPRequest.RESULT_TIMEOUT: return "timeout"
	return "code %d" % result
