extends Node

## Node to monitor for transform (position/rotation). Falls back to parent if unset.
@export var target_node: Node3D

# UI references
var _label_name: Label
var _label_global_pos: Label
var _label_global_rot: Label
var _label_local_pos: Label
var _label_local_rot: Label
var _vbox: VBoxContainer # Container Referenz für die Helper-Funktion

func _ready():
	# Fallback: if no target set, use parent
	if not target_node and get_parent() is Node3D:
		target_node = get_parent()
	
	_build_ui()

func _process(_delta):
	if not is_instance_valid(target_node):
		if _label_name: _label_name.text = "Target: INVALID"
		return

	# Name Update
	_label_name.text = "Target: " + target_node.name

	# Global data (world coordinates)
	var g_pos = target_node.global_position
	var g_rot = target_node.global_rotation_degrees
	_label_global_pos.text = "G-Pos: X:%.4f  Y:%.4f  Z:%.4f" % [g_pos.x, g_pos.y, g_pos.z]
	_label_global_rot.text = "G-Rot: X:%.2f  Y:%.2f  Z:%.2f" % [g_rot.x, g_rot.y, g_rot.z]

	# Local data (relative to parent - important for AnimationPlayer debugging)
	var l_pos = target_node.position
	var l_rot = target_node.rotation_degrees
	_label_local_pos.text = "L-Pos: X:%.4f  Y:%.4f  Z:%.4f" % [l_pos.x, l_pos.y, l_pos.z]
	_label_local_rot.text = "L-Rot: X:%.2f  Y:%.2f  Z:%.2f" % [l_rot.x, l_rot.y, l_rot.z]

func _build_ui():
	# 1. CanvasLayer so it's always on top
	var canvas = CanvasLayer.new()
	add_child(canvas)

	# 2. Panel container for background
	var panel = PanelContainer.new()
	canvas.add_child(panel)

	# Position: top left with some margin
	panel.position = Vector2(20, 20)

	# StyleBox for semi-transparent black background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	style.set_corner_radius_all(5)
	panel.add_theme_stylebox_override("panel", style)
	
	# 3. Layout
	_vbox = VBoxContainer.new()
	panel.add_child(_vbox)
	
	# 4. Create labels
	_label_name = _add_label("Target: ...", Color.CYAN)
	_vbox.add_child(HSeparator.new())
	
	_add_label("GLOBAL (World Space):", Color.GRAY)
	_label_global_pos = _add_label("G-Pos: ...")
	_label_global_rot = _add_label("G-Rot: ...")
	
	_vbox.add_child(HSeparator.new())
	
	_add_label("LOCAL (Animation Space):", Color.GRAY)
	_label_local_pos = _add_label("L-Pos: ...")
	_label_local_rot = _add_label("L-Rot: ...")

func _add_label(text: String, color: Color = Color.WHITE) -> Label:
	var l = Label.new()
	l.text = text
	l.modulate = color
	# Monospace font for better number readability
	l.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(l)
	return l
