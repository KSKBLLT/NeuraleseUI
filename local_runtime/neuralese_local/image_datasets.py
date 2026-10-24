"""Picture datasets for local_runtime/tools/build_builtin_datasets.py: verified
downloads of the official files, read into uint8 arrays and written as the
builtin train.npz the app ships. Nothing here runs while training."""
from __future__ import annotations

import gzip
import hashlib
import io
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import urllib.request

import numpy as np

OPTIONAL_DATASETS = {"fashion_mnist", "cifar10"}
FASHION_FILES = {
    "train-images-idx3-ubyte.gz": "8d4fb7e6c68d591d4c3dfef9ec88bf0d",
    "train-labels-idx1-ubyte.gz": "25c81989df183df01b3e8a0aad5dffbe",
    "t10k-images-idx3-ubyte.gz": "bef4ecab320f06d8554ea6380940ec79",
    "t10k-labels-idx1-ubyte.gz": "bb300cfdad3c16e7a12a480ee83cd310",
}


def _download(url: str, checksum: str, limit: int) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Dataset download exceeded its size limit")
    if hashlib.md5(data).hexdigest() != checksum:
        raise ValueError("Dataset checksum mismatch; please retry the download")
    return data


def read_idx(blob: bytes, images: bool) -> np.ndarray:
    data = gzip.decompress(blob)
    header_size = 16 if images else 8
    if len(data) < header_size:
        raise ValueError("Truncated IDX header")
    header = struct.unpack(">IIII" if images else ">II", data[:header_size])
    if header[0] != (2051 if images else 2049):
        raise ValueError("Invalid IDX magic")
    shape = (header[1], 1, header[2], header[3]) if images else (header[1],)
    values = np.frombuffer(data, dtype=np.uint8, offset=header_size)
    if values.size != int(np.prod(shape)):
        raise ValueError("IDX dimensions do not match payload")
    return values.reshape(shape)


def read_cifar_batch(data: bytes) -> tuple[np.ndarray, np.ndarray]:
    if not data or len(data) % 3073:
        raise ValueError("Invalid CIFAR binary batch length")
    rows = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3073)
    if np.any(rows[:, 0] > 9):
        raise ValueError("Invalid CIFAR class label")
    return rows[:, 1:].reshape(-1, 3, 32, 32), rows[:, 0]


def materialize(name: str, destination: Path) -> Path:
    if name not in OPTIONAL_DATASETS:
        raise ValueError(f"Unknown optional image dataset: {name}")
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / "train.npz"
    if target.exists():
        return destination
    if name == "fashion_mnist":
        host = "https://raw.githubusercontent.com/zalandoresearch/fashion-mnist/master/data/fashion"
        arrays = [read_idx(_download(f"{host}/{filename}", checksum, 40_000_000), "images" in filename)
                  for filename, checksum in FASHION_FILES.items()]
        x, y, val_x, val_y = arrays
    else:
        blob = _download("https://www.cs.toronto.edu/~kriz/cifar-10-binary.tar.gz",
                         "c32a1d4ab5d03f1284b67883e8d87530", 180_000_000)
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
            def batch(filename: str) -> tuple[np.ndarray, np.ndarray]:
                member = archive.getmember("cifar-10-batches-bin/" + filename)
                if not member.isfile() or member.size != 30_730_000:
                    raise ValueError("Invalid CIFAR batch member")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError("Missing CIFAR batch")
                return read_cifar_batch(stream.read())
            parts = [batch(f"data_batch_{index}.bin") for index in range(1, 6)]
            x = np.concatenate([part[0] for part in parts])
            y = np.concatenate([part[1] for part in parts])
            val_x, val_y = batch("test_batch.bin")
    if len(x) != len(y) or len(val_x) != len(val_y):
        raise ValueError("Image and label counts differ")
    # Atomic publication: interrupted downloads never look installed. Archives
    # are not kept, extracted to disk, or unpickled. Store bytes, not float32.
    handle, temp_name = tempfile.mkstemp(prefix="dataset-", suffix=".npz", dir=destination)
    os.close(handle)
    try:
        np.savez_compressed(temp_name, x=x, y=y, val_x=val_x, val_y=val_y)
        os.replace(temp_name, target)
    finally:
        Path(temp_name).unlink(missing_ok=True)
    return destination
