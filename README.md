# Router

Router is a network-routing simulation built with **Godot 4**. It visualizes routers, network links, and packets as they travel through a network. Users can modify the network topology, send requests between routers, and observe packet delivery, network traffic, and performance statistics.

## Features

* **Network generation:** Generate a random network of routers connected by links.
* **Packet routing:** Send packets between routers using the network's routing graph.
* **Multiple packet types:** Simulate ping requests, file requests, and video chunk requests, including their corresponding responses.
* **Network editing:** Add and delete routers, create and remove links, and disable or re-enable routers.
* **Link capacity and queues:** Simulate link transmission times, limited queue capacity, and packet drops when queues are full.
* **Packet animation:** Visualize packets moving between routers.
* **Network statistics:** Track sent and received packets, successful requests, failures, timeouts, queue drops, router drops, throughput, and round-trip time.
* **Event recording:** Record simulation events and export them to a CSV file for further analysis.

## Build/Run Requirements

* Godot Engine 4.x
* A desktop environment capable of running Godot

## Getting Started

Either download the prebuilt binaries for Windows, Linux, or Android, or build the program yourself with Godot:

1. Clone or download this repository.
2. Open the project in Godot 4.
3. Open the main scene configured in the project.
4. Run the project to launch the simulation.

## Using the Simulation

### Network Controls

Use the available interface controls to:

* **Generate Random Graph:** Create a new network topology.
* **Clear All:** Remove the current network contents and packets.
* **Add Router:** Add a router to the network.
* **Link Tool:** Connect two routers.
* **Delete:** Remove a router or link.
* **Disable/Enable Router:** Simulate a router becoming unavailable or returning to service.

The exact available actions depend on the currently selected editing tool.

### Sending Packets

Currently, random packet traffic is generated using the parameters in the bottom toolbar. Configure them to increase or decrease load on the network

### Statistics and Recording

The simulation tracks network activity and displays statistics through the interface. Events can also be recorded and exported to CSV for analysis outside the application.

The default recording path is:

```text
user://packet_recording.csv
```

In Godot, `user://` refers to the application's user data directory, not the project directory. The actual filesystem location depends on the operating system:

Windows:
%APPDATA%\Godot\app_userdata\Packet Storm\

Linux:
~/.local/share/godot/app_userdata/Packet Storm/

Android:
An app-specific sandbox directory in internal or external storage; the exact path depends on the device and export configuration.

## Implementation Overview

Router is implemented in GDScript and uses Godot's 2D scene system.

* **Routers:** Represent network nodes and maintain routing graph information.
* **Packets:** Represent requests and responses, animate through the network, and handle delivery or drop conditions.
* **Network graph:** Uses `AStar2D` to represent router connections and calculate paths.
* **Link simulation:** Models transmission time, active transmissions, and FIFO waiting queues.
* **Simulation loop:** Advances network activity using simulation time and a configurable simulation speed.
* **Event recording:** Stores simulation events and exports them as CSV data.

## AI Disclosure

AI was used in this project in the following ways:

- To answer questions regarding algorithms and technical questions
- To fill out some function and design prototypes, after which each function was manually inspected, fixed, and thoroughly tested
- To strictly type code, and clean code to meet the gdscript style guide

## License and Assets

The project uses third-party icons. Refer to the original asset sources and their applicable licenses for attribution and usage requirements.

The Godot runtime the project was built against contains many open source libraries and its own license. More information can be found at https://godotengine.org/license/

All other code in the project is dedicated to the public domain under CC0

