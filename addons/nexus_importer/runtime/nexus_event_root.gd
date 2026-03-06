extends Node

## Stub root script for Nexus animation markers/events.
## Assign this script to the scene ROOT when animation method call tracks use path "." (root).
## This avoids "couldn't resolve track" / "Method not found" warnings when the root
## Node3D has no on_nexus_event. Override on_nexus_event or connect to nexus_event to react.
## Use nexus_event_receiver.gd instead when tracks target a dedicated child node (e.g. "NexusEvents").

signal nexus_event(marker_name: String)

func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)
