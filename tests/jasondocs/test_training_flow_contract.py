from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_run_model_connects_directly_to_train_step() -> None:
    run_model_scene = _read("scenes/run_model.tscn")
    train_step_scene = _read("scenes/train_input.tscn")

    assert 'name="i" parent="connection"' not in run_model_scene
    assert 'get_node("i")' not in _read("scripts/run_m.gd")
    assert '_accepted_datatypes = "model_output"' in train_step_scene
    assert '_accepted_datatypes = "output_mapped"' not in train_step_scene


def test_output_map_is_not_available_or_required() -> None:
    menus = _read("scenes/menus.tscn")
    graph_manager = _read("scripts/graph_manager.gd")
    run_manager = _read("scripts/run_manager.gd")
    local_handlers = _read("local_runtime/neuralese_local/onnx_node_handlers.py")

    assert '"output_map"' not in menus
    assert '"output_map": gload(' not in graph_manager
    assert '"OutputMap": true' not in run_manager
    assert '"OutputMap", "output_map"' not in local_handlers


def test_run_model_still_owns_loss_selection() -> None:
    run_model_scene = _read("scenes/run_model.tscn")
    run_model_script = _read("scripts/run_m.gd")

    assert 'text = "MSE"' in run_model_scene
    assert 'text = "CrossE"' in run_model_scene
    assert '"branch_losses"' in run_model_script
