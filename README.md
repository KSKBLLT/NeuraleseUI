# Neuralese Frontend

Neuralese Frontend is the desktop client for building, training, and testing neural network projects through a visual interface.

It is designed for learners who want to understand how models are assembled and iterated without starting from raw code.

Neuralese Backend (API) repo link: https://github.com/hex358/neuralese-api/

---

## What this app does

The frontend focuses on the full learning workflow:

- **Visual model building** through a node-graph editor (layers + connections).
- **Dataset workbench** for inspecting and preparing data.
- **Training orchestration UI** that sends model/data jobs to the backend.
- **Live project management** for lessons, class workflows, and experiments.
- **AI assistant integration hooks** used by in-app mentoring features.

The project is implemented in **Godot 4.x** and uses a modular autoload setup for global services such as networking, graph management, dataset helpers, and runtime orchestration.

---

## High-level architecture (frontend side)

At runtime, the client initializes several singleton-like services (autoloads) for key responsibilities:

- `web` → HTTP/SSE request layer for API calls.
- `sockets` → realtime communication.
- `graphs` → graph state and editing flow.
- `dsl_reg` / `parser` → graph and scripting-related parsing/registry flow.
- `dsreader` → dataset helper utilities.
- `nn` / `learner` → run and training orchestration from the UI side.
- `ui`, `glob`, `cookies` → global UI state, environment config, and auth/session helpers.

The frontend can switch connection mode for development/deployment contexts:

- **Localhost** (default in this repo): `http://127.0.0.1:8000/`
- **Remote**: hosted API endpoint
- **LAN**: configurable local-network host

---

## Main user workflows

1. **Create/open a project**
   - Start a project workspace and select an activity (lesson, sandbox experiment, class task).

2. **Build a model graph**
   - Add layers as nodes, connect flows, and adjust layer settings.
   - Use graph-level feedback to correct invalid architecture paths.

3. **Prepare data**
   - Import or edit datasets in the app.
   - Apply basic transformations and organize data for training.

4. **Train and observe**
   - Launch training from the frontend.
   - Monitor progress, metrics, and intermediate behavior.

5. **Iterate / export-ready workflow**
   - Refine architecture and parameters based on outcomes.
   - Continue until model behavior matches task goals.

---

## Running the frontend locally

### Prerequisites

- **Godot 4.x** (project is configured with 4.6 feature flags).
- A running Neuralese backend API (default expected at `127.0.0.1:8000`).

### Steps

0. **Build the builtin datasets once per checkout** (CIFAR-10 is not in git, 162 MB download): `local_runtime\python\python.exe local_runtime\tools\build_builtin_datasets.py`. Builds refuse to package the app without them; see `local_runtime/datasets/README.md`.
1. Open this repository in Godot.
2. Ensure backend is running.
3. Run the main scene from the editor.
4. If needed, adjust network mode in `scripts/glob.gd`:
   - `NetMode.Localhost`
   - `NetMode.Remote`
   - `NetMode.LAN`

---

## Who this README is for

This README is intended for new users and contributors who need a practical orientation to the Neuralese frontend app (what it is, how it works, and how to start it locally).

If you are integrating backend services, start from `scripts/web.gd` and `scripts/glob.gd` to understand API root selection and request flow.
