extends Sprite2D
## Represents a packet traveling through the simulated network.


const ICON_CENTER_OFFSET: Vector2 = Vector2(32, 32)

var size_bytes: int = 64
var network: Node2D
var id: int = -1
var src_id: int = -1
var dst_id: int = -1
var response: bool = false
var packet_type: StringName = &"unknown"
var payload: Dictionary = {}
var metadata: Dictionary = {}

# Pathfinding state.
var path: PackedInt64Array = []
var path_index: int = 0

# Link transmission state.
var waiting_for_link: bool = false
var moving_on_link: bool = false
var current_link_from: int = -1
var current_link_to: int = -1


## Registers the packet for centralized simulation updates.
func _ready() -> void:
	add_to_group("simulation_step")
	add_to_group("packet")
	set_process(false)


## Finds a route from the source and requests its first link transmission.
func start_moving() -> void:
	if not network.router_is_alive(src_id):
		on_network_drop()
		return

	if not network.router_is_alive(dst_id):
		on_network_drop()
		return

	global_position = network.get_router_center(src_id)

	var source_router: Variant = network.routers[src_id]
	path = source_router.known_graph.get_id_path(src_id, dst_id)

	if path.size() < 2:
		on_network_drop()
		return

	path_index = 1
	_request_next_link()


## Requests transmission on the next hop, or delivers at the destination.
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


## Moves the packet visually while it is traversing an available link.
func simulation_step(delta: float) -> void:
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
		network.packet_speed * delta
	)

	if global_position.distance_to(target_position) < 1.0:
		global_position = target_position
		moving_on_link = false

		if not network.router_is_alive(current_link_to):
			on_network_drop()
			return

		path_index += 1

		if path_index >= path.size():
			_deliver()
		else:
			_request_next_link()


## Begins visual movement after the link finishes transmitting this packet.
func on_link_transmission_complete(from_id: int, to_id: int) -> void:
	if not is_inside_tree():
		return

	if not network.router_is_alive(from_id) or not network.router_is_alive(to_id):
		on_network_drop()
		return

	current_link_from = from_id
	current_link_to = to_id
	waiting_for_link = false
	moving_on_link = true


## Delivers the packet to its destination router and records its bytes.
func _deliver() -> void:
	if not network.router_is_alive(dst_id):
		on_network_drop()
		return
	
	network.log_event("bytes_delivered", {
		"packet_id": id,
		"src_id": src_id,
		"dst_id": dst_id,
		"packet_type": str(packet_type),
		"size_bytes": size_bytes
	})
	network.record_bytes_delivered(size_bytes)

	var destination_router: Variant = network.routers[dst_id]
	destination_router.receive_packet(self)
	queue_free()


## Records the drop reason and removes the packet from the simulation.
func on_network_drop(reason: StringName = &"router") -> void:
	if not is_queued_for_deletion():
		match reason:
			&"queue":
				network.record_queue_drop()
			&"router":
				network.record_router_drop()

	waiting_for_link = false
	moving_on_link = false
	
	network.log_event("packet_dropped", {
		"packet_id": id,
		"src_id": src_id,
		"dst_id": dst_id,
		"packet_type": str(packet_type),
		"size_bytes": size_bytes,
		"reason": str(reason),
		"link_from": current_link_from,
		"link_to": current_link_to
	})
	
	queue_free()
