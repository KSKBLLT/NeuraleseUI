from __future__ import annotations

import argparse
import csv
import gzip
import json
import struct
import sys
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1] / "datasets"
sys.path.insert(0, str(ROOT.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from neuralese_local.image_datasets import materialize  # noqa: E402
from check_builtin_datasets import missing_datasets  # noqa: E402


def _download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def _read_mnist_images(blob: bytes) -> np.ndarray:
    raw = gzip.decompress(blob)
    magic, count, rows, cols = struct.unpack(">IIII", raw[:16])
    if magic != 2051:
        raise ValueError(f"Unexpected MNIST image magic: {magic}")
    arr = np.frombuffer(raw, dtype=np.uint8, offset=16)
    arr = arr.reshape(count, 1, rows, cols).astype(np.float32) / 255.0
    return arr


def _read_mnist_labels(blob: bytes) -> np.ndarray:
    raw = gzip.decompress(blob)
    magic, count = struct.unpack(">II", raw[:8])
    if magic != 2049:
        raise ValueError(f"Unexpected MNIST label magic: {magic}")
    return np.frombuffer(raw, dtype=np.uint8, offset=8).astype(np.int64)


def build_mnist() -> None:
    base = ROOT / "mnist"
    base.mkdir(parents=True, exist_ok=True)
    host = "https://storage.googleapis.com/cvdf-datasets/mnist"
    train_x = _read_mnist_images(_download(f"{host}/train-images-idx3-ubyte.gz"))
    train_y = _read_mnist_labels(_download(f"{host}/train-labels-idx1-ubyte.gz"))
    test_x = _read_mnist_images(_download(f"{host}/t10k-images-idx3-ubyte.gz"))
    test_y = _read_mnist_labels(_download(f"{host}/t10k-labels-idx1-ubyte.gz"))
    np.savez_compressed(base / "train.npz", x=train_x, y=train_y, val_x=test_x, val_y=test_y)


def build_iris() -> None:
    base = ROOT / "iris"
    base.mkdir(parents=True, exist_ok=True)
    url = "https://archive.ics.uci.edu/ml/machine-learning-databases/iris/iris.data"
    rows = []
    labels = []
    label_map = {"Iris-setosa": 0, "Iris-versicolor": 1, "Iris-virginica": 2}
    for row in csv.reader(_download(url).decode("utf-8").splitlines()):
        if len(row) != 5:
            continue
        rows.append([float(v) for v in row[:4]])
        labels.append(label_map[row[4]])
    x = np.asarray(rows, dtype=np.float32)
    y = np.asarray(labels, dtype=np.int64)
    rng = np.random.default_rng(42)
    order = rng.permutation(len(x))
    split = int(len(x) * 0.8)
    train_idx, val_idx = order[:split], order[split:]
    np.savez_compressed(base / "train.npz", x=x[train_idx], y=y[train_idx], val_x=x[val_idx], val_y=y[val_idx])


def build_titanic() -> None:
    base = ROOT / "titanic"
    base.mkdir(parents=True, exist_ok=True)
    url = "https://raw.githubusercontent.com/mwaskom/seaborn-data/master/titanic.csv"
    reader = csv.DictReader(_download(url).decode("utf-8").splitlines())
    rows = []
    labels = []
    for row in reader:
        try:
            sex = 1.0 if row["sex"] == "male" else 0.0
            embarked = {"C": 0.0, "Q": 1.0, "S": 2.0}.get(row.get("embarked", ""), 0.0)
            age = float(row["age"]) if row["age"] else 29.7
            fare = float(row["fare"]) if row["fare"] else 0.0
            rows.append([
                float(row["pclass"]),
                sex,
                age / 80.0,
                float(row["sibsp"]),
                float(row["parch"]),
                fare / 512.0,
                embarked,
                1.0 if row.get("alone") == "True" else 0.0,
            ])
            labels.append(int(row["survived"]))
        except Exception:
            continue
    x = np.asarray(rows, dtype=np.float32)
    y = np.asarray(labels, dtype=np.int64)
    rng = np.random.default_rng(42)
    order = rng.permutation(len(x))
    split = int(len(x) * 0.8)
    train_idx, val_idx = order[:split], order[split:]
    np.savez_compressed(base / "train.npz", x=x[train_idx], y=y[train_idx], val_x=x[val_idx], val_y=y[val_idx])


def build_eco_ai() -> None:
    base = ROOT / "eco_ai"
    base.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(42)

    centers = [
        [0.8, 0.9, 0.0, 0.9], # 0: Glass
        [0.8, 0.0, 0.9, 0.9], # 1: Metal
        [0.1, 0.1, 0.0, 0.1], # 2: Paper
        [0.3, 0.4, 0.0, 0.6], # 3: Plastic
    ]
    samples_per_class = 250
    rows = []
    labels = []

    for c_idx, center in enumerate(centers):
        for _ in range(samples_per_class):
            noise = rng.normal(0, 0.1, size=4)
            sample = np.clip(np.array(center) + noise, 0.0, 1.0)
            rows.append(sample)
            labels.append(c_idx)

    x = np.asarray(rows, dtype=np.float32)
    y = np.asarray(labels, dtype=np.int64)

    order = rng.permutation(len(x))
    split = int(len(x) * 0.8)
    train_idx, val_idx = order[:split], order[split:]
    np.savez_compressed(base / "train.npz", x=x[train_idx], y=y[train_idx], val_x=x[val_idx], val_y=y[val_idx])


CIFAR10_CLASSES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]
FASHION_CLASSES = ["T-shirt/top", "Trouser", "Pullover", "Dress", "Coat", "Sandal", "Shirt", "Sneaker", "Bag", "Ankle boot"]


def _write_meta(base: Path, meta: dict) -> None:
    (base / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def build_cifar10(source: Path | None = None) -> None:
    """CIFAR-10 as bytes: x (N, 3, 32, 32) uint8, channels first, which is how
    the model reads a colour picture; training scales each batch to 0..1.
    `source` reuses arrays already read from the official archive (an .npz
    with x, y, val_x, val_y); without it the archive is downloaded and its
    checksum verified."""
    base = ROOT / "cifar10"
    base.mkdir(parents=True, exist_ok=True)
    if source is None:
        (base / "train.npz").unlink(missing_ok=True)
        materialize("cifar10", base)
    else:
        with np.load(source, allow_pickle=False) as arrays:
            x, y, val_x, val_y = (arrays[key] for key in ("x", "y", "val_x", "val_y"))
        if x.dtype != np.uint8 or x.shape[1:] != (3, 32, 32) or val_x.shape[1:] != (3, 32, 32):
            raise ValueError(f"not CIFAR-10 pictures: {x.dtype} {x.shape} / {val_x.shape}")
        if len(x) != 50000 or len(val_x) != 10000 or len(y) != len(x) or len(val_y) != len(val_x):
            raise ValueError("CIFAR-10 has 50 000 training and 10 000 test pictures")
        np.savez_compressed(base / "train.npz", x=x, y=y.astype(np.int64), val_x=val_x, val_y=val_y.astype(np.int64))
    _write_meta(base, {
        "name": "cifar10",
        "size": 60000,
        "inputs": {"x": 32, "y": 32, "channels": 3, "datatype": "2d"},
        "outputs": [{"label": "object", "x": 10, "datatype": "1d", "label_names": CIFAR10_CLASSES}],
        "input_hints": [{"name": "image", "value": "32x32 RGB", "dtype": "image"}],
        "fully_local": True,
        "storage": "numpy",
    })


def build_fashion_mnist() -> None:
    base = ROOT / "fashion_mnist"
    base.mkdir(parents=True, exist_ok=True)
    (base / "train.npz").unlink(missing_ok=True)
    materialize("fashion_mnist", base)
    _write_meta(base, {
        "name": "fashion_mnist",
        "size": 70000,
        "inputs": {"x": 28, "y": 28, "datatype": "2d"},
        "outputs": [{"label": "clothing", "x": 10, "datatype": "1d", "label_names": FASHION_CLASSES}],
        "input_hints": [{"name": "image", "value": "28x28", "dtype": "image"}],
        "fully_local": True,
        "storage": "numpy",
    })


BUILDERS = {
    "mnist": build_mnist,
    "iris": build_iris,
    "titanic": build_titanic,
    "eco_ai": build_eco_ai,
    "cifar10": build_cifar10,
    "fashion_mnist": build_fashion_mnist,
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Write the builtin datasets the app ships. Run it once per checkout before "
                    "building the app: CIFAR-10 is too large for git and is built here.")
    parser.add_argument("names", nargs="*",
                        help="datasets to build, of %s (by default the ones missing)" % ", ".join(BUILDERS))
    parser.add_argument("--cifar-from", type=Path, help="an .npz of CIFAR-10 arrays already read from the official archive")
    args = parser.parse_args()
    unknown = [name for name in args.names if name not in BUILDERS]
    if unknown:
        parser.error("unknown datasets: %s" % ", ".join(unknown))
    names = args.names or [name for name in missing_datasets(ROOT) if name in BUILDERS]
    if not names:
        print(f"Every builtin dataset is already in {ROOT}")
    for name in names:
        if name == "cifar10":
            build_cifar10(args.cifar_from)
        else:
            BUILDERS[name]()
        print(f"{name} written under {ROOT / name}")


if __name__ == "__main__":
    main()

