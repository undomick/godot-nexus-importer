extends Node

## Stub root script for Nexus animation markers/events.
## Method call tracks use path "." (root) to avoid "couldn't resolve track" warnings.
## Override on_nexus_event or connect to nexus_event to react to markers.

signal nexus_event(marker_name: String)

func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)
