class_name PacketStyle
extends RefCounted
## Colours and labels per payload type, shared by the animator and the HUD legend.

const COLORS := {
	PacketDecoder.Payload.ADVERT: Color(0.2, 0.85, 1.0),
	PacketDecoder.Payload.GRP_TXT: Color(1.0, 0.3, 0.85),
	PacketDecoder.Payload.TXT_MSG: Color(0.35, 1.0, 0.45),
	PacketDecoder.Payload.TRACE: Color(1.0, 0.82, 0.2),
	PacketDecoder.Payload.ACK: Color(0.92, 0.94, 1.0),
	PacketDecoder.Payload.PATH: Color(1.0, 0.55, 0.15),
	PacketDecoder.Payload.REQ: Color(0.6, 0.5, 1.0),
	PacketDecoder.Payload.RESPONSE: Color(0.6, 0.5, 1.0),
	PacketDecoder.Payload.ANON_REQ: Color(0.6, 0.5, 1.0),
	PacketDecoder.Payload.GRP_DATA: Color(1.0, 0.45, 0.55),
}
const OTHER_COLOR := Color(0.5, 0.7, 1.0)

## Legend rows: [label, payload types].
const LEGEND := [
	["Advert", [PacketDecoder.Payload.ADVERT]],
	["Channel msg", [PacketDecoder.Payload.GRP_TXT, PacketDecoder.Payload.GRP_DATA]],
	["Direct msg", [PacketDecoder.Payload.TXT_MSG]],
	["Trace", [PacketDecoder.Payload.TRACE]],
	["Ack", [PacketDecoder.Payload.ACK]],
	["Path", [PacketDecoder.Payload.PATH]],
	["Request", [PacketDecoder.Payload.REQ, PacketDecoder.Payload.RESPONSE, PacketDecoder.Payload.ANON_REQ]],
]


static func color_for(payload_type: int) -> Color:
	return COLORS.get(payload_type, OTHER_COLOR)
