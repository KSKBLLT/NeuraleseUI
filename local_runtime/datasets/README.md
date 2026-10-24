# FullyLocal Builtin Datasets

## Build CIFAR-10 before running or building the app

The app ships every dataset below. `cifar10/train.npz` (170 MB) is larger than GitHub's 100 MB file limit, so git holds only `cifar10/meta.json`: **each checkout builds it once**, from the repository root:

```powershell
local_runtime\python\python.exe local_runtime\tools\build_builtin_datasets.py
```

With no arguments it builds only the missing datasets. CIFAR-10 is downloaded as the official archive (162 MB, checksum verified) from www.cs.toronto.edu, which can be slow. Any Python with NumPy can run it.

Builds refuse to package the app without it. `local_runtime/tools/check_builtin_datasets.py` exits with an error naming the missing datasets and this command. It runs in `build.ps1`, `tools/build_pruned.ps1`, `tools/build_local_runtime_payload.ps1`, `tools/build_local_runtime_payload.pruned.ps1` and `tools/prepare_windows_installer_payload.ps1` (on the packed copy). The Windows CI workflows (`build-windows-branch`, `release-windows`, `build-managed-msi`) build it, cached, before packaging. Running the app from the editor without it makes CIFAR-10 training fail with the same command.

## Datasets

The Godot frontend advertises these builtin dataset identifiers (`FULLY_LOCAL_DATASET_NAMES` in `scripts/run_manager.gd`):

- `mnist`
- `cifar10` (built per checkout, see above)
- `iris`
- `titanic`
- `car_track`
- `eco_ai`

Each dataset directory must contain either:

- `train.npz` with arrays `x` and `y`, plus optional `val_x` / `val_y` or `test_x` / `test_y`
- or `train_x.npy` and `train_y.npy`, plus optional `val_x.npy` / `val_y.npy` or `test_x.npy` / `test_y.npy`

Arrays are consumed directly by `local_runtime/neuralese_local/dataset_store.py`.

User-created Godot datasets do not live in this directory. When FullyLocal training starts, `scripts/run_manager.gd` converts the raw in-memory dataset table from `glob.dataset_datas[name]` into a temporary uncompressed `godot_json` dataset inside the job directory, then the Python trainer loads it through `load_godot_json_dataset()`.

`mnist`, `cifar10`, `iris`, `titanic` and `eco_ai` can be rebuilt with `python local_runtime/tools/build_builtin_datasets.py <names>`. Only `cifar10` has to be; the others are in git. `--cifar-from` reuses arrays already read from the official archive.

`cifar10` is stored as bytes: `x` is `uint8` of shape `(N, 3, 32, 32)`, channels first as the model reads a colour picture. The trainer keeps it as bytes (184 MB rather than 737 MB of float32) and scales each batch and the validation set to 0..1 (`ArrayDataset(materialize_x=False, x_scale=1/255)` in `dataset_store.py`). Its `train.npz` is larger than GitHub's 100 MB file limit.

`car_track` was converted from Neuralese's legacy single-file LMDB `.ds` dataset format into `local_runtime/datasets/car_track/train.npz`. The conversion reader lives in `local_runtime/neuralese_local/legacy_ds.py`; use it when refreshing the dataset from canonical `.ds` files.
