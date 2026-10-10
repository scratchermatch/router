## Simple camera controller script written by ChatGPT

extends Camera2D

@export var move_speed: float = 700.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.2
@export var max_zoom: float = 3.0

func _process(delta: float) -> void:
	var direction := Input.get_vector(
		"ui_left", "ui_right",
		"ui_up", "ui_down"
	)
	# Move relative to the camera's world coordinates
	position += direction * move_speed * delta / zoom.x

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_camera(1.0 + zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_camera(1.0 / (1.0 + zoom_speed))

func _zoom_camera(factor: float) -> void:
	var new_zoom := clampf(
		zoom.x * factor,
		min_zoom,
		max_zoom
	)
	zoom = Vector2.ONE * new_zoom
