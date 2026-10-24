"""local_runtime/tools/check_builtin_datasets.py: every build refuses to package
the app without the builtin datasets (CIFAR-10 is not in git)."""
import importlib.util
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).parents[2]
_spec = importlib.util.spec_from_file_location(
    "check_builtin_datasets", PROJECT_ROOT / "local_runtime" / "tools" / "check_builtin_datasets.py"
)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


def _dataset(root: Path, name: str, entries=("x.npy", "y.npy")) -> None:
    (root / name).mkdir(parents=True)
    with zipfile.ZipFile(root / name / "train.npz", "w") as archive:
        for entry in entries:
            archive.writestr(entry, b"")


def test_the_app_list_is_read_from_run_manager() -> None:
    names = check.app_dataset_names(PROJECT_ROOT)
    assert "cifar10" in names and "mnist" in names


def test_missing_cifar_fails_with_the_build_command(tmp_path, capsys) -> None:
    for name in check.app_dataset_names(PROJECT_ROOT):
        if name != "cifar10":
            _dataset(tmp_path, name)
    (tmp_path / "cifar10").mkdir()
    (tmp_path / "cifar10" / "meta.json").write_text("{}", encoding="utf-8")

    assert check.main(["--datasets", str(tmp_path), "--project-root", str(PROJECT_ROOT)]) == 1
    message = capsys.readouterr().err
    assert "cifar10" in message
    assert "python local_runtime/tools/build_builtin_datasets.py cifar10" in message
    assert "162 MB" in message


def test_a_folder_without_training_arrays_counts_as_missing(tmp_path) -> None:
    _dataset(tmp_path, "pictures", entries=("val_x.npy",))
    (tmp_path / "broken").mkdir()
    (tmp_path / "broken" / "train.npz").write_bytes(b"not a zip")
    _dataset(tmp_path, "fine")

    assert check.missing_datasets(tmp_path, tmp_path) == ["broken", "pictures"]


def test_complete_datasets_pass(tmp_path) -> None:
    for name in check.app_dataset_names(PROJECT_ROOT):
        _dataset(tmp_path, name, entries=("train_x.npy", "train_y.npy"))

    assert check.main(["--datasets", str(tmp_path), "--project-root", str(PROJECT_ROOT)]) == 0
