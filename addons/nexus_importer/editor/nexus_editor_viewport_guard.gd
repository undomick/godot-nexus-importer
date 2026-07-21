class_name NexusEditorViewportGuard
extends RefCounted

## On Godot 4.7+, pause editor 3D SubViewport updates during tab open/close.
## Avoids renderer_scene_cull / light_culler ERR spam on freed RIDs without extra awaits.

const _VIEWPORT_COUNT := 4

static var _version_resolved: bool = false
static var _needs_3d_pause: bool = false
static var _pause_depth: int = 0
static var _saved_update_modes: Array[int] = []


static func needs_editor_3d_pause() -> bool:
	if not _version_resolved:
		var info := Engine.get_version_info()
		var major := int(info.get("major", 0))
		var minor := int(info.get("minor", 0))
		_needs_3d_pause = major > 4 or (major == 4 and minor >= 7)
		_version_resolved = true
	return _needs_3d_pause


static func push_pause(editor_interface: EditorInterface) -> void:
	if editor_interface == null or not needs_editor_3d_pause():
		return
	if _pause_depth == 0:
		_saved_update_modes.clear()
		for i in _VIEWPORT_COUNT:
			var vp: SubViewport = editor_interface.get_editor_viewport_3d(i)
			if vp == null:
				_saved_update_modes.append(-1)
				continue
			_saved_update_modes.append(int(vp.render_target_update_mode))
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_pause_depth += 1


static func pop_pause(editor_interface: EditorInterface) -> void:
	if editor_interface == null or not needs_editor_3d_pause():
		return
	if _pause_depth <= 0:
		return
	_pause_depth -= 1
	if _pause_depth > 0:
		return
	for i in mini(_saved_update_modes.size(), _VIEWPORT_COUNT):
		var mode: int = _saved_update_modes[i]
		if mode < 0:
			continue
		var vp: SubViewport = editor_interface.get_editor_viewport_3d(i)
		if vp != null:
			vp.render_target_update_mode = mode as SubViewport.UpdateMode
	_saved_update_modes.clear()
