# Simulations virtual architecture

The Simulations tab is intentionally not represented by one Godot `Node` per world object.

## Ownership

- `SimulationWorldState` is the editable source of truth. It stores parallel packed columns and sparse properties.
- `SimulationSpatialIndex` owns editor picking. Editor picking must not use physics queries.
- `SimulationWorldRenderer` owns a bounded pool of visible static chunks and one dynamic canvas.
- `SimulationCompiler` creates an immutable, detached blueprint.
- `SimulationKernel` owns the rules of one running session.
- `SimulationPhysicsBackend` owns one `PhysicsServer2D.space` and every RID inside that space.
- `SimulationDatasetWorker` owns exactly one kernel and accesses it from exactly one worker thread.

## Thread rules

1. SceneTree nodes, CanvasItems, UI controls and loaded resources stay on the main thread.
2. A dataset worker receives a deep-detached blueprint before its thread starts.
3. A worker never shares a mutable kernel, RID list, array or dictionary with another worker.
4. Worker-to-main communication uses message batches protected by a mutex.
5. Physics spaces are independent. Godot's PhysicsServer runs on its separate thread via `physics/2d/run_on_separate_thread`.
6. Rendering commands are never issued from dataset workers.
7. Workers are cancelled and joined before their owner is destroyed.

The built-in PhysicsServer has no public manual per-space step. Dataset workers therefore synchronize sampling to the engine fixed tick. A future Rapier backend may add manual stepping without changing the document, renderer, kernel or dataset format.

## Persistence

World format v2 stores packed object columns under `objects` and sparse properties by stable object ID. The loader accepts the legacy v1 object-array format and upgrades it in memory.

Generated numeric datasets use row-major `PackedFloat32Array` storage. Training and previews consume the packed representation directly. Legacy cell dictionaries are created only when the user explicitly opens the dataset in the old table editor.

## Performance invariants

- Never add per-object `_process`, `_physics_process`, signal connections or render nodes.
- Never deep-copy the full world for undo. Commands contain only affected objects.
- Never serialize static world objects into each dataset preview.
- Never update generation UI for every generated row.
- Never access a session from more than one owning thread.
