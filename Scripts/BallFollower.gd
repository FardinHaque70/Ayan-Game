extends Node
class_name BallFollower

## Waypoint following
var waypoints: Array[Vector3] = []
var idx: int = 0

@export var target_speed: float = 10.0      # desired speed along path
@export var steer_strength: float = 30.0    # steering force factor
@export var arrive_radius: float = 0.15     # switch to next waypoint when this close

## Collision behavior
@export var stop_on_collision: bool = true
@export var collision_gravity_scale: float = 1.0  # gravity scale to set after first collision

var _following: bool = true
var _rb: RigidBody3D

func set_waypoints(pts: Array[Vector3]) -> void:
	waypoints = pts
	idx = 0
	_following = true

func _ready() -> void:
	_rb = get_parent() as RigidBody3D
	if _rb:
		# Enable contact reporting so we can detect collisions (Godot 4)
		_rb.contact_monitor = true
		_rb.max_contacts_reported = 8  # how many contacts to track

func _physics_process(delta: float) -> void:
	if _rb == null:
		set_physics_process(false)
		return

	# Stop steering on any collision
	if stop_on_collision and _rb.contact_monitor and _rb.get_contact_count() > 0 and _following:
		_stop_following_due_to_collision()
		return

	if not _following:
		return

	if waypoints.is_empty():
		return

	# Advance waypoint if close enough
	var pos: Vector3 = _rb.global_transform.origin
	var target: Vector3 = waypoints[idx]
	var to_target: Vector3 = target - pos
	var dist: float = to_target.length()

	if dist < arrive_radius and idx < waypoints.size() - 1:
		idx += 1
		target = waypoints[idx]
		to_target = target - pos
		dist = to_target.length()

	# If at last point and close, stop following but keep momentum
	if idx == waypoints.size() - 1 and dist < arrive_radius:
		_following = false
		return

	# Steering toward current target point
	if dist > 0.0001:
		var desired_vel: Vector3 = to_target.normalized() * target_speed
		var steer: Vector3 = (desired_vel - _rb.linear_velocity) * steer_strength
		_rb.apply_central_force(steer)

func _stop_following_due_to_collision() -> void:
	_following = false
	# Ensure gravity is ON after collision
	_rb.gravity_scale = collision_gravity_scale
