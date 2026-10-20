class_name SourceLoader
extends Node
## Loads the node directory from every enabled Beacon server into MeshData (skipping nodes only heard
## in excluded IATAs), falls back to a synthetic mesh in demo mode, and centres the world on the result.

signal status(text: String)


## Returns one warning per Beacon server that failed; loading carries on past failures.
func load_nodes() -> Array[String]:
	MeshData.clear()
	var warnings: Array[String] = []
	var client := BeaconClient.new()
	add_child(client)
	for b in AppConfig.beacons:
		if not b.get("enabled", true) or str(b.get("url", "")) == "":
			continue
		var label: String = b.get("name", "Beacon")
		status.emit("Loading nodes from %s…" % label)
		var on_progress := func(n: int) -> void: status.emit("Loading nodes from %s… %d" % [label, n])
		client.progress.connect(on_progress)
		var res: Dictionary = await client.fetch_nodes(b.url, b.get("iatas", ""))
		client.progress.disconnect(on_progress)
		for item in res.nodes:
			if not AppConfig.is_node_excluded(item.get("iatas", [])):
				MeshData.upsert_from_beacon(item)
		if not res.ok:
			warnings.append("%s: %s" % [label, res.error])
	client.queue_free()

	if MeshData.located_nodes().is_empty() and AppConfig.demo_mode:
		MeshData.generate_synthetic()
	MeshData.set_origin_from_nodes()
	MeshData.loaded = true
	status.emit("%d nodes loaded" % MeshData.nodes.size())
	return warnings
