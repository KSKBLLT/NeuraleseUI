"""Neuralese local training runtime.

This package is launched by Godot for FullyLocal training jobs.  It mirrors the
backend ORT training contract closely enough that the frontend can consume the
same progress packets as the WebSocket path.
"""

TRAINING_WORKER_PROTOCOL_VERSION = 1
