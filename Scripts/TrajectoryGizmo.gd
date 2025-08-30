@tool
extends Node3D
class_name TrajectoryGizmo

@export var player_path: NodePath
@export var goal_path: NodePath
@export var goal_local_x_range := Vector2(-1.0, 1.0)
@export var goal_local_y_range := Vector2(-0.5, 1.5)

@export var preview_goal_offset_local := Vector2.ZERO
@export var preview_curve_amount := 0.0
@export_range(0.0, 1.0, 0.01) var anchor_forward_bias := 0.5
@export var anchor_side_offset_max := 2.0

@export var preview_color: Color = Color(0.2, 0.8, 1.0, 1.0)
@export var preview_marker_size: float = 0.06

var _player: Node3D
var _goal: Node3D
var _last_hash := 0
var _gizmo: MeshInstance3D

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(true)

func _process(_dt: float) -> void:
	if not Engine.is_editor_hint():
		return
	if player_path != NodePath(): _player = get_node_or_null(player_path)
	if goal_path != NodePath(): _goal = get_node_or_null(goal_path)

	var h := hash([player_path, goal_path,
		goal_local_x_range, goal_local_y_range,
		preview_goal_offset_local, preview_curve_amount,
		anchor_forward_bias, anchor_side_offset_max
	])
	if h != _last_hash:
		_update_gizmo()
		_last_hash = h

func _update_gizmo() -> void:
	if _player == null or _goal == null:
		return
	var giz := _get_or_make_gizmo()
	var im := ImmediateMesh.new()

	var player_pos := _player.global_transform.origin
	var gxf := _goal.global_transform
	var gx := gxf.basis.x
	var gy := gxf.basis.y
	var g0 := gxf.origin

	var offx := clampf(preview_goal_offset_local.x, goal_local_x_range.x, goal_local_x_range.y)
	var offy := clampf(preview_goal_offset_local.y, goal_local_y_range.x, goal_local_y_range.y)
	var target := g0 + gx * offx + gy * offy

	var forward := (target - player_pos).normalized()
	var right := forward.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.00001: right = Vector3(1,0,0)

	var base_anchor := player_pos.lerp(target, anchor_forward_bias)
	var anchor := base_anchor + right * (preview_curve_amount * anchor_side_offset_max)

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(preview_color)
	_draw_line(im, player_pos, anchor)
	_draw_line(im, anchor, target)
	im.surface_end()

	giz.mesh = im

func _draw_line(im: ImmediateMesh, a: Vector3, b: Vector3) -> void:
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)

func _get_or_make_gizmo() -> MeshInstance3D:
	if _gizmo and is_instance_valid(_gizmo): return _gizmo
	_gizmo = MeshInstance3D.new()
	_gizmo.name = "_PreviewGizmo"
	_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_gizmo)
	_gizmo.owner = get_tree().edited_scene_root
	return _gizmo
