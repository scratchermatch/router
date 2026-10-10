# Pause/play icons created by Andreas666 - Flaticon
# Fast-forward icons created by khulqi Rosyid - Flaticon
# Fast-forward icons created by Smashicons - Flaticon
# Lines icons created by Dreamstale - Flaticon
# Trash icon from IconArchive

extends Node2D
## Manages network topology, simulation timing, traffic, and statistics.


enum EditMode {
	ADD_ROUTER,
	ADD_LINK,
	DISABLE_ROUTER,
	DELETE,
}

const ICON_SIZE: Vector2 = Vector2(64, 64)
const ROUTER = preload("uid://c82ko2ojb6hbj")
const PACKET = preload("uid://cpmged7yex2li")

# Initial simulation conditions.
var num_routers: int = 100
var num_connnections: int = 3
var min_client_send_delay: float = 0.15
var max_client_send_delay: float = 0.3
var link_capacity_bytes_per_second: float = 10_000_000.0
var max_link_queue_size: int = 3
var default_router_timeout: float = 3.0
var packet_speed: float = 5000.0

# Network state.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var routers: Array = []
var astar: AStar2D = AStar2D.new()
var graph_lines: Node2D = Node2D.new()

# Link states are keyed by "lower_router_id:higher_router_id".
# Each link has one transmitting packet and a FIFO waiting queue.
var link_states: Dictionary = {}

# Measurement configuration and state.
var rtt_window_seconds: float = 10.0
var bandwidth_window_seconds: float = 10.0
var window_bytes_delivered: int = 0
var rtt_samples: Array[Array] = []
var total_rtt: float = 0.0
var successful_rtt_samples: int = 0
var bandwidth_samples: Array[Dictionary] = []

# Aggregate statistics.
var sent: int = 0
var received: int = 0
var successes: int = 0
var failures: int = 0
var timeouts: int = 0
var queue_drops: int = 0
var router_drops: int = 0
var loss_rate: float = 0.0

# Network-wide packet ID allocator.
var next_packet_id: int = 0

# Simulation controls.
var max_sim_speed: float = 3.0
var min_sim_speed: float = 0.1
var sim_speed_step: float = 0.1
var simulation_speed: float = 1.0
var simulation_paused: bool = true
var simulation_time: float = 0.0

# Simulation-time-based traffic generation.
var random_traffic_elapsed: float = 0.0
var next_random_traffic_delay: float = 1.0

# Network editing.
var current_edit_mode: EditMode = EditMode.ADD_ROUTER
var selected_link_router_id: int = -1


## Initializes signals, random state, the graph, and background traffic.
func _ready() -> void:
	Signals.router_disabled.connect(_on_router_disabled)
	Signals.router_enabled.connect(_on_router_enabled)

	rng.seed = Time.get_ticks_usec()

	add_child(graph_lines)
	generate_tree()

	next_random_traffic_delay = rng.randf_range(
		min_client_send_delay,
		max_client_send_delay
	)


## Advances the simulation using a shared, scaled delta.
func _process(delta: float) -> void:
	if simulation_paused:
		return

	var sim_delta: float = delta * simulation_speed
	simulation_time += sim_delta

	_process_link_queues(sim_delta)

	for node: Node in get_tree().get_nodes_in_group("simulation_step"):
		if is_instance_valid(node):
			node.simulation_step(sim_delta)

	random_traffic_elapsed += sim_delta

	while random_traffic_elapsed >= next_random_traffic_delay:
		random_traffic_elapsed -= next_random_traffic_delay
		_spawn_random_traffic()
		next_random_traffic_delay = rng.randf_range(
			min_client_send_delay,
			max_client_send_delay
		)


## Pauses or resumes simulation-time advancement.
func set_simulation_paused(paused: bool) -> void:
	simulation_paused = paused


## Sets the simulation speed, clamped to the supported range.
func set_simulation_speed(speed: float) -> void:
	simulation_speed = clampf(speed, min_sim_speed, max_sim_speed)


## Allocates a unique packet ID for the network.
func allocate_packet_id() -> int:
	var packet_id: int = next_packet_id
	next_packet_id += 1
	return packet_id


## Records a packet dropped because a link queue is full.
func record_queue_drop() -> void:
	queue_drops += 1
	refresh_labels()


## Records a packet dropped because of router or link failure.
func record_router_drop() -> void:
	router_drops += 1
	refresh_labels()


## Returns a consistent key for an undirected link.
func get_link_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


## Creates state for a link if it does not already exist.
func ensure_link_state(a: int, b: int) -> void:
	var key: String = get_link_key(a, b)

	if not link_states.has(key):
		link_states[key] = {
			"a": mini(a, b),
			"b": maxi(a, b),
			"active": null,
			"remaining": 0.0,
			"queue": [],
		}


## Drops in-flight and queued packets when a link is removed.
func remove_link_state(a: int, b: int) -> void:
	var key: String = get_link_key(a, b)

	if not link_states.has(key):
		return

	var link: Dictionary = link_states[key]
	var packets_to_drop: Array = []

	if link["active"] != null:
		packets_to_drop.append(link["active"]["packet"])

	for entry: Dictionary in link["queue"]:
		packets_to_drop.append(entry["packet"])

	link_states.erase(key)

	for packet: Variant in packets_to_drop:
		if is_instance_valid(packet):
			packet.on_network_drop(&"router")


## Drops all active and queued packets associated with a link.
func remove_link_state_by_key(link_key: String) -> void:
	if not link_states.has(link_key):
		return

	var link: Dictionary = link_states[link_key]
	var active_packet: Variant = link.get("active")

	if is_instance_valid(active_packet):
		active_packet.on_network_drop(&"router")

	for packet: Variant in link.get("queue", []):
		if is_instance_valid(packet):
			packet.on_network_drop(&"router")

	link_states.erase(link_key)

## Removes all packets currently in the simulation.
func clear_all_packets() -> void:
	for packet: Node in get_tree().get_nodes_in_group("packet"):
		packet.queue_free()


## Removes all rendered graph edges.
func clear_graph_lines() -> void:
	for child: Node in graph_lines.get_children():
		graph_lines.remove_child(child)
		child.queue_free()


## Returns the center position of a router in world coordinates.
func get_router_center(router_id: int) -> Vector2:
	return routers[router_id].global_position + ICON_SIZE / 2.0


## Refreshes the aggregate statistics displayed in the UI.
func refresh_labels() -> void:
	%SentLabel.text = "Packets Sent: %d" % sent
	%ReceivedLabel.text = "Responses Received: %d" % received
	%SuccessesLabel.text = "Successes: %d" % successes
	%FailuresLabel.text = "Failures: %d" % failures
	%TimeoutsLabel.text = "Timeouts: %d" % timeouts
	%QueueDropsLabel.text = "Queue Drops: %d" % queue_drops
	%RouterDropsLabel.text = "Router Drops: %d" % router_drops

	if successes + failures > 0:
		loss_rate = float(failures) / float(successes + failures) * 100.0
	else:
		loss_rate = 0.0

	%LossRateLabel.text = "Loss Rate: %.2f%%" % loss_rate

	var average_rtt_ms: float = get_average_rtt() * 1000.0
	if rtt_samples.is_empty():
		%AverageRttLabel.text = "Average RTT: --"
	else:
		%AverageRttLabel.text = "Average RTT: %.1f ms" % average_rtt_ms

	var bandwidth: float = get_bandwidth_bytes_per_second()
	%BandwidthLabel.text = "Throughput: " + format_bandwidth(bandwidth)


## Redraws every edge in the actual network topology.
func redraw_graph() -> void:
	clear_graph_lines()

	for router_id: int in astar.get_point_ids():
		for neighbor_id: int in astar.get_point_connections(router_id):
			if router_id >= neighbor_id:
				continue

			var line: Line2D = Line2D.new()
			line.add_point(astar.get_point_position(router_id) + ICON_SIZE / 2.0)
			line.add_point(astar.get_point_position(neighbor_id) + ICON_SIZE / 2.0)
			line.width = 4.0

			if (
				astar.is_point_disabled(router_id)
				or astar.is_point_disabled(neighbor_id)
			):
				line.default_color = Color.RED
			else:
				line.default_color = Color.AQUA

			graph_lines.add_child(line)


## Copies the actual topology into every existing router's knowledge graph.
func initialize_router_knowledge() -> void:
	for router: Variant in routers:
		if router == null or not is_instance_valid(router):
			continue

		router.initialize_knowledge(astar)


## Generates a connected spanning tree using Prim's algorithm.
func generate_spanning_tree() -> void:
	if routers.is_empty():
		return

	var connected: Dictionary = {0: true}
	var remaining: int = routers.size() - 1

	while remaining > 0:
		var best_from: int = -1
		var best_to: int = -1
		var best_distance: float = INF

		for from_id: int in connected:
			var from_router: TextureButton = routers[from_id]

			for to_id: int in range(routers.size()):
				if connected.has(to_id):
					continue

				var to_router: TextureButton = routers[to_id]
				var distance: float = (
					from_router.position.distance_squared_to(to_router.position)
				)

				if distance < best_distance:
					best_distance = distance
					best_from = from_id
					best_to = to_id

		if best_to == -1:
			push_error("Could not connect all routers.")
			return

		astar.connect_points(best_from, best_to)
		ensure_link_state(best_from, best_to)
		connected[best_to] = true
		remaining -= 1


## Generates a random topology with a connected spanning tree and extra links.
func generate_tree() -> void:
	for i: int in range(num_routers):
		var router: TextureButton = ROUTER.instantiate() as TextureButton
		router.init(i, self)
		router.position = Vector2(
			rng.randi_range(0, 100) * 32,
			rng.randi_range(0, 100) * 32
		)

		add_child(router)
		routers.append(router)
		astar.add_point(i, router.position)

	generate_spanning_tree()

	for i: int in range(routers.size()):
		var router: TextureButton = routers[i]
		var neighbors: Array = get_k_nearest_neighbors(
			router,
			num_connnections
		)

		for neighbor: TextureButton in neighbors:
			var neighbor_id: int = neighbor.id
			if not astar.are_points_connected(i, neighbor_id):
				astar.connect_points(i, neighbor_id)
				ensure_link_state(i, neighbor_id)

	initialize_router_knowledge()
	redraw_graph()


## Returns a router's next hop from its local routing knowledge.
func get_known_next_hop(current_router_id: int, destination_id: int) -> int:
	if not router_exists(current_router_id):
		return -1

	var router: Variant = routers[current_router_id]
	return router.get_known_next_hop(destination_id)


## Returns whether a router ID refers to an existing router.
func router_exists(router_id: int) -> bool:
	if router_id < 0 or router_id >= routers.size():
		return false

	var router: Variant = routers[router_id]
	if router == null or not is_instance_valid(router):
		return false

	return astar.has_point(router_id)


## Returns whether a router exists and is enabled.
func router_is_alive(router_id: int) -> bool:
	return router_exists(router_id) and not astar.is_point_disabled(router_id)


## Returns the nearest routers to a given router.
func get_k_nearest_neighbors(router: TextureButton, k: int) -> Array:
	var distances: Dictionary = {}

	for other_router: Variant in routers:
		if other_router == null or other_router == router:
			continue

		distances[other_router] = router.position.distance_squared_to(
			other_router.position
		)

	var nodes: Array = distances.keys()
	nodes.sort_custom(
		func(a: Variant, b: Variant) -> bool:
			return distances[a] < distances[b]
	)

	return nodes.slice(0, mini(k, nodes.size()))


## Finds an actual route between two routers.
func find_route(
	start_router: TextureButton,
	end_router: TextureButton
) -> PackedInt64Array:
	var start_id: int = start_router.id
	var end_id: int = end_router.id

	if not astar.has_point(start_id) or not astar.has_point(end_id):
		return PackedInt64Array()

	if astar.is_point_disabled(start_id) or astar.is_point_disabled(end_id):
		return PackedInt64Array()

	return astar.get_id_path(start_id, end_id)


## Returns the world-space positions along a route.
func get_route_positions(
	start_router: TextureButton,
	end_router: TextureButton
) -> PackedVector2Array:
	var route: PackedInt64Array = find_route(start_router, end_router)
	var positions: PackedVector2Array = PackedVector2Array()

	for point_id: int in route:
		positions.append(astar.get_point_position(point_id) + ICON_SIZE / 2.0)

	return positions


## Requests transmission of a packet over one link.
func request_link_transmission(packet: Node, from_id: int, to_id: int) -> void:
	if not router_exists(from_id) or not router_exists(to_id):
		packet.on_network_drop(&"router")
		return

	if not astar.are_points_connected(from_id, to_id):
		packet.on_network_drop(&"router")
		return

	if not router_is_alive(from_id) or not router_is_alive(to_id):
		packet.on_network_drop(&"router")
		return

	ensure_link_state(from_id, to_id)

	var key: String = get_link_key(from_id, to_id)
	var link: Dictionary = link_states[key]
	var queue: Array = link["queue"]
	var entry: Dictionary = {
		"packet": packet,
		"from": from_id,
		"to": to_id,
	}

	# An idle link can start transmitting immediately, even with a zero queue.
	if link["active"] == null:
		link["active"] = entry
		link["remaining"] = (
			float(maxi(1, packet.size_bytes))
			/ maxf(1.0, link_capacity_bytes_per_second)
		)
		link_states[key] = link
		return

	if queue.size() >= maxi(0, max_link_queue_size):
		packet.on_network_drop(&"queue")
		return

	queue.append(entry)
	link["queue"] = queue
	link_states[key] = link


## Advances all link transmission timers using simulation time.
func _process_link_queues(delta: float) -> void:
	for key: String in link_states.keys():
		if not link_states.has(key):
			continue

		var link: Dictionary = link_states[key]
		var active: Variant = link["active"]

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


## Starts the first valid packet waiting on a link.
func _start_next_link_packet(key: String) -> void:
	if not link_states.has(key):
		return

	var link: Dictionary = link_states[key]
	if link["active"] != null:
		return

	var queue: Array = link["queue"]

	while not queue.is_empty():
		var entry: Dictionary = queue.pop_front()
		var packet: Variant = entry["packet"]

		if not is_instance_valid(packet):
			continue

		link["queue"] = queue
		link["active"] = entry
		link["remaining"] = (
			float(maxi(1, packet.size_bytes))
			/ maxf(1.0, link_capacity_bytes_per_second)
		)
		link_states[key] = link
		return

	link["queue"] = queue
	link_states[key] = link


## Adds a connection between two existing routers.
func connect_routers(a: int, b: int) -> void:
	if not router_exists(a) or not router_exists(b) or a == b:
		return

	if not astar.are_points_connected(a, b):
		astar.connect_points(a, b)
		ensure_link_state(a, b)
		initialize_router_knowledge()
		redraw_graph()


## Removes a connection and drops its active and queued packets.
func disconnect_routers(a: int, b: int) -> void:
	if not astar.has_point(a) or not astar.has_point(b):
		return

	if astar.are_points_connected(a, b):
		remove_link_state(a, b)
		astar.disconnect_points(a, b)
		initialize_router_knowledge()
		redraw_graph()


## Deletes a router while preserving the IDs of all remaining routers.
func delete_router(router_id: int) -> void:
	if not router_exists(router_id):
		return

	for neighbor_id: int in astar.get_point_connections(router_id).duplicate():
		remove_link_state(router_id, neighbor_id)
		astar.disconnect_points(router_id, neighbor_id)

	var router: Variant = routers[router_id]
	astar.remove_point(router_id)

	if is_instance_valid(router):
		router.queue_free()

	routers[router_id] = null
	initialize_router_knowledge()
	redraw_graph()


## Disables a router and marks its connected links as unavailable visually.
func disable_router(router_id: int) -> void:
	if not router_exists(router_id):
		return

	astar.set_point_disabled(router_id, true)
	routers[router_id].set_disabled_state(true)
	redraw_graph()


## Re-enables an existing disabled router.
func enable_router(router_id: int) -> void:
	if not router_exists(router_id):
		return

	astar.set_point_disabled(router_id, false)
	routers[router_id].set_disabled_state(false)
	redraw_graph()


## Handles a router-disabled signal from the Signals singleton.
func _on_router_disabled(router_id: int) -> void:
	disable_router(router_id)


## Handles a router-enabled signal from the Signals singleton.
func _on_router_enabled(router_id: int) -> void:
	enable_router(router_id)


## Records a successful request and its round-trip time.
func record_packet_success(_info: Dictionary, rtt: float) -> void:
	successes += 1
	received += 1
	record_rtt(rtt)
	refresh_labels()


## Records an RTT sample using simulation time.
func record_rtt(rtt: float) -> void:
	rtt_samples.append([simulation_time, rtt])
	total_rtt += rtt
	successful_rtt_samples += 1
	prune_old_rtt_samples()


## Removes RTT samples older than the configured rolling window.
func prune_old_rtt_samples() -> void:
	var cutoff: float = simulation_time - rtt_window_seconds

	while not rtt_samples.is_empty():
		if float(rtt_samples[0][0]) >= cutoff:
			break

		total_rtt -= float(rtt_samples.pop_front()[1])
		successful_rtt_samples -= 1


## Returns the mean RTT of samples still in the rolling window.
func get_average_rtt() -> float:
	prune_old_rtt_samples()

	if rtt_samples.is_empty():
		return 0.0

	return total_rtt / float(rtt_samples.size())


## Records a request failure after its timeout expires.
func record_packet_failure(_info: Dictionary) -> void:
	failures += 1
	refresh_labels()


## Generates one random request between two distinct live routers.
func _spawn_random_traffic() -> void:
	var live_routers: Array[int] = []

	for i: int in range(routers.size()):
		if router_is_alive(i):
			live_routers.append(i)

	if live_routers.size() < 2:
		return

	var source_id: int = live_routers.pick_random()
	var destination_id: int = source_id

	while destination_id == source_id:
		destination_id = live_routers.pick_random()

	var source: Variant = routers[source_id]

	match rng.randi_range(0, 2):
		0:
			source.send_ping(destination_id)
		1:
			source.download_file(
				destination_id,
				"file_%d" % rng.randi_range(1, 5)
			)
		2:
			source.request_video_chunk(
				destination_id,
				"video_%d" % rng.randi_range(1, 3),
				rng.randi_range(0, 20)
			)


## Adds delivered bytes to the throughput measurement window.
func record_bytes_delivered(bytes_count: int) -> void:
	if bytes_count <= 0:
		return

	bandwidth_samples.append({
		"time": simulation_time,
		"bytes": bytes_count,
	})
	window_bytes_delivered += bytes_count
	prune_old_bandwidth_samples()


## Removes delivered-byte samples older than the rolling window.
func prune_old_bandwidth_samples() -> void:
	var cutoff: float = simulation_time - bandwidth_window_seconds

	while not bandwidth_samples.is_empty():
		if float(bandwidth_samples[0]["time"]) >= cutoff:
			break

		var old_sample: Dictionary = bandwidth_samples.pop_front()
		window_bytes_delivered -= int(old_sample["bytes"])


## Returns delivered throughput in bytes per second.
func get_bandwidth_bytes_per_second() -> float:
	prune_old_bandwidth_samples()

	if simulation_time <= 0.0:
		return 0.0

	var elapsed: float = minf(simulation_time, bandwidth_window_seconds)
	if elapsed <= 0.0:
		return 0.0

	return float(window_bytes_delivered) / elapsed


## Formats throughput using decimal byte units.
func format_bandwidth(bytes_per_second: float) -> String:
	if bytes_per_second >= 1_000_000.0:
		return "%.2f MB/s" % (bytes_per_second / 1_000_000.0)
	if bytes_per_second >= 1_000.0:
		return "%.2f KB/s" % (bytes_per_second / 1_000.0)

	return "%.0f B/s" % bytes_per_second


## Decreases simulation speed by one configured step.
func _on_slow_button_pressed() -> void:
	set_simulation_speed(simulation_speed - sim_speed_step)
	%SimSpeedLabel.text = "Current Sim Speed %.1fx" % simulation_speed


## Increases simulation speed by one configured step.
func _on_fast_button_pressed() -> void:
	set_simulation_speed(simulation_speed + sim_speed_step)
	%SimSpeedLabel.text = "Current Sim Speed %.1fx" % simulation_speed


## Updates pause state and its UI label.
func _on_pause_button_toggled(toggled_on: bool) -> void:
	set_simulation_paused(toggled_on)
	if toggled_on:
		%SimPausedLabel.text = "SIMULATION PAUSED"
	else:
		%SimPausedLabel.text = "Simulation Running"


## Handles the two router clicks required to create or remove a link.
func _handle_add_link_click(router_id: int) -> void:
	if selected_link_router_id == -1:
		selected_link_router_id = router_id
		return

	var first_id: int = selected_link_router_id
	selected_link_router_id = -1

	if first_id == router_id:
		return

	if not router_exists(first_id) or not router_exists(router_id):
		return

	if astar.are_points_connected(first_id, router_id):
		disconnect_routers(first_id, router_id)
	else:
		connect_routers(first_id, router_id)


## Dispatches a router click to the currently selected editing tool.
func handle_router_click(router_id: int) -> void:
	if not router_exists(router_id):
		return

	match current_edit_mode:
		EditMode.ADD_ROUTER:
			pass
		EditMode.ADD_LINK:
			_handle_add_link_click(router_id)
		EditMode.DISABLE_ROUTER:
			if router_is_alive(router_id):
				disable_router(router_id)
			else:
				enable_router(router_id)
		EditMode.DELETE:
			delete_router(router_id)


## Adds a router centered at the given world-space position.
func add_router_at(world_position: Vector2) -> void:
	var router_id: int = routers.size()
	var router: TextureButton = ROUTER.instantiate() as TextureButton
	router.init(router_id, self)
	router.position = to_local(world_position) - ICON_SIZE / 2.0

	add_child(router)
	routers.append(router)
	astar.add_point(router_id, router.position)

	initialize_router_knowledge()
	redraw_graph()


## Handles left-clicks on empty canvas for router placement.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if current_edit_mode == EditMode.ADD_ROUTER:
				add_router_at(get_global_mouse_position())


## Selects the minimum random-traffic delay.
func _on_min_send_delay_value_changed(value: float) -> void:
	min_client_send_delay = minf(value, max_client_send_delay)


## Selects the maximum random-traffic delay.
func _on_max_send_delay_value_changed(value: float) -> void:
	max_client_send_delay = maxf(value, min_client_send_delay)


## Updates the default timeout used by new requests.
func _on_router_timeout_value_changed(value: float) -> void:
	default_router_timeout = value


## Updates the bandwidth capacity used by new link transmissions.
func _on_link_capacity_value_changed(value: float) -> void:
	link_capacity_bytes_per_second = maxf(1.0, value)


## Updates the maximum number of waiting packets per link.
func _on_max_link_queue_size_value_changed(value: float) -> void:
	max_link_queue_size = maxi(0, int(value))


## Updates packet animation speed.
func _on_packet_speed_value_changed(value: float) -> void:
	packet_speed = maxf(0.0, value)

## Sets the active editing mode and clears any partial link selection.
func set_edit_mode(mode: EditMode) -> void:
	current_edit_mode = mode
	selected_link_router_id = -1


## Removes all routers, links, and in-flight packets from the network.
func _on_clear_all_button_pressed() -> void:
	clear_all_packets()
	for link_key: String in link_states.keys():
		remove_link_state_by_key(link_key)

	link_states.clear()

	for router: Variant in routers:
		if is_instance_valid(router):
			router.queue_free()

	routers.clear()
	astar.clear()
	initialize_router_knowledge()
	redraw_graph()


## Rebuilds the network with randomly positioned routers and connections.
func _on_random_graph_button_pressed() -> void:
	_on_clear_all_button_pressed()
	generate_tree()


func _on_clear_packets_button_pressed() -> void:
	clear_all_packets()


func _on_add_router_button_pressed() -> void:
	set_edit_mode(EditMode.ADD_ROUTER)


func _on_add_link_button_pressed() -> void:
	set_edit_mode(EditMode.ADD_LINK)


func _on_disable_button_pressed() -> void:
	set_edit_mode(EditMode.DISABLE_ROUTER)


func _on_trash_button_pressed() -> void:
	set_edit_mode(EditMode.DELETE)
