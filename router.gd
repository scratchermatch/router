# Wireless router and close icons from Flaticon.
# Envelope icons created by Atif Arshad and Magnific - Flaticon.
# Video and document icons created by Magnific - Flaticon.

extends TextureButton
## Represents a router, its local topology knowledge, and pending requests.


const PACKET = preload("uid://cpmged7yex2li")
const CLOSED = preload("uid://cdou8xiv46hro")
const OPEN = preload("uid://c8xs4t2dvxpa5")
const LETTER = preload("uid://c8xs4t2dvxpa5")
const MAIL = preload("uid://cdou8xiv46hro")
const YOUTUBE = preload("uid://b6ey3wn3s6red")
const DOCUMENT = preload("uid://e61vw84tttot")

var network: Node2D
var id: int = -1
var router_disabled: bool = false
var known_graph: AStar2D = AStar2D.new()
var pending_packets: Dictionary = {}


## Registers the router with the centralized simulation and click handler.
func _ready() -> void:
	add_to_group("simulation_step")
	set_process(false)
	toggle_mode = false

	if not pressed.is_connected(_on_pressed):
		pressed.connect(_on_pressed)


## Initializes the router ID, network reference, and default appearance.
func init(router_id: int, network_ref: Node2D) -> void:
	self_modulate = Color.BLACK
	id = router_id
	network = network_ref


## Copies the actual topology into this router's local knowledge graph.
func initialize_knowledge(actual_graph: AStar2D) -> void:
	known_graph.clear()

	for point_id: int in actual_graph.get_point_ids():
		known_graph.add_point(
			point_id,
			actual_graph.get_point_position(point_id)
		)

	for point_id: int in actual_graph.get_point_ids():
		for neighbor_id: int in actual_graph.get_point_connections(point_id):
			if point_id < neighbor_id:
				known_graph.connect_points(point_id, neighbor_id)


## Returns the next hop toward a destination using local knowledge.
func get_known_next_hop(destination_id: int) -> int:
	var path: PackedInt64Array = known_graph.get_id_path(id, destination_id)
	if path.size() < 2:
		return -1

	return path[1]


## Sends a packet and optionally tracks a pending response with a timeout.
func send_packet(
	packet_type: StringName,
	payload: Dictionary,
	destination_id: int,
	timeout: float = -1.0,
	expects_response: bool = true,
	is_response: bool = false,
	packet_id: int = -1
) -> int:
	if not network.router_is_alive(id):
		return -1

	if not network.router_is_alive(destination_id):
		return -1

	if packet_id == -1:
		packet_id = network.allocate_packet_id()

	var packet: Sprite2D = PACKET.instantiate() as Sprite2D
	packet.network = network
	packet.id = packet_id
	packet.src_id = id
	packet.dst_id = destination_id
	packet.packet_type = packet_type
	packet.payload = payload.duplicate(true)
	packet.response = is_response
	packet.size_bytes = int(payload.get("size_bytes", 64))
	
	network.log_event("packet_sent", {
		"packet_id": packet.id,
		"src_id": packet.src_id,
		"dst_id": packet.dst_id,
		"packet_type": str(packet.packet_type),
		"size_bytes": packet.size_bytes
	})
	
	if expects_response and not is_response:
		var effective_timeout: float = network.default_router_timeout
		if timeout > 0.0:
			effective_timeout = timeout

		pending_packets[packet_id] = {
			"remaining": effective_timeout,
			"type": packet_type,
			"destination": destination_id,
			"started_at": network.simulation_time,
		}

		network.sent += 1
		network.refresh_labels()

	match packet.packet_type:
		&"ping", &"file_request", &"video_chunk_request":
			packet.self_modulate = Color.WHITE
			packet.texture = CLOSED
		&"ping_response":
			packet.self_modulate = Color.GREEN
			packet.texture = OPEN
		&"video_chunk_response":
			packet.self_modulate = Color.RED
			packet.texture = YOUTUBE
		&"file_response":
			packet.self_modulate = Color.BLUE
			packet.texture = DOCUMENT

	network.add_child(packet)
	packet.start_moving()
	return packet_id


## Dispatches a received packet to its handler or response tracker.
func receive_packet(packet: Node) -> void:
	if packet.response:
		handle_packet_response(packet)
		return

	match packet.packet_type:
		&"ping":
			_handle_ping(packet)
		&"file_request":
			_handle_file_request(packet)
		&"video_chunk_request":
			_handle_video_chunk_request(packet)
		_:
			print(
				"Router ",
				id,
				" received unknown packet type: ",
				packet.packet_type
			)


## Replies to a ping using the original packet ID.
func _handle_ping(packet: Node) -> void:
	send_packet(
		&"ping_response",
		{
			"message": packet.payload.get("message", ""),
			"responder_id": id,
		},
		packet.src_id,
		-1.0,
		false,
		true,
		packet.id
	)


## Simulates looking up a file and returning its metadata.
func _handle_file_request(packet: Node) -> void:
	var file_id: String = str(packet.payload.get("file_id", ""))

	if file_id.is_empty():
		push_warning("Router %d received a file request without a file ID." % id)
		return

	send_packet(
		&"file_response",
		{
			"file_id": file_id,
			"size_bytes": 1024 * 1024,
			"status": "success",
			"server_id": id,
		},
		packet.src_id,
		-1.0,
		false,
		true,
		packet.id
	)


## Simulates returning a video chunk.
func _handle_video_chunk_request(packet: Node) -> void:
	var video_id: String = str(packet.payload.get("video_id", ""))
	var chunk_index: int = int(packet.payload.get("chunk_index", -1))

	if video_id.is_empty() or chunk_index < 0:
		push_warning("Router %d received an invalid video chunk request." % id)
		return

	send_packet(
		&"video_chunk_response",
		{
			"video_id": video_id,
			"chunk_index": chunk_index,
			"size_bytes": 256 * 1024,
			"status": "success",
			"server_id": id,
		},
		packet.src_id,
		-1.0,
		false,
		true,
		packet.id
	)


## Updates the router's disabled state and its visual appearance.
func set_disabled_state(d: bool) -> void:
	router_disabled = d
	self_modulate = Color.GRAY if disabled else Color.BLACK


## Handles the legacy toggle signal if it is emitted by the scene.
func _on_toggled(toggled_on: bool) -> void:
	router_disabled = not toggled_on

	if network == null:
		return

	if not toggled_on:
		Signals.router_enabled.emit(id)
	else:
		Signals.router_disabled.emit(id)


## Routes a router click to the root's selected editing tool.
func _on_pressed() -> void:
	if network != null:
		network.handle_router_click(id)


## Advances pending request timeouts using simulation time.
func simulation_step(delta: float) -> void:
	var expired_ids: Array[int] = []

	for packet_id: int in pending_packets:
		pending_packets[packet_id]["remaining"] -= delta

		if pending_packets[packet_id]["remaining"] <= 0.0:
			expired_ids.append(packet_id)
			
	
	
	
	for packet_id: int in expired_ids:
		var info: Dictionary = pending_packets[packet_id]
		network.log_event("timeout", {
			"packet_id": packet_id,
			"src_id": id,
			"dst_id": info.get("destination_id", -1),
			"packet_type": str(info.get("type", ""))
		})
		pending_packets.erase(packet_id)
		network.timeouts += 1
		network.record_packet_failure(info)


## Sends a ping request using the configured default timeout.
func send_ping(destination_id: int) -> int:
	return send_packet(
		&"ping",
		{"message": "hello"},
		destination_id,
		network.default_router_timeout,
		true
	)


## Requests a file from another router.
func download_file(destination_id: int, file_id: String) -> int:
	return send_packet(
		&"file_request",
		{"file_id": file_id},
		destination_id,
		network.default_router_timeout,
		true
	)


## Requests a video chunk from another router.
func request_video_chunk(
	destination_id: int,
	video_id: String,
	chunk_index: int
) -> int:
	return send_packet(
		&"video_chunk_request",
		{
			"video_id": video_id,
			"chunk_index": chunk_index,
		},
		destination_id,
		network.default_router_timeout,
		true
	)


## Matches a response to its pending request and records its RTT.
func handle_packet_response(packet: Node) -> void:
	var packet_id: int = packet.id
	if not pending_packets.has(packet_id):
		return

	var info: Dictionary = pending_packets[packet_id]
	pending_packets.erase(packet_id)

	var rtt: float = network.simulation_time - float(info["started_at"])
	
	network.log_event("packet_delivered", {
		"packet_id": packet.id,
		"src_id": packet.src_id,
		"dst_id": packet.dst_id,
		"packet_type": str(packet.packet_type),
		"size_bytes": packet.size_bytes,
		"rtt_seconds": rtt
	})
	
	network.record_packet_success(info, rtt)
