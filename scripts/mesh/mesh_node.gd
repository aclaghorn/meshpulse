class_name MeshNode
extends RefCounted
## One MeshCore node (repeater, companion, room server or sensor).

enum Type { UNKNOWN, COMPANION, REPEATER, ROOM_SERVER, SENSOR }

const TYPE_NAMES := ["Unknown", "Companion", "Repeater", "Room server", "Sensor"]

## Lowercase hex Ed25519 public key; also the registry key.
var pubkey := ""
var name := ""
var type := Type.UNKNOWN
var lat := 0.0
var lon := 0.0
var has_location := false
## Where the node's dot sits in world space, maintained by NodeMarkers as elevation arrives.
var world := Vector3.ZERO
## "beacon", "advert" (learned live from an ADVERT packet) or "synthetic" (demo mode).
var source := "beacon"


func short_id() -> String:
	return pubkey.substr(0, 8).to_upper()


func display_name() -> String:
	return name if name != "" else short_id()


func type_name() -> String:
	return TYPE_NAMES[type] if type >= 0 and type < TYPE_NAMES.size() else "Unknown"


## Repeaters and room servers forward packets; only they can appear as path hops.
func can_repeat() -> bool:
	return type == Type.REPEATER or type == Type.ROOM_SERVER
