from __future__ import annotations

from pathlib import Path
import subprocess
import sys

from training_benchmark_scenarios import SCENARIOS, scenario_graph, scenario_request


def test_epoch_benchmark_scenarios_cover_model_families_without_startup_fields(tmp_path: Path):
    assert set(SCENARIOS) == {
        "iris_dense",
        "titanic_dense",
        "car_dense",
        "mnist_mlp",
        "mnist_conv",
    }

    conv_graph = scenario_graph("mnist_conv")
    assert any(node["type"] == "conv2d" for node in conv_graph["nodes"].values())

    request = scenario_request("car_dense", tmp_path, epochs=4, batch_size=256, seed=23)
    assert request["epochs"] == 4
    assert request["batch_size"] == 256
    assert request["initialization_seed"] == 23
    assert request["dataset_ref"]["name"] == "car_track"
    assert "path_class" not in request


def test_startup_benchmark_runs_as_a_direct_script():
    script = Path(__file__).with_name("benchmark_training_startup.py")

    completed = subprocess.run(
        [sys.executable, str(script), "--help"], capture_output=True, text=True
    )

    assert completed.returncode == 0, completed.stderr
