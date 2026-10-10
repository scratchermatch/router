# https://www.flaticon.com/free-icons/wireless-router
# https://www.flaticon.com/free-icons/close
# Envelope icons created by Atif Arshad - Flaticon
# Email icons created by Magnific - Flaticon
# <a href="https://www.flaticon.com/free-icons/video" title="video icons">Video icons created by Magnific - Flaticon</a>
# <a href="https://www.flaticon.com/free-icons/document" title="document icons">Document icons created by Magnific - Flaticon</a>

extends TextureButton

const PACKET = preload("uid://cpmged7yex2li")

const CLOSED = preload("uid://cdou8xiv46hro")
const OPEN = preload("uid://c8xs4t2dvxpa5")
const LETTER = preload("uid://c8xs4t2dvxpa5")
const MAIL = preload("uid://cdou8xiv46hro")
const YOUTUBE = preload("uid://b6ey3wn3s6red")
const DOCUMENT = preload("uid://e61vw84tttot")

var default_timeout: float = 2.0

var network: Node2D

var id: int = -1
var router_disabled := false
var known_graph := AStar2D.new()

func init(router_id: int, network_ref: Node2D) -> void:
	self_modulate = Color.BLACK
	id = router_id
	network = network_ref

func initialize_knowledge(actual_graph: AStar2D) -> void:
	known_graph.clear()

	# Copy every point, treating all routers as enabled.
	for point_id in actual_graph.get_point_ids():
		known_graph.add_point(
			point_id,
			actual_graph.get_point_position(point_id)
		)

	# Copy every connection.
	for point_id in actual_graph.get_point_ids():
		for neighbor_id in actual_graph.get_point_connections(point_id):
			if point_id < neighbor_id:
				known_graph.connect_points(point_id, neighbor_id)


func get_known_next_hop(destination_id: int) -> int:
	var path := known_graph.get_id_path(id, destination_id)
	if path.size() < 2:
		return -1
	return path[1]

var pending_packets: Dictionary = {}


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
		return -1 # sender is dead

	if not network.router_is_alive(destination_id):
		return -1 # destination is dead

	# The root allocates IDs so they're unique network-wide.
	if packet_id == -1:
		packet_id = network.allocate_packet_id()

	var packet = PACKET.instantiate() as Sprite2D
	packet.network = network
	packet.id = packet_id
	packet.src_id = id
	packet.dst_id = destination_id
	packet.packet_type = packet_type
	packet.payload = payload.duplicate(true)
	packet.response = is_response
	packet.size_bytes = int(payload.get("size_bytes", 64))

	if expects_response and not is_response:
		var effective_timeout := default_timeout
		if timeout > 0.0:
			effective_timeout = timeout

		pending_packets[packet_id] = {
			"remaining": effective_timeout,
			"type": packet_type,
			"destination": destination_id,
			"started_at": network.simulation_time
		}

		network.sent += 1
		network.refresh_labels()
	
	match packet.packet_type:
		&"ping":
			packet.self_modulate = Color.WHITE
			packet.texture = CLOSED
		&"file_request":
			packet.self_modulate = Color.WHITE
			packet.texture = CLOSED
		&"video_chunk_request":
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
			print("Router ", id, " received unknown packet type: ",
				packet.packet_type)


func _handle_ping(packet: Node) -> void:
	# Echo the ping payload back to the original sender.
	send_packet(
		&"ping_response",
		{
			"message": packet.payload.get("message", ""),
			"responder_id": id
		},
		packet.src_id,
		-1.0,
		false, # The reply doesn't expect another response.
		true,  # This is a response packet.
		packet.id
	)


func _handle_file_request(packet: Node) -> void:
	var file_id: String = str(packet.payload.get("file_id", ""))

	if file_id.is_empty():
		push_warning("Router %d received a file request without a file ID." % id)
		return

	# Simulate finding a file and returning its metadata.
	send_packet(
		&"file_response",
		{
			"file_id": file_id,
			"size_bytes": 1024 * 1024,
			"status": "success",
			"server_id": id
		},
		packet.src_id,
		-1.0,
		false,
		true,
		packet.id
	)


func _handle_video_chunk_request(packet: Node) -> void:
	var video_id: String = str(packet.payload.get("video_id", ""))
	var chunk_index: int = int(packet.payload.get("chunk_index", -1))

	if video_id.is_empty() or chunk_index < 0:
		push_warning("Router %d received an invalid video chunk request." % id)
		return

	# Simulate returning one video chunk.
	send_packet(
		&"video_chunk_response",
		{
			"video_id": video_id,
			"chunk_index": chunk_index,
			"size_bytes": 256 * 1024,
			"status": "success",
			"server_id": id
		},
		packet.src_id,
		-1.0,
		false,
		true,
		packet.id
	)

func _on_toggled(toggled_on: bool) -> void:
	router_disabled = not toggled_on

	if not toggled_on:
		Signals.router_enabled.emit(id)
	else:
		Signals.router_disabled.emit(id)

func _process(delta: float) -> void:
	var expired_ids: Array = []

	for packet_id in pending_packets:
		pending_packets[packet_id]["remaining"] -= delta

		if pending_packets[packet_id]["remaining"] <= 0.0:
			expired_ids.append(packet_id)

	for packet_id in expired_ids:
		var info: Dictionary = pending_packets[packet_id]
		pending_packets.erase(packet_id)
		network.timeouts += 1
		network.record_packet_failure(info)

func send_ping(destination_id: int) -> int:
	return send_packet(
		&"ping",
		{"message": "hello"},
		destination_id,
		default_timeout,
		true
	)

func download_file(destination_id: int, file_id: String) -> int:
	return send_packet(
		&"file_request",
		{"file_id": file_id},
		destination_id,
		default_timeout,
		true
	)

func request_video_chunk(destination_id: int, video_id: String, chunk_index: int) -> int:
	return send_packet(
		&"video_chunk_request",
		{
			"video_id": video_id,
			"chunk_index": chunk_index
		},
		destination_id,
		default_timeout,
		true
	)

func handle_packet_response(packet: Node) -> void:
	var packet_id: int = packet.id
	if not pending_packets.has(packet_id):
		# Timed out or unexpected response.
		return

	var info: Dictionary = pending_packets[packet_id]
	pending_packets.erase(packet_id)

	var rtt: float = network.simulation_time - info["started_at"]
	network.record_packet_success(info, rtt)
