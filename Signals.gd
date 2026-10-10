extends Node
## Central signal bus for router state changes.


@warning_ignore_start("unused_signal")

## Emitted when a router becomes disabled.
signal router_disabled(id: int)

## Emitted when a router becomes enabled.
signal router_enabled(id: int)
