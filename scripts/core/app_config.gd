extends Node
## Persistent settings: selected regions, MQTT brokers, Beacon servers and view options, stored in
## user://meshpulse.cfg.

const CONFIG_PATH := "user://meshpulse.cfg"
## Bumped when saved sources need migrating; see _migrate.
const CONFIG_VERSION := 2
## Most IATA regions the map follows at once.
const MAX_IATAS := 10
const MESHMAPPER_URL := "https://analyzer.meshmapper.net/"
const IATA_TOKEN := "{iata}"

## Each broker: {enabled, name, url, topic, username, password}. url scheme is mqtt, mqtts, ws or wss.
## A topic containing {iata} is subscribed once per selected region.
var brokers: Array[Dictionary] = []
## Each beacon: {enabled, name, url, live}. live also streams packets from the server's /ws feed.
var beacons: Array[Dictionary] = []
## IATA regions to load nodes and traffic for, at most MAX_IATAS. Empty means nothing is fetched.
var selected_iatas := PackedStringArray()
var demo_mode := false
var vertical_exaggeration := 2.0
## How sharp map imagery is; higher detail downloads more tiles. See TerrainMap.TILE_PX.
var map_detail := MapDetail.HIGH

## STANDARD loads the same tiles whatever the screen size; HIGH and ULTRA scale with screen pixels.
enum MapDetail { STANDARD, HIGH, ULTRA }


func _ready() -> void:
	load_config()


func load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		brokers = [default_broker()]
		beacons = [default_beacon()]
		selected_iatas = PackedStringArray()
		return
	brokers.assign(cfg.get_value("sources", "brokers", [default_broker()]))
	beacons.assign(cfg.get_value("sources", "beacons", [default_beacon()]))
	selected_iatas = normalize_iatas(cfg.get_value("filters", "selected_iatas", PackedStringArray()))
	demo_mode = cfg.get_value("app", "demo_mode", false)
	vertical_exaggeration = cfg.get_value("view", "vertical_exaggeration", 2.0)
	map_detail = clampi(cfg.get_value("view", "map_detail", MapDetail.HIGH), MapDetail.STANDARD, MapDetail.ULTRA) as MapDetail
	if cfg.get_value("app", "config_version", 1) < CONFIG_VERSION:
		_migrate()
		save_config()


func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("sources", "brokers", brokers)
	cfg.set_value("sources", "beacons", beacons)
	cfg.set_value("filters", "selected_iatas", selected_iatas)
	cfg.set_value("app", "config_version", CONFIG_VERSION)
	cfg.set_value("app", "demo_mode", demo_mode)
	cfg.set_value("view", "vertical_exaggeration", vertical_exaggeration)
	cfg.set_value("view", "map_detail", map_detail)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		push_error("Could not save config: %s" % error_string(err))


## Version 1 configs point at Sierra Mesh's Beacon and subscribe to every region on GoMesh; move them
## to MeshMapper and per-region topics, keeping anything the user added.
func _migrate() -> void:
	var has_meshmapper := false
	for b in beacons:
		if str(b.get("url", "")).contains("beacon.sierrame.sh"):
			b.url = MESHMAPPER_URL
			b.name = "MeshMapper"
		b.erase("iatas")
		if not b.has("live"):
			b["live"] = str(b.get("url", "")).contains("meshmapper.net")
		has_meshmapper = has_meshmapper or str(b.get("url", "")).contains("meshmapper.net")
	if not has_meshmapper:
		beacons.push_front(default_beacon())
	for b in brokers:
		if str(b.get("url", "")).contains("mqtt.gomesh.dev"):
			b.enabled = false
		if str(b.get("topic", "")) == "meshcore/+/+/packets":
			b.topic = default_broker().topic


func has_regions() -> bool:
	return not selected_iatas.is_empty()


## Selected regions as a comma-separated query value, e.g. "SEA,PDX".
func iatas_query() -> String:
	return ",".join(selected_iatas)


## Splits a broker topic field on commas and repeats every {iata} topic once per selected region.
func expand_topics(template: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in template.split(","):
		var topic := part.strip_edges()
		if topic == "":
			continue
		if topic.contains(IATA_TOKEN):
			for code in selected_iatas:
				out.append(topic.replace(IATA_TOKEN, code))
		else:
			out.append(topic)
	return out


## Upper-cased, de-duplicated, at most MAX_IATAS codes.
static func normalize_iatas(codes) -> PackedStringArray:
	var out := PackedStringArray()
	for c in codes:
		var code := str(c).strip_edges().to_upper()
		if code != "" and not out.has(code) and out.size() < MAX_IATAS:
			out.append(code)
	return out


static func default_broker() -> Dictionary:
	return {
		"enabled": false,
		"name": "GoMesh",
		"url": "wss://mqtt.gomesh.dev",
		"topic": "meshcore/{iata}/+/packets",
		"username": "example_user",
		"password": "password123",
	}


static func default_beacon() -> Dictionary:
	return {
		"enabled": true,
		"name": "MeshMapper",
		"url": MESHMAPPER_URL,
		"live": true,
	}
