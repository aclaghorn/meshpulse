extends Node
## Persistent settings: MQTT brokers, Beacon servers and view options, stored in user://meshpulse.cfg.

const CONFIG_PATH := "user://meshpulse.cfg"

## Each broker: {enabled, name, url, topic, username, password}. url scheme is mqtt, mqtts, ws or wss.
var brokers: Array[Dictionary] = []
## Each beacon: {enabled, name, url, iatas}. iatas is an optional comma-separated filter, e.g. "SEA,PDX".
var beacons: Array[Dictionary] = []
var demo_mode := false
var vertical_exaggeration := 2.0
## How sharp map imagery is; higher detail downloads more tiles. See TerrainMap.TILE_PX.
var map_detail := MapDetail.HIGH
## IATA codes to ignore, comma-separated; `*` and `?` wildcards allowed (e.g. "Y*").
var excluded_iatas := DEFAULT_EXCLUDED_IATAS

const DEFAULT_EXCLUDED_IATAS := "MCI,CAK,MCO,Y*"

## STANDARD loads the same tiles whatever the screen size; HIGH and ULTRA scale with screen pixels.
enum MapDetail { STANDARD, HIGH, ULTRA }


func _ready() -> void:
	load_config()


func load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		brokers = [default_broker()]
		beacons = [default_beacon()]
		return
	brokers.assign(cfg.get_value("sources", "brokers", [default_broker()]))
	beacons.assign(cfg.get_value("sources", "beacons", [default_beacon()]))
	demo_mode = cfg.get_value("app", "demo_mode", false)
	vertical_exaggeration = cfg.get_value("view", "vertical_exaggeration", 2.0)
	map_detail = clampi(cfg.get_value("view", "map_detail", MapDetail.HIGH), MapDetail.STANDARD, MapDetail.ULTRA) as MapDetail
	excluded_iatas = cfg.get_value("filters", "excluded_iatas", DEFAULT_EXCLUDED_IATAS)


func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("sources", "brokers", brokers)
	cfg.set_value("sources", "beacons", beacons)
	cfg.set_value("app", "demo_mode", demo_mode)
	cfg.set_value("view", "vertical_exaggeration", vertical_exaggeration)
	cfg.set_value("view", "map_detail", map_detail)
	cfg.set_value("filters", "excluded_iatas", excluded_iatas)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		push_error("Could not save config: %s" % error_string(err))


func is_iata_excluded(iata: String) -> bool:
	return iata_matches(iata, excluded_iatas)


## True when a Beacon node was only ever heard in excluded IATAs. `iatas` is Beacon's
## [{iata, lastHeard}] list; nodes with no IATA history are kept.
func is_node_excluded(iatas: Array) -> bool:
	if iatas.is_empty():
		return false
	for entry in iatas:
		var code := str(entry.get("iata", "")) if entry is Dictionary else str(entry)
		if not is_iata_excluded(code):
			return false
	return true


static func iata_matches(iata: String, patterns: String) -> bool:
	var code := iata.strip_edges().to_upper()
	if code == "":
		return false
	for pattern in patterns.to_upper().split(",", false):
		if code.match(pattern.strip_edges()):
			return true
	return false


static func default_broker() -> Dictionary:
	return {
		"enabled": true,
		"name": "GoMesh",
		"url": "wss://mqtt.gomesh.dev",
		"topic": "meshcore/+/+/packets",
		"username": "example_user",
		"password": "password123",
	}


static func default_beacon() -> Dictionary:
	return {
		"enabled": true,
		"name": "Sierra Mesh Beacon",
		"url": "https://beacon.sierrame.sh/",
		"iatas": "",
	}
