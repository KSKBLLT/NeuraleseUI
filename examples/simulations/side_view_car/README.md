# Side-view car trained example

This folder contains a real Neuralese ONNX training result for the built-in
`car_track` simulation dataset.

## Contract

- Agent: side-view car
- Inputs: 8 normalized distance rays
- Outputs: steering and throttle
- Model: `8 -> Dense(32, ReLU) -> Dense(16, ReLU) -> Dense(2)`
- Loss: mean squared error
- Optimizer: Adam, learning rate `0.001`
- Training: 20 epochs, seed `7`

## Files

- `checkpoint/inference.onnx` is the trained model used for inference.
- `checkpoint/checkpoint` is the required ONNX Runtime training state.
- `checkpoint/manifest.json` describes the training result.
- `evaluation.json` contains the reproducible validation comparison.

On 600 validation samples the trained model reached MAE `0.01397`; the constant
baseline reached MAE `0.19956`. The trained model reduced error by about 93%.
The end-to-end regression test rebuilds the same model, requires a physical
checkpoint file, runs ONNX inference, and rejects the result unless it beats the
constant baseline by at least 10%.

Run the proof locally:

```bash
PYTHONPATH=local_runtime python -m unittest \
  tests.local_runtime.test_simulation_training_e2e -v
```
