extends AnimationPlayer

## Nexus AnimationPlayer: receives marker events and provides get_nexus_markers().
## Method call tracks target this node; connect to nexus_event to react.

signal nexus_event(marker_name: String)

func on_nexus_event(marker_name: String) -> void:
	nexus_event.emit(marker_name)


## Returns markers for the given animation, or current if anim_name is empty.
## Format: [{"name": "footstep", "time": 0.5}, ...]
func get_nexus_markers(anim_name: String = "") -> Array[Dictionary]:
	var name_to_use = anim_name if not anim_name.is_empty() else current_animation
	if name_to_use.is_empty():
		return []
	var anim = get_animation(name_to_use)
	if not anim:
		return []
	return anim.get_meta("nexus_markers", [])
