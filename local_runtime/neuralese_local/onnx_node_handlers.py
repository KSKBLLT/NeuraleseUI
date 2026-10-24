from __future__ import annotations

from math import ceil
import re
from typing import Any, Callable, Dict, List

import numpy as np
from onnx import TensorProto, helper

from .generated_node_catalog import handler_id_for


NodeHandler = Callable[[Any, str, str, Dict[str, Any], Dict[str, Any], Dict[str, Any]], None]
LayerHandler = Callable[[Any, str, Dict[str, Any], Dict[str, Any]], None]

_NODE_HANDLERS: Dict[str, NodeHandler] = {}
_LAYER_HANDLERS: Dict[str, LayerHandler] = {}

MAX_GRU_SEQUENCE_LENGTH = 128
MAX_GRU_HIDDEN_SIZE = 256


def handles(*node_types: str) -> Callable[[NodeHandler], NodeHandler]:
    def decorator(func: NodeHandler) -> NodeHandler:
        for node_type in node_types:
            _NODE_HANDLERS[node_type] = func
        return func
    return decorator


def handles_layer(*layer_types: str) -> Callable[[LayerHandler], LayerHandler]:
    def decorator(func: LayerHandler) -> LayerHandler:
        for layer_type in layer_types:
            _LAYER_HANDLERS[layer_type] = func
        return func
    return decorator


def get_handler(node_type: str) -> NodeHandler | None:
    handler_id = handler_id_for(str(node_type))
    if handler_id:
        return _NODE_HANDLERS.get(handler_id)
    normalized = re.sub(r"(?<!^)(?=[A-Z])", "_", str(node_type)).lower()
    candidates = (normalized, normalized.removesuffix("_node"))
    return next((_NODE_HANDLERS[key] for key in candidates if key in _NODE_HANDLERS), None)


def _as_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return int(default)


def _as_str(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


@handles("input")
def compile_input(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    shape_val = _as_int(props.get("shape", config.get("shape", 784)), 784)
    rows = _as_int(config.get("rows", -1), -1)
    cols = _as_int(config.get("columns", -1), -1)
    current_shape: List[Any] = ["batch_size", shape_val]
    if rows > 0 and cols > 0:
        channels = _as_int(config.get("channels", 1), 1)
        if channels not in (1, 3):
            raise ValueError("Image input channels must be 1 (grayscale) or 3 (RGB)")
        current_shape = ["batch_size", channels, rows, cols]
    if not any(info.name == "input" for info in ctx.inputs):
        ctx.inputs.append(helper.make_tensor_value_info("input", TensorProto.FLOAT, current_shape))
    ctx.tensor_routing.setdefault(nid, {})["input_out"] = "input"
    ctx.tensor_shapes["input"] = current_shape


@handles("neuron_layer")
def compile_neuron_layer(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    layer_type = _as_str(config.get("type", props.get("type", "dense")), "dense").lower()
    handler = _LAYER_HANDLERS.get(layer_type) or (_LAYER_HANDLERS.get("dense") if layer_type == "" else None)
    if handler is None:
        raise ValueError(f"Unsupported NeuronLayer type '{layer_type}' on node {nid}")
    handler(ctx, nid, props, config)


@handles_layer("dense", "linear", "")
def compile_dense_layer(ctx, nid: str, props: Dict[str, Any], config: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 784])
    in_features = _as_int(incoming_shape[-1], 784)
    out_features = _as_int(config.get("units", props.get("neuron_count", props.get("neuron_amount", 64))), 64)
    w_name = f"w_{nid}"
    b_name = f"b_{nid}"
    output_name = f"tensor_{nid}_layer_out"
    limit = np.sqrt(6.0 / max(1, in_features + out_features))
    w_vals = np.random.uniform(-limit, limit, [out_features, in_features]).astype(np.float32)
    b_vals = np.zeros([out_features], dtype=np.float32)
    ctx.initializers.append(helper.make_tensor(w_name, TensorProto.FLOAT, [out_features, in_features], w_vals.flatten().tolist()))
    ctx.initializers.append(helper.make_tensor(b_name, TensorProto.FLOAT, [out_features], b_vals.tolist()))
    ctx.trainable_params.extend([w_name, b_name])
    ctx.onnx_nodes.append(helper.make_node("Gemm", inputs=[incoming_tensor, w_name, b_name], outputs=[output_name], transB=1, name=f"dense_{nid}"))
    current_shape = [incoming_shape[0], out_features]
    ctx.tensor_shapes[output_name] = current_shape
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = ctx.add_activation(nid, output_name, current_shape, config.get("activation", config.get("activ", "none")))


@handles_layer("conv2d", "convolution2d")
def compile_conv2d_layer(ctx, nid: str, props: Dict[str, Any], config: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 784])
    if len(incoming_shape) == 2:
        features = _as_int(incoming_shape[1], 784)
        side = int(features ** 0.5)
        if side * side != features:
            raise ValueError(f"Conv2D node {nid} received flat feature count {features}, which is not square")
        reshape_out = f"tensor_{nid}_conv_in_reshape"
        shape_tensor = f"shape_tensor_{nid}_conv_in"
        ctx.initializers.append(helper.make_tensor(shape_tensor, TensorProto.INT64, [4], [0, 1, side, side]))
        ctx.onnx_nodes.append(helper.make_node("Reshape", inputs=[incoming_tensor, shape_tensor], outputs=[reshape_out], name=f"reshape_conv_in_{nid}"))
        incoming_tensor = reshape_out
        incoming_shape = ["batch_size", 1, side, side]
        ctx.tensor_shapes[incoming_tensor] = incoming_shape

    in_channels = _as_int(incoming_shape[1], 1)
    out_channels = _as_int(config.get("filters", 16), 16)
    kernel = _as_int(config.get("window", 3), 3)
    stride = _as_int(config.get("stride", config.get("step", 1)), 1)
    keep_size = bool(config.get("keep_size", True))
    w_name = f"w_{nid}"
    b_name = f"b_{nid}"
    output_name = f"tensor_{nid}_layer_out"
    w_shape = [out_channels, in_channels, kernel, kernel]
    limit = np.sqrt(6.0 / max(1, in_channels * kernel * kernel + out_channels * kernel * kernel))
    ctx.initializers.append(helper.make_tensor(w_name, TensorProto.FLOAT, w_shape, np.random.uniform(-limit, limit, w_shape).astype(np.float32).flatten().tolist()))
    ctx.initializers.append(helper.make_tensor(b_name, TensorProto.FLOAT, [out_channels], np.zeros([out_channels], dtype=np.float32).tolist()))
    ctx.trainable_params.extend([w_name, b_name])
    conv_attrs = {"kernel_shape": [kernel, kernel], "strides": [stride, stride]}
    h_in = _as_int(incoming_shape[2], 1)
    w_in = _as_int(incoming_shape[3], 1)
    if keep_size:
        h_out = int(ceil(h_in / max(1, stride)))
        w_out = int(ceil(w_in / max(1, stride)))
        # SAME_UPPER padding written out. onnxruntime-training computes wrong
        # weight gradients for auto_pad=SAME_UPPER (its forward pass is right),
        # which left every image model training badly; explicit pads are exact
        # (tests/local_runtime/test_conv_gradients.py).
        pad_h = max((h_out - 1) * max(1, stride) + kernel - h_in, 0)
        pad_w = max((w_out - 1) * max(1, stride) + kernel - w_in, 0)
        conv_attrs["pads"] = [pad_h // 2, pad_w // 2, pad_h - pad_h // 2, pad_w - pad_w // 2]
    else:
        conv_attrs["pads"] = [0, 0, 0, 0]
        h_out = int((h_in - kernel) // max(1, stride) + 1)
        w_out = int((w_in - kernel) // max(1, stride) + 1)
    ctx.onnx_nodes.append(helper.make_node("Conv", inputs=[incoming_tensor, w_name, b_name], outputs=[output_name], name=f"conv_{nid}", **conv_attrs))
    current_shape = [incoming_shape[0], out_channels, h_out, w_out]
    ctx.tensor_shapes[output_name] = current_shape
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = ctx.add_activation(nid, output_name, current_shape, config.get("activation", "none"))


@handles_layer("maxpool2d")
def compile_maxpool2d_layer(ctx, nid: str, props: Dict[str, Any], config: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 1, 28, 28])
    if len(incoming_shape) != 4:
        raise ValueError(f"MaxPool2D node {nid} expected a 4D tensor, got {incoming_shape}")
    kernel = _as_int(config.get("group", 2), 2)
    output_name = f"tensor_{nid}_layer_out"
    ctx.onnx_nodes.append(helper.make_node("MaxPool", inputs=[incoming_tensor], outputs=[output_name], kernel_shape=[kernel, kernel], strides=[kernel, kernel], name=f"maxpool_{nid}"))
    current_shape = [incoming_shape[0], incoming_shape[1], _as_int(incoming_shape[2], 1) // kernel, _as_int(incoming_shape[3], 1) // kernel]
    ctx.tensor_shapes[output_name] = current_shape
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles_layer("dropout")
def compile_dropout_layer(ctx, nid: str, props: Dict[str, Any], config: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 784])
    p = float(config.get("p", 0.5))
    output_name = f"tensor_{nid}_layer_out"
    ratio_name = f"ratio_{nid}"
    ctx.initializers.append(helper.make_tensor(ratio_name, TensorProto.FLOAT, [], [p]))
    ctx.onnx_nodes.append(helper.make_node("Dropout", inputs=[incoming_tensor, ratio_name], outputs=[output_name], name=f"dropout_{nid}"))
    ctx.tensor_shapes[output_name] = incoming_shape
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("gru_cell")
def compile_gru_cell(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    """Read a Neuralese 1D chain as a scalar sequence through one GRU cell.

    Neuralese layer ports carry ``[batch, chain_length]``.  Until graph ports
    gain a first-class sequence datatype, each number in that chain is one
    scalar time step.  The same GRU cell is applied across the whole chain and
    its final hidden state returns through the normal 1D layer port.
    """
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 784])
    if len(incoming_shape) != 2:
        raise ValueError(f"GRUCell node {nid} expected a 1D layer tensor, got {incoming_shape}")

    chain_length = _as_int(incoming_shape[-1], 784)
    hidden_size = _as_int(config.get("hidden_size", props.get("hidden_size", 16)), 16)
    if chain_length < 1:
        raise ValueError(f"GRUCell node {nid} requires at least one input number")
    if chain_length > MAX_GRU_SEQUENCE_LENGTH:
        raise ValueError(
            f"GRUCell node {nid} received {chain_length} input numbers, but FullyLocal GRU training "
            f"supports at most {MAX_GRU_SEQUENCE_LENGTH} steps. Use a shorter Input1D sequence and "
            "do not connect a flattened image directly to GRUCell."
        )
    if hidden_size < 1:
        raise ValueError(f"GRUCell node {nid} requires hidden_size >= 1, got {hidden_size}")
    if hidden_size > MAX_GRU_HIDDEN_SIZE:
        raise ValueError(
            f"GRUCell node {nid} requested memory size {hidden_size}, but FullyLocal GRU training "
            f"supports at most {MAX_GRU_HIDDEN_SIZE}."
        )

    # ORT Training 1.19 cannot build a valid GRUGrad graph for the standard
    # ONNX GRU operator.  Expanding the same equations into basic operators
    # keeps both inference and local training on the supported code path.
    sequence_axes_name = f"gru_sequence_axes_{nid}"
    output_axes_name = f"gru_output_axes_{nid}"
    split_sequence_name = f"gru_split_sequence_{nid}"
    split_gate_name = f"gru_split_gate_{nid}"
    one_name = f"gru_one_{nid}"
    zero_name = f"gru_zero_{nid}"
    w_zr_name = f"gru_w_zr_{nid}"
    u_zr_name = f"gru_u_zr_{nid}"
    b_zr_name = f"gru_b_zr_{nid}"
    w_n_name = f"gru_w_n_{nid}"
    u_n_name = f"gru_u_n_{nid}"
    b_n_name = f"gru_b_n_{nid}"

    ctx.initializers.extend([
        helper.make_tensor(sequence_axes_name, TensorProto.INT64, [1], [2]),
        helper.make_tensor(output_axes_name, TensorProto.INT64, [1], [1]),
        helper.make_tensor(split_sequence_name, TensorProto.INT64, [chain_length], [1] * chain_length),
        helper.make_tensor(split_gate_name, TensorProto.INT64, [2], [hidden_size, hidden_size]),
        helper.make_tensor(one_name, TensorProto.FLOAT, [], [1.0]),
        helper.make_tensor(zero_name, TensorProto.FLOAT, [], [0.0]),
    ])

    input_limit = np.sqrt(6.0 / max(1, 1 + hidden_size))
    recurrent_limit = np.sqrt(3.0 / max(1, hidden_size))
    parameter_specs = [
        (w_zr_name, [1, 2 * hidden_size], input_limit),
        (u_zr_name, [hidden_size, 2 * hidden_size], recurrent_limit),
        (w_n_name, [1, hidden_size], input_limit),
        (u_n_name, [hidden_size, hidden_size], recurrent_limit),
    ]
    for name, shape, limit in parameter_specs:
        values = np.random.uniform(-limit, limit, shape).astype(np.float32)
        ctx.initializers.append(helper.make_tensor(name, TensorProto.FLOAT, shape, values.flatten().tolist()))
    ctx.initializers.append(
        helper.make_tensor(b_zr_name, TensorProto.FLOAT, [2 * hidden_size], np.zeros([2 * hidden_size], dtype=np.float32).tolist())
    )
    ctx.initializers.append(
        helper.make_tensor(b_n_name, TensorProto.FLOAT, [hidden_size], np.zeros([hidden_size], dtype=np.float32).tolist())
    )
    ctx.trainable_params.extend([w_zr_name, u_zr_name, b_zr_name, w_n_name, u_n_name, b_n_name])

    sequence = f"tensor_{nid}_sequence"
    projected_gates = f"tensor_{nid}_projected_gates"
    projected_gates_biased = f"tensor_{nid}_projected_gates_biased"
    projected_candidates = f"tensor_{nid}_projected_candidates"
    projected_candidates_biased = f"tensor_{nid}_projected_candidates_biased"
    gate_steps = [f"tensor_{nid}_gate_step_{index}" for index in range(chain_length)]
    candidate_steps = [f"tensor_{nid}_candidate_step_{index}" for index in range(chain_length)]

    # Project every scalar input in two batched MatMul operations.  Only the
    # recurrent part remains unrolled, reducing the training graph from
    # roughly 17 to 13 operators per step.
    ctx.onnx_nodes.extend([
        helper.make_node("Unsqueeze", [incoming_tensor, sequence_axes_name], [sequence], name=f"gru_sequence_{nid}"),
        helper.make_node("MatMul", [sequence, w_zr_name], [projected_gates], name=f"gru_project_gates_{nid}"),
        helper.make_node("Add", [projected_gates, b_zr_name], [projected_gates_biased], name=f"gru_bias_projected_gates_{nid}"),
        helper.make_node(
            "Split",
            inputs=[projected_gates_biased, split_sequence_name],
            outputs=gate_steps,
            axis=1,
            name=f"gru_split_projected_gates_{nid}",
        ),
        helper.make_node("MatMul", [sequence, w_n_name], [projected_candidates], name=f"gru_project_candidates_{nid}"),
        helper.make_node("Add", [projected_candidates, b_n_name], [projected_candidates_biased], name=f"gru_bias_projected_candidates_{nid}"),
        helper.make_node(
            "Split",
            inputs=[projected_candidates_biased, split_sequence_name],
            outputs=candidate_steps,
            axis=1,
            name=f"gru_split_projected_candidates_{nid}",
        ),
    ])

    hidden = f"tensor_{nid}_hidden_initial"
    ctx.onnx_nodes.append(helper.make_node("Mul", [candidate_steps[0], zero_name], [hidden], name=f"gru_zero_state_{nid}"))

    for index in range(chain_length):
        prefix = f"tensor_{nid}_step_{index}"
        memory_gates = f"{prefix}_memory_gates"
        gates_sum = f"{prefix}_gates_sum"
        update_pre = f"{prefix}_update_pre"
        reset_pre = f"{prefix}_reset_pre"
        update_gate = f"{prefix}_update"
        reset_gate = f"{prefix}_reset"
        reset_memory = f"{prefix}_reset_memory"
        memory_candidate = f"{prefix}_memory_candidate"
        candidate_sum = f"{prefix}_candidate_sum"
        candidate = f"{prefix}_candidate"
        inverse_update = f"{prefix}_inverse_update"
        candidate_part = f"{prefix}_candidate_part"
        memory_part = f"{prefix}_memory_part"
        next_hidden = f"{prefix}_hidden"

        ctx.onnx_nodes.extend([
            helper.make_node("MatMul", [hidden, u_zr_name], [memory_gates], name=f"gru_memory_gates_{nid}_{index}"),
            helper.make_node("Add", [gate_steps[index], memory_gates], [gates_sum], name=f"gru_add_gates_{nid}_{index}"),
            helper.make_node(
                "Split",
                [gates_sum, split_gate_name],
                [update_pre, reset_pre],
                axis=2,
                name=f"gru_split_gates_{nid}_{index}",
            ),
            helper.make_node("Sigmoid", [update_pre], [update_gate], name=f"gru_update_gate_{nid}_{index}"),
            helper.make_node("Sigmoid", [reset_pre], [reset_gate], name=f"gru_reset_gate_{nid}_{index}"),
            helper.make_node("Mul", [reset_gate, hidden], [reset_memory], name=f"gru_reset_memory_{nid}_{index}"),
            helper.make_node("MatMul", [reset_memory, u_n_name], [memory_candidate], name=f"gru_memory_candidate_{nid}_{index}"),
            helper.make_node("Add", [candidate_steps[index], memory_candidate], [candidate_sum], name=f"gru_add_candidate_{nid}_{index}"),
            helper.make_node("Tanh", [candidate_sum], [candidate], name=f"gru_candidate_{nid}_{index}"),
            helper.make_node("Sub", [one_name, update_gate], [inverse_update], name=f"gru_inverse_update_{nid}_{index}"),
            helper.make_node("Mul", [inverse_update, candidate], [candidate_part], name=f"gru_candidate_part_{nid}_{index}"),
            helper.make_node("Mul", [update_gate, hidden], [memory_part], name=f"gru_memory_part_{nid}_{index}"),
            helper.make_node("Add", [candidate_part, memory_part], [next_hidden], name=f"gru_hidden_{nid}_{index}"),
        ])
        hidden = next_hidden

    output_name = f"tensor_{nid}_layer_out"
    ctx.onnx_nodes.append(helper.make_node("Squeeze", [hidden, output_axes_name], [output_name], name=f"gru_output_{nid}"))
    current_shape = [incoming_shape[0], hidden_size]
    ctx.tensor_shapes[output_name] = current_shape
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("softmax")
def compile_softmax(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    if nid in ctx.disabled_softmax_nodes:
        ctx.tensor_shapes[incoming_tensor] = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 10])
        ctx.tensor_routing.setdefault(nid, {})["soft_out"] = incoming_tensor
        ctx.tensor_routing.setdefault(nid, {})["layer_out"] = incoming_tensor
        return
    output_name = f"tensor_{nid}_soft_out"
    ctx.onnx_nodes.append(helper.make_node("Softmax", inputs=[incoming_tensor], outputs=[output_name], axis=1, name=f"softmax_{nid}"))
    ctx.tensor_shapes[output_name] = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 10])
    ctx.tensor_routing.setdefault(nid, {})["soft_out"] = output_name
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("flatten")
def compile_flatten(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 1, 28, 28])
    output_name = f"tensor_{nid}_layer_out"
    ctx.onnx_nodes.append(helper.make_node("Flatten", inputs=[incoming_tensor], outputs=[output_name], axis=1, name=f"flatten_{nid}"))
    ctx.tensor_shapes[output_name] = [incoming_shape[0], int(np.prod(incoming_shape[1:]))]
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("reshape2d")
def compile_reshape2d(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "layer_in", "model_in")
    incoming_shape = ctx.tensor_shapes.get(incoming_tensor, ["batch_size", 784])
    rows = _as_int(config.get("rows", -1), -1)
    cols = _as_int(config.get("columns", -1), -1)
    features = _as_int(incoming_shape[1] if len(incoming_shape) == 2 else int(np.prod(incoming_shape[1:])), 784)
    if rows <= 0 and cols <= 0:
        rows = int(features ** 0.5)
        cols = features // max(1, rows)
    elif rows <= 0:
        rows = features // max(1, cols)
    elif cols <= 0:
        cols = features // max(1, rows)
    elif rows * cols != features:
        raise ValueError(f"Reshape2D node {nid} cannot reshape {features} features to {rows}x{cols}")
    output_name = f"tensor_{nid}_layer_out"
    shape_name = f"shape_tensor_{nid}"
    ctx.initializers.append(helper.make_tensor(shape_name, TensorProto.INT64, [4], [0, 1, rows, cols]))
    ctx.onnx_nodes.append(helper.make_node("Reshape", inputs=[incoming_tensor, shape_name], outputs=[output_name], name=f"reshape_{nid}"))
    ctx.tensor_shapes[output_name] = ["batch_size", 1, rows, cols]
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("concat")
def compile_concat(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    ordered_tensors: List[str] = []
    concat_order = config.get("concat_order", [])
    if concat_order:
        for port_name in concat_order:
            ordered_tensors.extend(ctx.inputs_for(nid, str(port_name)))
    else:
        for port_name in sorted(ctx.input_deliveries.get(nid, {}).keys()):
            ordered_tensors.extend(ctx.inputs_for(nid, port_name))
    if not ordered_tensors:
        raise ValueError(f"Concat node {nid} has no inputs")
    output_name = f"tensor_{nid}_layer_out"
    ctx.onnx_nodes.append(helper.make_node("Concat", inputs=ordered_tensors, outputs=[output_name], axis=1, name=f"concat_{nid}"))
    base_shape = ctx.tensor_shapes.get(ordered_tensors[0], ["batch_size", 0])
    channels = sum(_as_int(ctx.tensor_shapes.get(t, ["batch_size", 0])[1], 0) for t in ordered_tensors)
    ctx.tensor_shapes[output_name] = [base_shape[0], channels, *base_shape[2:]] if len(base_shape) == 4 else [base_shape[0], channels]
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("add")
def compile_add(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    incoming_tensors: List[str] = []
    for port_name in sorted(ctx.input_deliveries.get(nid, {}).keys()):
        incoming_tensors.extend(ctx.inputs_for(nid, port_name))
    if not incoming_tensors:
        raise ValueError(f"Add node {nid} has no inputs")
    if len(incoming_tensors) == 1:
        ctx.tensor_routing.setdefault(nid, {})["layer_out"] = incoming_tensors[0]
        return
    output_name = f"tensor_{nid}_layer_out"
    current_tensor = incoming_tensors[0]
    for idx, next_tensor in enumerate(incoming_tensors[1:]):
        step_output = output_name if idx == len(incoming_tensors) - 2 else f"tensor_{nid}_add_step_{idx}"
        ctx.onnx_nodes.append(helper.make_node("Add", inputs=[current_tensor, next_tensor], outputs=[step_output], name=f"add_{nid}_{idx}"))
        current_tensor = step_output
    ctx.tensor_shapes[output_name] = ctx.tensor_shapes.get(incoming_tensors[0], ["batch_size", 64])
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = output_name


@handles("passthrough")
def compile_passthrough(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    incoming_tensor = ctx.first_input(nid, "model_in", "layer_in", "pred_in", "scores_in")
    ctx.tensor_routing.setdefault(nid, {})["model_out"] = incoming_tensor
    ctx.tensor_routing.setdefault(nid, {})["layer_out"] = incoming_tensor


@handles("ignored_training")
def compile_ignored_training_node(ctx, nid: str, ntype: str, props: Dict[str, Any], config: Dict[str, Any], emit: Dict[str, Any]) -> None:
    return
