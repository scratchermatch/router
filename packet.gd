extends Sprite2D

const ICON_CENTER_OFFSET := Vector2(32, 32)

var speed: float = 5000.0
var size_bytes: int = 64

var network: Node2D
var id := -1
var src_id := -1
var dst_id := -1
var response := false
var packet_type: StringName = &"unknown"
var payload: Dictionary = {}
var metadata: Dictionary = {}

# Pathfinding
var path: PackedInt64Array = []
var path_index := 0

# Link transmission state
var waiting_for_link := false
var moving_on_link := false
var current_link_from := -1
var current_link_to := -1


func start_moving() -> void:
	if not network.router_is_alive(src_id):
		on_network_drop()
		return

	if not network.router_is_alive(dst_id):
		on_network_drop()
		return

	global_position = network.get_router_center(src_id)

	var source_router = network.routers[src_id]
	path = source_router.known_graph.get_id_path(src_id, dst_id)

	if path.size() < 2:
		on_network_drop()
		return

	path_index = 1
	_request_next_link()


func _request_next_link() -> void:
	if path_index >= path.size():
		_deliver()
		return

	var next_router_id: int = path[path_index]

	if not network.router_is_alive(next_router_id):
		on_network_drop()
		return

	waiting_for_link = true
	moving_on_link = false

	network.request_link_transmission(
		self,
		path[path_index - 1],
		next_router_id
	)


func _process(delta: float) -> void:
	# A queued packet does not move until its link grants transmission.
	if not moving_on_link:
		return

	if not network.router_is_alive(current_link_from):
		on_network_drop()
		return

	if not network.router_is_alive(current_link_to):
		on_network_drop()
		return

	var target_position: Vector2 = network.get_router_center(current_link_to)

	global_position = global_position.move_toward(
		target_position,
		speed * delta
	)

	if global_position.distance_to(target_position) < 1.0:
		global_position = target_position
		moving_on_link = false

		# The packet has reached the next router.
		if not network.router_is_alive(current_link_to):
			on_network_drop()
			return

		path_index += 1

		if path_index >= path.size():
			_deliver()
		else:
			_request_next_link()


func on_link_transmission_complete(
	from_id: int,
	to_id: int
) -> void:
	# The link finished serializing this packet.
	# It may now travel visually to the next router.
	if not is_inside_tree():
		return

	if not network.router_is_alive(from_id):
		on_network_drop()
		return

	if not network.router_is_alive(to_id):
		on_network_drop()
		return

	current_link_from = from_id
	current_link_to = to_id

	waiting_for_link = false
	moving_on_link = true


func _deliver() -> void:
	if not network.router_is_alive(dst_id):
		on_network_drop()
		return

	network.record_bytes_delivered(size_bytes)

	var destination_router = network.routers[dst_id]
	destination_router.receive_packet(self)

	# The receiver may have created a response packet.
	queue_free()


func on_network_drop(reason: StringName = &"router") -> void:
	if not is_queued_for_deletion():
		match reason:
			&"queue":
				network.record_queue_drop()
			&"router":
				network.record_router_drop()

	waiting_for_link = false
	moving_on_link = false
	queue_free()
