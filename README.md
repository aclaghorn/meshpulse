# Mesh Pulse

A live 3D visualizer for [MeshCore](https://github.com/meshcore-dev/MeshCore) networks, built with Godot 4.7.
Packets streamed over MQTT are decoded, their hop paths resolved to real nodes from a
[MeshCore Beacon](https://github.com/MeshCore-Beacon/beacon-server) server, and animated as glowing
laser trails hopping node to node across satellite imagery draped over real terrain.

## Running

```sh
godot --path .            # or open project.godot in the Godot 4.7 editor and press F5
```

The setup screen lets you configure sources (saved to `user://meshpulse.cfg`):

- **MQTT brokers**: `mqtt://`, `mqtts://`, `ws://` or `wss://` URLs, a topic filter (default
  `meshcore/+/+/packets`) and optional credentials. Messages are expected in
  [meshcore-packet-capture](https://github.com/agessaman/meshcore-packet-capture) JSON format.
- **Beacon servers**: base URL (`/api/v1` is appended) and an optional IATA filter like `SFO,OAK`.
- **Exclude IATAs**: comma-separated IATA codes (wildcards allowed, default `MCI,CAK,MCO,Y*`) whose
  packets are ignored. Beacon nodes heard only in those regions are skipped.
- **Simulated demo traffic**: fake packets over the loaded nodes, or over a synthetic mesh when no
  Beacon is reachable.

Defaults point at `wss://mqtt.gomesh.dev` and `https://beacon.sierrame.sh/`.

Command-line user args: `godot --path . -- --autostart --demo`.

## Controls

| Input | Action |
| --- | --- |
| Left-drag | Pan (animations keep running) |
| Scroll / pinch | Zoom toward cursor; zooming in close tilts into 3D automatically |
| Right-, middle- or Shift+left-drag | Orbit / tilt |
| Click node | Select and show details |
| Double-click node | Fly in to it in 3D |
| `V` | Toggle top-down / 3D |
| `R` | Reset to north-up |
| `F` / Fullscreen button | Fullscreen with all UI hidden (again to exit) |
| `+` / `-` | Zoom |

The packet-type legend on the left doubles as a filter.

On touch screens (Android, iOS, mobile browsers), one finger pans, pinch zooms, twist rotates and a
two-finger vertical drag tilts. On phones the UI switches to a compact layout with a bottom toolbar
that opens the legend, log and sources as drawers. Preview it on desktop with
`godot --path . -- --touch-ui` in a narrow window.

## How it works

```
MQTT (MqttClient) ──► PacketFeed ──► PacketDecoder ──► HopResolver ──► PacketAnimator ──► PacketTrail
                         ▲                                  ▲                │
TrafficSimulator ────────┘                    MeshData ◄────┘                ▼
                                    (Beacon /api/v1/nodes + live adverts)  NodeMarkers (flash, labels)
```

- `scripts/net/mqtt_client.gd`: dependency-free MQTT 3.1.1 subscriber over TCP, TLS and WebSocket,
  with reconnect backoff.
- `scripts/mesh/packet_decoder.gd`: parses the raw packet: header, transport codes, packed
  `path_len` (1–3 byte hop hashes), TRACE routes, ADVERT name/location, and a content hash so the
  same packet heard by several observers is recognised.
- `scripts/mesh/hop_resolver.gd`: maps hop hashes to nodes. Hashes are key prefixes and can
  collide, so ambiguous hops pick the candidate nearest their resolved neighbours. Flood paths are
  `origin → hops → observer`. Direct paths list the hops still ahead (each repeater strips itself),
  so they're drawn from the observer forward and marked *projected*. Trace packets animate only the
  hops already crossed.
- `scripts/viz/packet_animator.gd`: when another observer reports the same packet, only the
  branch where its route diverges is animated, timed to leave the fork node when the first flight
  passed through it.
- `scripts/map/`: Web Mercator world (1 unit = 1 km at the origin, Y = elevation × exaggeration),
  tile streaming with disk cache in `user://tilecache`, and nested LOD terrain. Imagery comes from
  Esri World Imagery and elevation from AWS Terrain Tiles (Terrarium), so no API keys are needed.

## Building

`make` exports with the presets in `export_presets.cfg` into `build/<platform>/`. It needs Godot 4.7
on `PATH` (or `GODOT=/path/to/godot`) with export templates installed.

| Target | Output |
| --- | --- |
| `make macos` | `build/macos/MeshPulse.zip` (universal .app, ad-hoc signed) |
| `make windows` | `build/windows/MeshPulse.exe` + `.pck` |
| `make linux` | `build/linux/MeshPulse.x86_64` + `.pck` |
| `make web` | `build/web/` (no-threads build; `make serve-web` serves it on :8060) |
| `make android` | `build/android/MeshPulse.apk`, debug-signed (`make install-android` installs via adb) |
| `make android-release` | signed release APK using `GODOT_ANDROID_KEYSTORE_RELEASE_PATH/_USER/_PASSWORD` |
| `make all` / `make clean` / `make test` | |

`MODE=debug make linux` makes debug exports. On the web, brokers must use `ws://` or `wss://`, and
every HTTP source must allow CORS. The default Beacon, imagery and elevation hosts all do.

## Tests

```sh
godot --headless --path . -s tests/run_tests.gd          # unit tests (decoder, MQTT framing, resolver, geo)

python3 tools/fake_broker.py --port 18830 --count 4 --interval 0.2 &
godot --headless --path . -s tests/mqtt_live_test.gd     # MQTT client against the fake broker
godot --headless --path . -s tests/mqtt_live_test.gd -- --url=wss://mqtt.gomesh.dev --user=example_user --pass=password123 --min=3

godot --path . -s tests/capture.gd -- --out=/tmp/shots   # windowed run that saves screenshots
```
