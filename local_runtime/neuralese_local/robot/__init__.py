"""Neuralese robot export: run a trained ONNX model against a physical robot.

The robot never runs the network. It streams sensor readings to the host over a
link, the host evaluates the ONNX model, and the host streams actuator commands
back. This keeps the child-facing device script tiny and identical across every
model, and keeps inference on a machine that can actually run onnxruntime.

Layout:

- ``platforms``  -- registry of supported robots (sensors, actuators, transports)
- ``config``     -- the input/output mapping dict, its schema and validation
- ``codec``      -- the wire protocol (framing, checksum, sequence numbers)
- ``transport``  -- Serial / TCP / BLE / Loopback links, one interface
- ``bridge``     -- the host control loop that ties link + onnxruntime together
- ``drive``      -- steer + throttle -> left/right motor power (from the prototype)
- ``ir``         -- one description (ports, devices, geometry) of host-driven robots
- ``drivers``    -- host-driven robots behind one interface: the simulated Dummy, replay
- ``virtual_device`` -- the robot side of the protocol, in-process, on top of a driver
- ``profiles``   -- each robot's name and geometry, remembered between sessions
- ``generate``   -- renders the canonical device script for a platform + config
- ``bundle``     -- assembles the exported folder handed to the child
- ``export_robot`` -- ``request.json`` -> ``response.json`` entry for Godot
- ``run_robot``  -- job-dir entry that runs a live bridge for Godot
"""

from __future__ import annotations

PROTOCOL_VERSION = 1

__all__ = ["PROTOCOL_VERSION"]
