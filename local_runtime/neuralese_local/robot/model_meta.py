"""Reading a trained model's shape, and running it.

Kept apart from :mod:`.bridge` so the control loop can be tested against a fake
engine with no onnxruntime installed, and so the UI can read a model's arity
(to build the mapping form) without paying for a full inference session.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .errors import ERR_MODEL_NOT_FOUND, ERR_MODEL_UNREADABLE, MissingDependencyError, RobotError


def _flat_size(shape: Sequence[Any]) -> int:
    """Elements per sample: everything after the batch dimension."""
    total = 1
    for dim in list(shape)[1:]:
        if isinstance(dim, int) and dim > 0:
            total *= dim
        else:
            # A symbolic dimension we cannot resolve makes the total a guess
            # rather than a fact, and a wrong guess here would silently
            # mis-shape every frame. Report "unknown" and let validation skip
            # the arity check instead of enforcing a made-up number.
            return 0
    return total


def read_model_meta(model_path: Any) -> Dict[str, Any]:
    """Input/output signature of an ONNX model.

    Uses ``onnx`` alone (no inference session), so it stays cheap enough to call
    every time the mapping screen opens.
    """
    path = Path(model_path)
    if not path.exists():
        raise RobotError("Trained model not found: %s" % path, code=ERR_MODEL_NOT_FOUND)

    try:
        import onnx  # type: ignore
    except ImportError as exc:
        raise MissingDependencyError(
            "Reading the trained model needs the 'onnx' package, which is not "
            "installed in this runtime.",
            details={"package": "onnx"},
        ) from exc

    try:
        model = onnx.load(str(path))
    except Exception as exc:
        raise RobotError("Could not read the trained model: %s" % exc, code=ERR_MODEL_UNREADABLE) from exc

    initializers = {init.name for init in model.graph.initializer}
    inputs = [value for value in model.graph.input if value.name not in initializers]
    if not inputs:
        raise RobotError("The trained model has no inputs.", code=ERR_MODEL_UNREADABLE)

    def dims(value_info) -> List[Any]:
        out: List[Any] = []
        for dim in value_info.type.tensor_type.shape.dim:
            out.append(int(dim.dim_value) if dim.HasField("dim_value") and dim.dim_value > 0 else None)
        return out

    input_shape = dims(inputs[0])
    outputs = list(model.graph.output)
    output_shape = dims(outputs[0]) if outputs else []

    return {
        "input_name": inputs[0].name,
        "input_shape": input_shape,
        "input_size": _flat_size(input_shape),
        "output_names": [out.name for out in outputs],
        "output_shape": output_shape,
        "output_size": _flat_size(output_shape),
        "path": str(path),
    }


class InferenceEngine:
    """Anything that turns a model input vector into a model output vector."""

    def infer(self, values: Sequence[float]) -> List[float]:
        raise NotImplementedError

    def close(self) -> None:
        pass


class OnnxEngine(InferenceEngine):
    """onnxruntime session driving one sample at a time."""

    def __init__(self, model_path: Any, meta: Optional[Dict[str, Any]] = None) -> None:
        try:
            import numpy as np  # type: ignore
            import onnxruntime as ort  # type: ignore
        except ImportError as exc:
            raise MissingDependencyError(
                "Running a model needs 'onnxruntime' and 'numpy', which are not "
                "installed in this runtime.",
                details={"package": "onnxruntime"},
            ) from exc
        self._np = np
        self._session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
        self._input = self._session.get_inputs()[0]
        self.meta = meta or {}
        # Resolve the per-sample shape once. Symbolic dims (batch) become 1.
        self._sample_shape = [
            int(dim) if isinstance(dim, int) and dim > 0 else 1
            for dim in list(self._input.shape)[1:]
        ]

    def infer(self, values: Sequence[float]) -> List[float]:
        array = self._np.asarray(list(values), dtype=self._np.float32)
        expected = 1
        for dim in self._sample_shape:
            expected *= dim
        if self._sample_shape and expected == array.size:
            array = array.reshape([1] + self._sample_shape)
        else:
            array = array.reshape(1, -1)
        result = self._session.run(None, {self._input.name: array})[0]
        return [float(v) for v in self._np.asarray(result).reshape(-1)]

    def close(self) -> None:
        self._session = None


class ConstantEngine(InferenceEngine):
    """Fixed output, for wiring up and demonstrating a link without a model."""

    def __init__(self, output: Sequence[float]) -> None:
        self._output = [float(v) for v in output]

    def infer(self, values: Sequence[float]) -> List[float]:
        return list(self._output)
