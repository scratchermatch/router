# Free wifi router icon:
# https://www.flaticon.com/free-icons/wireless-router
# https://www.flaticon.com/free-icons/close

extends TextureButton

var id : int = -1
var router_disabled := false

func init(router_id: int):
	id = router_id

func _on_toggled(toggled_on: bool) -> void:
	if toggled_on:
		Signals.router_disabled.emit(id)
	else:
		Signals.router_enabled.emit(id)
