extends Node

## Shared stub for Nexus animation event method tracks (on_nexus_event).

signal nexus_event(marker_name: String)


func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)
