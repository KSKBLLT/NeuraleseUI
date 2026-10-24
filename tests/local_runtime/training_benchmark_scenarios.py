from __future__ import annotations

from pathlib import Path
from typing import Any


RUNTIME_ROOT = Path(__file__).resolve().parents[2] / "local_runtime"

SCENARIOS = {
    "iris_dense": {
        "dataset": "iris", "inputs": 4, "outputs": 3, "hidden": [16], "loss": "cross_entropy",
    },
    "titanic_dense": {
        "dataset": "titanic", "inputs": 8, "outputs": 2, "hidden": [16], "loss": "cross_entropy",
    },
    "car_dense": {
        "dataset": "car_track", "inputs": 8, "outputs": 2, "hidden": [32, 16], "loss": "mse",
    },
    "mnist_mlp": {
        "dataset": "mnist", "inputs": 784, "outputs": 10, "hidden": [16],
        "loss": "cross_entropy", "image": True,
    },
    "mnist_conv": {
        "dataset": "mnist", "inputs": 784, "outputs": 10, "hidden": [16],
        "loss": "cross_entropy", "image": True, "conv": True,
    },
}


def scenario_graph(scenario: str) -> dict:
    spec = SCENARIOS[scenario]
    inputs = int(spec["inputs"])
    outputs = int(spec["outputs"])
    image = bool(spec.get("image", False))
    conv = bool(spec.get("conv", False))
    nodes: dict[str, Any] = {
        "input": {"type": "InputNode", "data": {"shape": inputs}},
        "output": {"type": "NeuronLayer", "data": {"units": outputs, "activation": "none"}},
    }
    connections: list[dict[str, str]] = []
    previous = "input"
    previous_port = "input_out"
    if image:
        nodes["input"]["data"].update(rows=28, columns=28)
    if conv:
        nodes["conv"] = {
            "type": "conv2d",
            "data": {
                "type": "conv2d", "filters": 4, "window": 3, "stride": 2,
                "keep_size": True, "activation": "relu",
            },
        }
        connections.append(_edge(previous, previous_port, "conv", "layer_in"))
        previous, previous_port = "conv", "layer_out"
    if image:
        nodes["flatten"] = {"type": "Flatten", "data": {}}
        connections.append(_edge(previous, previous_port, "flatten", "layer_in"))
        previous, previous_port = "flatten", "layer_out"
    for index, units in enumerate(spec.get("hidden", [16])):
        node_name = f"hidden_{index}"
        nodes[node_name] = {
            "type": "NeuronLayer",
            "data": {"type": "dense", "units": int(units), "activation": "relu"},
        }
        connections.append(_edge(previous, previous_port, node_name, "layer_in"))
        previous, previous_port = node_name, "layer_out"
    connections.append(_edge(previous, previous_port, "output", "layer_in"))
    return {"nodes": nodes, "connections": connections}


def scenario_request(
    scenario: str,
    root: Path,
    *,
    epochs: int,
    batch_size: int,
    seed: int,
    artifact_cache: Path | None = None,
) -> dict:
    spec = SCENARIOS[scenario]
    return {
        "graph": scenario_graph(scenario),
        "graph_generation": 1,
        "train_graph": _train_graph(str(spec["loss"])),
        "epochs": int(epochs),
        "batch_size": int(batch_size),
        "runtime_root": str(RUNTIME_ROOT),
        "job_dir": str(root / "job"),
        "checkpoint_dir": str(root / "checkpoint"),
        "artifact_cache_dir": str(artifact_cache or root / "artifact-cache"),
        "dataset_ref": {"kind": "builtin_numpy", "name": spec["dataset"]},
        "initialization_seed": int(seed),
    }


def _edge(source: str, source_port: str, target: str, target_port: str) -> dict[str, str]:
    return {"from_node": source, "from_port": source_port, "to_node": target, "to_port": target_port}


def _train_graph(loss: str) -> dict:
    if loss == "mse":
        return {"pages": {"0": {
            "run": {"type": "RunModel", "props": {"config": {"branch_losses": {"output": "mse"}}}},
            "train": {"type": "TrainInput", "props": {"config": {"optimizer": "adam", "lr": 0.001}}},
        }}}
    return {"pages": {"0": {
        "train": {"type": "TrainInput", "props": {"config": {
            "optimizer": "adam", "loss": loss, "lr": 0.001,
        }}},
    }}}
