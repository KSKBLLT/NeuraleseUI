"""Expose genuine internal ONNX tensors without changing checkpoint weights."""
import argparse
from pathlib import Path
from neuralese_local.language.model_bundle import load_bundle
from neuralese_local.language.trace_model import ensure_trace_model

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    path, manifest = ensure_trace_model(load_bundle(arguments.model), arguments.output)
    print(path)
