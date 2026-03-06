extends Node

## Stub receiver for Nexus animation markers/events.
## Assign this script to a CHILD node (e.g. "NexusEvents") when animation method call tracks
## target that node path instead of "." (root). Use this when the root has a custom script
## that doesn't implement on_nexus_event. Connect to nexus_event to react to markers.
## Use nexus_event_root.gd when tracks use path "." on the scene root.

signal nexus_event(marker_name: String)

func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)
