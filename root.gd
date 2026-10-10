extends Node2D

# Initial simulation conditions
var num_routers := 100
var num_connnections := 3
var min_client_send_delay := 0.01
var max_client_send_delay := 0.1
var link_capacity_bytes_per_second := 10_000_000.0
var max_link_queue_size := 2

# Constants
const ICON_SIZE := Vector2(64, 64)
const ROUTER = preload("uid://c82ko2ojb6hbj")
const PACKET = preload("uid://cpmged7yex2li")

# References
var rng := RandomNumberGenerator.new()
var routers: Array = []
var astar := AStar2D.new()
var graph_lines := Node2D.new()

# Keyed by "lower_router_id:higher_router_id".
# Each link has one packet transmitting and a FIFO waiting queue.
var link_states: Dictionary = {}

# Data config
var rtt_window_seconds := 10.0
var bandwidth_window_seconds := 10.0
var window_bytes_delivered := 0

# Data
var sent := 0
var received := 0
var successes := 0
var failures := 0
var timeouts := 0
var queue_drops := 0
var router_drops := 0
var loss_rate := 0.0
var rtt_samples: Array[Array] = [] # Each entry: [simulation_timestamp, rtt_seconds]
var total_rtt := 0.0
var successful_rtt_samples := 0
var bandwidth_samples: Array[Dictionary] = [] # Each sample contains the arrival time and delivered byte count.

# Global allocator, all packets are unique network wide for advanced tracking
var next_packet_id := 0

# For how long the simulation has been running
var simulation_time := 0.0

func _process(delta: float) -> void:
	simulation_time += delta
	_process_link_queues(delta)

func allocate_packet_id() -> int:
	var packet_id := next_packet_id
	next_packet_id += 1
	return packet_id

func _ready() -> void:
	# Connect signals from routers
	Signals.router_disabled.connect(_on_router_disabled)
	Signals.router_enabled.connect(_on_router_enabled)
	
	# Initialize rng
	rng.seed = Time.get_ticks_usec()
	
	# Initialize graph
	add_child(graph_lines)
	generate_tree()
	
	start_random_traffic()

func record_queue_drop() -> void:
	queue_drops += 1
	refresh_labels()

func record_router_drop() -> void:
	router_drops += 1
	refresh_labels()

func get_link_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]

func ensure_link_state(a: int, b: int) -> void:
	var key := get_link_key(a, b)

	if not link_states.has(key):
		link_states[key] = {
			"a": mini(a, b),
			"b": maxi(a, b),
			"active": null,
			"remaining": 0.0,
			"queue": []
		}

func remove_link_state(a: int, b: int) -> void:
	var key := get_link_key(a, b)

	if not link_states.has(key):
		return

	var link: Dictionary = link_states[key]
	var packets_to_drop: Array = []

	if link["active"] != null:
		packets_to_drop.append(link["active"]["packet"])

	for entry in link["queue"]:
		packets_to_drop.append(entry["packet"])

	link_states.erase(key)

	for packet in packets_to_drop:
		if is_instance_valid(packet):
			packet.on_network_drop(&"router")

func clear_graph_lines() -> void:
	for child in graph_lines.get_children():
		graph_lines.remove_child(child)
		child.queue_free()

func get_router_center(router_id: int) -> Vector2:
	return routers[router_id].global_position + Vector2(32, 32)

func refresh_labels():
	# Binomials
	%SentLabel.text = "Packets Sent: " + str(sent)
	%ReceivedLabel.text = "Responses Received: " + str(received)
	%SuccessesLabel.text = "Successes: " + str(successes)
	%FailuresLabel.text = "Failures: " + str(failures)
	%TimeoutsLabel.text = "Timeouts: " + str(timeouts)
	%QueueDropsLabel.text = "Queue Drops: %d" % queue_drops
	%RouterDropsLabel.text = "Router Drops: %d" % router_drops
	if failures != 0:
		loss_rate = float(failures)/float(successes + failures) * 100
		%LossRateLabel.text = "Loss Rate: %.2f%%" % loss_rate
	else:
		%LossRateLabel.text = "Loss Rate: 0%"
	# RTT
	var average_rtt_ms := get_average_rtt() * 1000.0
	if rtt_samples.is_empty():
		%AverageRttLabel.text = "Average RTT: --"
	else:
		%AverageRttLabel.text = "Average RTT: %.1f ms" % average_rtt_ms
	# Throughput
	var bandwidth := get_bandwidth_bytes_per_second()
	%BandwidthLabel.text = "Throughput: " + format_bandwidth(bandwidth)

func redraw_graph() -> void:
	clear_graph_lines()

	for id in astar.get_point_ids():
		for neighbor_id in astar.get_point_connections(id):
			# Each undirected connection only needs one line.
			if id >= neighbor_id:
				continue

			var line := Line2D.new()
			line.add_point(astar.get_point_position(id) + ICON_SIZE / 2.0)
			line.add_point(astar.get_point_position(neighbor_id) + ICON_SIZE / 2.0)
			line.width = 4.0

			# Failed routers turn their connected edges red.
			if astar.is_point_disabled(id) or astar.is_point_disabled(neighbor_id):
				line.default_color = Color.RED
			else:
				line.default_color = Color.AQUA

			graph_lines.add_child(line)

func initialize_router_knowledge() -> void:
	for router in routers:
		if router == null or not is_instance_valid(router):
			continue

		router.initialize_knowledge(astar)

# i.e. guarantee graph continuity at creating time using Prim's algorhithm
func generate_spanning_tree() -> void:
	var connected := {0: true}
	var remaining := routers.size() - 1

	while remaining > 0:
		var best_from := -1
		var best_to := -1
		var best_distance := INF

		for from_id in connected:
			var from_router = routers[from_id]

			for to_id in range(routers.size()):
				if connected.has(to_id):
					continue

				var to_router = routers[to_id]
				var distance := from_router.position.distance_squared_to(to_router.position) as float

				if distance < best_distance:
					best_distance = distance
					best_from = from_id
					best_to = to_id

		if best_to == -1:
			push_error("Could not connect all routers.")
			return

		astar.connect_points(best_from, best_to)
		connected[best_to] = true
		remaining -= 1

func generate_tree() -> void:
	for i in range(num_routers):
		var router = ROUTER.instantiate() as TextureButton
		router.init(i, self)
		router.position = Vector2(
			rng.randi_range(0, 100) * 32,
			rng.randi_range(0, 100) * 32
		)

		add_child(router)
		routers.append(router)
		astar.add_point(i, router.position)
	
	# All routers have been instantiated and added to AStar2D.
	generate_spanning_tree()

	# Now add your existing nearest-neighbor connections.
	for i in range(routers.size()):
		var r = routers[i]
		var neighbors = get_k_nearest_neighbors(r, num_connnections)

		for neighbor in neighbors:
			var j = neighbor.id
			if not astar.are_points_connected(i, j):
				astar.connect_points(i, j)
	
	initialize_router_knowledge() # each router has a local A* grid
	redraw_graph()

func get_known_next_hop(current_router_id: int, destination_id: int) -> int:
	if not router_exists(current_router_id):
		return -1

	var router = routers[current_router_id]
	return router.get_known_next_hop(destination_id)

func router_exists(router_id: int) -> bool:
	if router_id < 0 or router_id >= routers.size():
		return false

	var router = routers[router_id]
	if router == null or not is_instance_valid(router):
		return false

	return astar.has_point(router_id)

func router_is_alive(router_id: int) -> bool:
	return (
		router_exists(router_id)
		and not astar.is_point_disabled(router_id)
	)

func get_k_nearest_neighbors(r: TextureButton, k: int) -> Array:
	var distances := {}

	for router in routers:
		if router == r:
			continue

		distances[router] = r.position.distance_squared_to(router.position)

	var nodes = distances.keys()
	nodes.sort_custom(func(a, b): return distances[a] < distances[b])

	return nodes.slice(0, mini(k, nodes.size()))


func find_route(start_router: TextureButton, end_router: TextureButton) -> PackedInt64Array:
	var start_id: int = start_router.id
	var end_id: int = end_router.id

	if not astar.has_point(start_id) or not astar.has_point(end_id):
		return PackedInt64Array()

	if astar.is_point_disabled(start_id) or astar.is_point_disabled(end_id):
		return PackedInt64Array()

	return astar.get_id_path(start_id, end_id)


func get_route_positions(start_router: TextureButton, end_router: TextureButton) -> PackedVector2Array:
	var path := find_route(start_router, end_router)
	var positions := PackedVector2Array()

	for point_id in path:
		positions.append(astar.get_point_position(point_id) + ICON_SIZE / 2.0)

	return positions

## For handling bandwidth and queue
func request_link_transmission(packet: Node, from_id: int, to_id: int) -> void:
	var key := get_link_key(from_id, to_id)

	# The connection must still exist in the real topology.
	if not astar.has_point(from_id) or not astar.has_point(to_id):
		packet.on_network_drop()
		return

	if not astar.are_points_connected(from_id, to_id):
		packet.on_network_drop()
		return

	if astar.is_point_disabled(from_id) or astar.is_point_disabled(to_id):
		packet.on_network_drop()
		return

	ensure_link_state(from_id, to_id)

	var link: Dictionary = link_states[key]
	var queue: Array = link["queue"]

	if queue.size() >= max_link_queue_size:
		packet.on_network_drop(&"queue")
		return

	queue.append({
		"packet": packet,
		"from": from_id,
		"to": to_id
	})

	link["queue"] = queue
	_start_next_link_packet(key)

func _process_link_queues(delta: float) -> void:
	for key in link_states.keys():
		var link: Dictionary = link_states[key]
		var active = link["active"]

		if active == null:
			_start_next_link_packet(key)
			continue

		if not is_instance_valid(active["packet"]):
			link["active"] = null
			link["remaining"] = 0.0
			link_states[key] = link
			_start_next_link_packet(key)
			continue

		link["remaining"] = float(link["remaining"]) - delta

		if float(link["remaining"]) <= 0.0:
			var packet: Node = active["packet"]
			var from_id: int = active["from"]
			var to_id: int = active["to"]

			link["active"] = null
			link["remaining"] = 0.0
			link_states[key] = link

			packet.on_link_transmission_complete(from_id, to_id)
			_start_next_link_packet(key)
		else:
			link_states[key] = link


func _start_next_link_packet(key: String) -> void:
	if not link_states.has(key):
		return

	var link: Dictionary = link_states[key]

	if link["active"] != null:
		return

	var queue: Array = link["queue"]

	while not queue.is_empty():
		var entry: Dictionary = queue.pop_front()
		var packet: Node = entry["packet"]

		if not is_instance_valid(packet):
			continue

		link["queue"] = queue
		link["active"] = entry

		var packet_size := maxi(1, int(packet.size_bytes))
		link["remaining"] = (float(packet_size) / link_capacity_bytes_per_second)

		link_states[key] = link
		return

	link["queue"] = queue
	link_states[key] = link

func connect_routers(a: int, b: int) -> void:
	if astar.has_point(a) and astar.has_point(b):
		if not astar.are_points_connected(a, b):
			astar.connect_points(a, b)
			ensure_link_state(a, b)
			redraw_graph()

func disconnect_routers(a: int, b: int) -> void:
	if astar.are_points_connected(a, b):
		astar.disconnect_points(a, b)
		redraw_graph()


func delete_router(router_id: int) -> void:
	if not astar.has_point(router_id):
		return

	# Disconnect all neighbors before deleting the point.
	for neighbor_id in astar.get_point_connections(router_id).duplicate():
		astar.disconnect_points(router_id, neighbor_id)

	astar.remove_point(router_id)

	# Router IDs remain stable; do not renumber the remaining nodes.
	var router = routers[router_id]
	if is_instance_valid(router):
		router.queue_free()

	routers[router_id] = null
	redraw_graph()


func disable_router(router_id: int) -> void:
	if astar.has_point(router_id):
		astar.set_point_disabled(router_id, true)
		redraw_graph()


func enable_router(router_id: int) -> void:
	if astar.has_point(router_id):
		astar.set_point_disabled(router_id, false)
		redraw_graph()

func _on_router_disabled(router_id: int) -> void:
	disable_router(router_id)


func _on_router_enabled(router_id: int) -> void:
	enable_router(router_id)

func record_packet_success(_info: Dictionary, rtt: float) -> void:
	successes += 1
	received += 1

	record_rtt(rtt)
	refresh_labels()

func record_rtt(rtt: float) -> void:
	var timestamp := simulation_time

	rtt_samples.append([timestamp, rtt])
	total_rtt += rtt

	prune_old_rtt_samples()


func prune_old_rtt_samples() -> void:
	var cutoff := simulation_time - rtt_window_seconds

	while not rtt_samples.is_empty():
		if rtt_samples[0][0] >= cutoff:
			break

		total_rtt -= rtt_samples.pop_front()[1]


func get_average_rtt() -> float:
	prune_old_rtt_samples()

	if rtt_samples.is_empty():
		return 0.0

	return total_rtt / rtt_samples.size()

func record_packet_failure(_info: Dictionary) -> void:
	failures += 1
	refresh_labels()

func start_random_traffic() -> void:
	while true:
		await get_tree().create_timer(
			randf_range(min_client_send_delay, max_client_send_delay)
		).timeout

		var live_routers: Array[int] = []

		for i in range(routers.size()):
			if router_is_alive(i):
				live_routers.append(i)

		# Need at least two live routers to send traffic.
		if live_routers.size() < 2:
			continue

		var source_id: int = live_routers.pick_random()
		var destination_id: int = source_id

		while destination_id == source_id:
			destination_id = live_routers.pick_random()

		var source = routers[source_id]

		match randi_range(0, 2):
			0:
				source.send_ping(destination_id)
			1:
				source.download_file(destination_id, "file_%d" % randi_range(1, 5))
			2:
				source.request_video_chunk(
					destination_id,
					"video_%d" % randi_range(1, 3),
					randi_range(0, 20)
				)

func record_bytes_delivered(bytes_count: int) -> void:
	if bytes_count <= 0:
		return

	bandwidth_samples.append({
		"time": simulation_time,
		"bytes": bytes_count
	})

	window_bytes_delivered += bytes_count
	prune_old_bandwidth_samples()


func prune_old_bandwidth_samples() -> void:
	var cutoff := simulation_time - bandwidth_window_seconds

	while not bandwidth_samples.is_empty():
		if bandwidth_samples[0]["time"] >= cutoff:
			break

		var old_sample: Dictionary = bandwidth_samples.pop_front()
		window_bytes_delivered -= int(old_sample["bytes"])


func get_bandwidth_bytes_per_second() -> float:
	prune_old_bandwidth_samples()

	if simulation_time <= 0.0:
		return 0.0

	# Avoid underestimating throughput during the first few seconds.
	var elapsed := minf(simulation_time, bandwidth_window_seconds)

	if elapsed <= 0.0:
		return 0.0

	return float(window_bytes_delivered) / elapsed


func format_bandwidth(bytes_per_second: float) -> String:
	if bytes_per_second >= 1_000_000.0:
		return "%.2f MB/s" % (bytes_per_second / 1_000_000.0)
	elif bytes_per_second >= 1_000.0:
		return "%.2f KB/s" % (bytes_per_second / 1_000.0)

	return "%.0f B/s" % bytes_per_second
