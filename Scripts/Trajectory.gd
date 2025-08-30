extends Node3D
class_name TrajectoryPlanner

signal trajectory_changed(points: Array, control_points: PackedVector3Array)

@export var player_path: NodePath
@export var goal_path: NodePath
@export var cubes_mmi_path: NodePath   # optional; auto-created if empty

# Goal-face selectable range (GOAL local X/Y)
@export var goal_local_x_range := Vector2(-1.0, 1.0)
@export var goal_local_y_range := Vector2(-0.5, 1.5)

# Drag normalization (1 screen = full range)
@export var drag_span_multiplier := Vector2(1.0, 1.0)  # >1 slower, <1 faster

# Curve tuning
@export_range(0.0, 10.0, 0.01) var anchor_offset_max := 2.0
@export_range(0.0, 1.0, 0.01) var anchor_forward_bias := 0.5
@export_range(0.0, 1.0, 0.01) var bezier_handle_strength := 0.65
@export var samples := 40

# Cube trail (only shown while dragging)
@export var cube_size: float = 0.08
@export var cube_color: Color = Color(0.2, 0.8, 1.0, 1.0)

# Physics ball settings
@export var ball_radius: float = 0.12
@export var ball_mass: float = 1.0
@export var ball_bounciness: float = 0.6
@export var ball_friction: float = 0.2
@export var ball_linear_damp: float = 0.0
@export var ball_gravity_scale: float = 1.0      # NEW: let gravity act (1.0 = world default)
@export var ball_speed: float = 10.0             # passed to BallFollower.target_speed
@export var ball_steer_strength: float = 30.0    # passed to BallFollower.steer_strength
@export var initial_boost_speed: float = 8.0     # NEW: initial velocity along first tangent
@export var ball_scene: PackedScene              # optional: your own RigidBody3D scene

var _player: Node3D
var _goal: Node3D
var _mmi: MultiMeshInstance3D
var _box_mesh: BoxMesh

var _dragging := false
var _accum_goal_local := Vector2.ZERO
var _target_world := Vector3.ZERO
var _anchor_world := Vector3.ZERO
var _needs_rebuild := true

var _px_to_local := Vector2.ZERO
var _last_view_size := Vector2.ZERO
var _last_pts: Array[Vector3] = []   # last sampled bezier points

func _ready() -> void:
	_player = get_node(player_path) as Node3D
	_goal = get_node(goal_path) as Node3D

	if cubes_mmi_path != NodePath():
		_mmi = get_node(cubes_mmi_path) as MultiMeshInstance3D
	else:
		_mmi = MultiMeshInstance3D.new()
		_mmi.name = "TrajectoryCubes"
		add_child(_mmi)

	_setup_multimesh()

	# start centered on goal (straight)
	_accum_goal_local = Vector2(
		(goal_local_x_range.x + goal_local_x_range.y) * 0.5,
		(goal_local_y_range.x + goal_local_y_range.y) * 0.5
	)

	_recalc_drag_sensitivity()
	_rebuild()

func _setup_multimesh() -> void:
	if _mmi.multimesh == null:
		_mmi.multimesh = MultiMesh.new()

	_box_mesh = BoxMesh.new()
	_box_mesh.size = Vector3.ONE * cube_size

	var mat := StandardMaterial3D.new()
	mat.albedo_color = cube_color
	mat.unshaded = true
	_box_mesh.material = mat

	var mm: MultiMesh = _mmi.multimesh
	mm.mesh = _box_mesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = 0

func _recalc_drag_sensitivity() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	screen.x = max(screen.x, 1.0)
	screen.y = max(screen.y, 1.0)

	var rx: float = goal_local_x_range.y - goal_local_x_range.x
	var ry: float = goal_local_y_range.y - goal_local_y_range.x
	var mx: float = max(drag_span_multiplier.x, 0.0001)
	var my: float = max(drag_span_multiplier.y, 0.0001)

	_px_to_local.x = (rx / screen.x) / mx
	_px_to_local.y = (ry / screen.y) / my
	_last_view_size = screen

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_needs_rebuild = true
		if not _dragging and _last_pts.size() >= 2:
			_spawn_ball(_last_pts)  # shoot on release

	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var dx: float = motion.relative.x
		var dy: float = motion.relative.y

		_accum_goal_local.x = clampf(
			_accum_goal_local.x + dx * _px_to_local.x,
			goal_local_x_range.x, goal_local_y_range.y
		)
		_accum_goal_local.y = clampf(
			_accum_goal_local.y - dy * _px_to_local.y,  # up = +Y
			goal_local_y_range.x, goal_local_y_range.y
		)
		_needs_rebuild = true

func _process(_dt: float) -> void:
	var now: Vector2 = get_viewport().get_visible_rect().size
	if now != _last_view_size:
		_recalc_drag_sensitivity()

	if _needs_rebuild:
		_rebuild()
		_needs_rebuild = false

func _rebuild() -> void:
	if _player == null or _goal == null or _mmi == null:
		return

	# target on goal face
	var gx: Vector3 = _goal.global_transform.basis.x
	var gy: Vector3 = _goal.global_transform.basis.y
	var g0: Vector3 = _goal.global_transform.origin
	_target_world = g0 + gx * _accum_goal_local.x + gy * _accum_goal_local.y

	# frame & center offset
	var p0: Vector3 = _player.global_transform.origin
	var p3: Vector3 = _target_world
	var chord: Vector3 = p3 - p0
	var fwd: Vector3 = chord.normalized()
	var up: Vector3 = Vector3.UP
	var right: Vector3 = fwd.cross(up).normalized()
	if right.length_squared() < 0.000001:
		right = Vector3(1, 0, 0)

	var cx: float = (goal_local_x_range.x + goal_local_y_range.y) * 0.5  # (typo-safe: see note below)
	var cy: float = (goal_local_y_range.x + goal_local_y_range.y) * 0.5
	var hx: float = max(0.0001, (goal_local_x_range.y - goal_local_x_range.x) * 0.5)
	var hy: float = max(0.0001, (goal_local_y_range.y - goal_local_y_range.x) * 0.5)
	var nx: float = clampf((_accum_goal_local.x - cx) / hx, -1.0, 1.0)
	var ny: float = clampf((_accum_goal_local.y - cy) / hy, -1.0, 1.0)

	var base_anchor: Vector3 = p0.lerp(p3, anchor_forward_bias)
	var anchor_offset: Vector3 = right * (nx * anchor_offset_max) + up * (ny * anchor_offset_max)
	_anchor_world = base_anchor + anchor_offset

	# cubic Bézier control points
	var c1: Vector3 = p0.lerp(_anchor_world, bezier_handle_strength)
	var c2: Vector3 = p3.lerp(_anchor_world, bezier_handle_strength)

	# sample curve
	var pts: Array[Vector3] = []
	pts.resize(samples)
	for i in range(samples):
		var t: float = float(i) / float(max(1, samples - 1))
		pts[i] = _bezier_point(p0, c1, c2, p3, t)
	_last_pts = pts
	emit_signal("trajectory_changed", pts, PackedVector3Array([p0, _anchor_world, p3]))

	# draw cubes only while dragging
	var mm: MultiMesh = _mmi.multimesh
	if _dragging:
		mm.instance_count = samples
		for i in range(samples):
			var origin: Vector3 = pts[i]
			var basis := Basis()
			if i < samples - 1:
				var t2: float = float(i + 1) / float(max(1, samples - 1))
				var tan: Vector3 = _bezier_tangent(p0, c1, c2, p3, t2).normalized()
				if tan.length_squared() > 0.0:
					var forward: Vector3 = -tan
					var up_v: Vector3 = Vector3.UP
					if abs(forward.dot(up_v)) > 0.999:
						up_v = Vector3(0, 0, 1)
					var right_v: Vector3 = up_v.cross(forward).normalized()
					up_v = forward.cross(right_v).normalized()
					basis = Basis(right_v, up_v, forward)
			basis = basis.scaled(Vector3.ONE * cube_size)
			var xf := Transform3D(basis, origin)
			mm.set_instance_transform(i, xf)
	else:
		mm.instance_count = 0

# spawn rigid ball & attach external BallFollower (keeps physics collisions)
func _spawn_ball(pts: Array[Vector3]) -> void:
	if pts.size() < 2:
		return

	var ball: RigidBody3D
	if ball_scene:
		ball = ball_scene.instantiate() as RigidBody3D
	else:
		ball = RigidBody3D.new()
		ball.mass = ball_mass
		ball.linear_damp = ball_linear_damp
		ball.continuous_cd = true

		# visuals
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = ball_radius
		sphere.height = ball_radius * 2.0
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 1, 1, 1)
		sphere.material = mat
		mi.mesh = sphere
		ball.add_child(mi)

		# collision
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = ball_radius
		cs.shape = sph
		ball.add_child(cs)

		# physics material
		var pm := PhysicsMaterial.new()
		pm.bounce = clamp(ball_bounciness, 0.0, 1.0)
		pm.friction = max(0.0, ball_friction)
		ball.physics_material_override = pm

	# position & physics defaults
	ball.global_transform = Transform3D(Basis(), pts[0])
	ball.gravity_scale = ball_gravity_scale          # NEW: turn gravity on
	ball.sleeping = false

	# give it an initial velocity along the first tangent (momentum)
	var first_tangent: Vector3 = (pts[1] - pts[0]).normalized()
	if first_tangent.length_squared() > 0.0:
		ball.linear_velocity = first_tangent * max(initial_boost_speed, 0.0)

	add_child(ball)

	# Requires your BallFollower.gd with: class_name BallFollower
	var follower := BallFollower.new()
	follower.target_speed = ball_speed
	follower.steer_strength = ball_steer_strength
	follower.set_waypoints(pts)
	ball.add_child(follower)

# --- Bézier math ---
func _bezier_point(p0: Vector3, c1: Vector3, c2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	var uu: float = u * u
	var tt: float = t * t
	return ((u * uu) * p0) + ((3.0 * uu * t) * c1) + ((3.0 * u * tt) * c2) + ((tt * t) * p3)

func _bezier_tangent(p0: Vector3, c1: Vector3, c2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	return (3.0 * (u * u)) * (c1 - p0) + (6.0 * u * t) * (c2 - c1) + (3.0 * (t * t)) * (p3 - c2)
