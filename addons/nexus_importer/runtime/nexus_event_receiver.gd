extends Node

## Stub receiver for Nexus animation markers/events.
## Animation method call tracks target this node to avoid "Method not found" errors
## when the root Node3D has no on_nexus_event.
## Connect to nexus_event in the root script to react to markers.

signal nexus_event(marker_name: String)

func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)
