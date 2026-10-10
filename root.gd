
extends Node2D

@export var num_routers := 100
@export var num_connnections := 3

const ICON_SIZE := Vector2(64, 64)
const ROUTER = preload("uid://c82ko2ojb6hbj")

var rng := RandomNumberGenerator.new()
var routers: Array = []
var astar := AStar2D.new()
var graph_lines := Node2D.new()


func _ready() -> void:
	rng.seed = Time.get_ticks_usec()
	add_child(graph_lines)

	Signals.router_disabled.connect(_on_router_disabled)
	Signals.router_enabled.connect(_on_router_enabled)

	generate_tree()


func clear_graph_lines() -> void:
	for child in graph_lines.get_children():
		graph_lines.remove_child(child)
		child.queue_free()


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
			line.width = 2.0

			# Failed routers turn their connected edges red.
			if astar.is_point_disabled(id) or astar.is_point_disabled(neighbor_id):
				line.default_color = Color.RED
			else:
				line.default_color = Color.GRAY

			graph_lines.add_child(line)

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
		router.init(i)
		router.position = Vector2(
			rng.randi_range(0, 100) * 10,
			rng.randi_range(0, 100) * 10
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
	redraw_graph()


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


func connect_routers(a: int, b: int) -> void:
	if astar.has_point(a) and astar.has_point(b):
		if not astar.are_points_connected(a, b):
			astar.connect_points(a, b)
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
