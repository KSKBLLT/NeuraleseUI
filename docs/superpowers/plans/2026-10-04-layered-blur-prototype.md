# Layered Blur Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and benchmark two fixed shared-texture backdrop-blur backends against the current High, Medium, and Low paths under deterministic movement on the existing llvmpipe proxy.

**Architecture:** A debug-only compositor renders workspace and persistent UI once, produces shared low-resolution workspace/UI blur textures, and lets panels sample those textures without `BackBufferCopy` or `hint_screen_texture`. Separate Kawase and linear-downsample backend scenes implement the same typed interface; a deterministic harness drives real Neuralese scenes through Godot MCP and standalone WSL runs.

**Tech Stack:** Godot 4.7.1, GDScript, canvas-item shaders, SubViewport/CanvasLayer, Python 3.11/pytest, PowerShell, WSL2 Ubuntu, Mesa llvmpipe, Godot MCP.

**Spec:** `docs/superpowers/specs/2026-10-04-layered-blur-prototype-design.md`

## Global Constraints

- Keep the current High, Medium, and Low implementation unchanged and default throughout the prototype.
- Add no user-facing graphics option.
- New backends contain no `BackBufferCopy`, `hint_screen_texture`, screen mipmaps, CPU image readback, or per-frame `ImageTexture` creation.
- Production-facing code exposes exactly two backends: `KAWASE` and `LINEAR_DOWNSAMPLE`; benchmark-only legacy variants do not become product modes.
- Use real Neuralese scenes, shaders, materials, panels, graph nodes, splines, fonts, and background in representative runs.
- Moving scenarios refresh the required blur texture every frame; dirty caching may optimize idle only.
- Do not modify `addons/`.
- Do not hand-edit generated node catalogs; follow `AGENTS.md` if fixture topology requires a registry change.
- WSL runs fail closed unless they report Godot 4.7.1, Vulkan Mobile, llvmpipe, the requested resolution, 4 GiB RAM, zero swap, and the requested CPU affinity.
- Stage files by name; never use `git add -A`.

## Review Focus

- Nested SubViewport ordering must not make blur trail pan/drag by one frame; Task 3 adds a frame-ID latency test.
- Input must still reach graph, text fields, menus, and modal blockers through nested viewports; Task 4 adds interaction-parity tests.
- First activation must not compile shaders during user motion; Task 2 adds explicit prewarm and cold/warm assertions.
- Resize/DPI changes must resize all sharp and blur targets atomically without stretching stale textures; Task 3 adds resize assertions.
- Hidden overlays must stop updating and release their UI-blur targets without invalidating workspace blur; Task 3 adds lifecycle assertions.

---

## File structure

- `scripts/rendering/layered_blur_backend.gd`: shared backend contract and fixed backend enum.
- `scripts/rendering/layered_blur_compositor.gd`: source revision, viewport sizing, update ordering, and texture publication.
- `scripts/rendering/layered_blur_kawase.gd`: Kawase backend controller.
- `scripts/rendering/layered_blur_linear.gd`: linear-downsample backend controller.
- `shaders/layered_blur/kawase_down.gdshader`: four-tap downsample.
- `shaders/layered_blur/kawase_up.gdshader`: eight-tap upsample.
- `shaders/layered_blur/linear_downsample.gdshader`: one-pass one-eighth-resolution source sample.
- `shaders/layered_blur/panel_sample.gdshader`: one-sample panel backdrop compositor with existing tint/border inputs.
- `scenes/rendering/layered_blur_compositor.tscn`: shared viewport topology.
- `scenes/rendering/layered_blur_kawase.tscn`: half/quarter/half Kawase chain.
- `scenes/rendering/layered_blur_linear.tscn`: one-eighth linear target.
- `tests/performance/layered_blur_fixture.tscn`: real-material rendering fixture.
- `tests/performance/layered_blur_fixture.gd`: deterministic fixture and action driver.
- `tests/performance/layered_blur_benchmark.gd`: variant runner and JSONL output.
- `tests/performance/run_layered_blur_matrix.ps1`: complete local matrix and summary entry point.
- `tests/performance/summarize_layered_blur.py`: validates metadata and calculates comparable statistics.
- `tests/godot/test_layered_blur_backend.gd`: backend contract and lifecycle tests.
- `tests/godot/test_layered_blur_backend.tscn`: registered Godot test scene.
- `tests/godot/test_layered_blur_input.gd`: input and temporal-latency test.
- `tests/godot/test_layered_blur_input.tscn`: registered interaction test scene.
- `.superpowers/low-perf-proxy/run.ps1`: variant, resolution, and MCP-editor arguments.
- `.superpowers/low-perf-proxy/run-wsl-llvmpipe.sh`: verified WSL editor/standalone launch modes.
- `.superpowers/low-perf-proxy/bench_project.gd`: delegate existing and new scenarios to one canonical scenario driver.
- `docs/performance/layered-blur-prototype-results.md`: commands, environment, raw-result links, screenshots, and decision.

### Task 1: Lock the backend contract and benchmark metadata

**Files:**
- Create: `scripts/rendering/layered_blur_backend.gd`
- Create: `tests/godot/test_layered_blur_backend.gd`
- Create: `tests/godot/test_layered_blur_backend.tscn`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Produces: `LayeredBlurBackend.Mode { KAWASE, LINEAR_DOWNSAMPLE }`.
- Produces: `const PROTOTYPE_DEFAULT_BACKEND := Mode.KAWASE`; this is only the debug-preview default and does not change production graphics selection.
- Produces: `configure(source: Texture2D, output_size: Vector2i) -> void`.
- Produces: `request_update(revision: int) -> void` and signal `texture_ready(revision: int, texture: Texture2D)`.
- Produces: `set_active(active: bool) -> void`, `prewarm() -> void`, and `get_metrics() -> Dictionary`.

- [ ] **Step 1: Write the failing contract test.** Assert the enum contains only the two specified values; reject zero-sized sources; assert monotonically increasing revisions; assert inactive backends do not update; print exact marker `PASS test_layered_blur_backend`.
- [ ] **Step 2: Register `test_layered_blur_backend.tscn:PASS test_layered_blur_backend` in `tests/godot/run_all.sh`.**
- [ ] **Step 3: Run the isolated test and confirm it fails because the backend class is absent.**

  Run: `"$GODOT_BIN" --headless --path . --quit-after 300 --scene tests/godot/test_layered_blur_backend.tscn`

- [ ] **Step 4: Implement the typed abstract contract and backend metadata dictionary.** Metadata keys are `backend`, `revision`, `source_size`, `output_size`, `active`, `prewarmed`, and `updates`.
- [ ] **Step 5: Re-run the isolated test and confirm the exact PASS marker.**
- [ ] **Step 6: Commit.**

  ```bash
  git add scripts/rendering/layered_blur_backend.gd tests/godot/test_layered_blur_backend.gd tests/godot/test_layered_blur_backend.tscn tests/godot/run_all.sh
  git commit -m "test: define layered blur backend contract"
  ```

### Task 2: Implement the two fixed low-resolution backends

**Files:**
- Create: `scripts/rendering/layered_blur_kawase.gd`
- Create: `scripts/rendering/layered_blur_linear.gd`
- Create: `shaders/layered_blur/kawase_down.gdshader`
- Create: `shaders/layered_blur/kawase_up.gdshader`
- Create: `shaders/layered_blur/linear_downsample.gdshader`
- Create: `scenes/rendering/layered_blur_kawase.tscn`
- Create: `scenes/rendering/layered_blur_linear.tscn`
- Modify: `tests/godot/test_layered_blur_backend.gd`

**Interfaces:**
- Consumes: Task 1 `LayeredBlurBackend` contract.
- Produces: `LayeredBlurKawase` with half/quarter/half targets and offsets `1.0`, `2.0`.
- Produces: `LayeredBlurLinear` with one eighth-resolution target.
- Produces: one linear-filtered, non-mipmapped output texture per backend.

- [ ] **Step 1: Extend the failing test.** Instantiate both backend scenes at 1280x720; assert Kawase target sizes 640x360, 320x180, 640x360; assert linear target size 160x90; assert neither shader source contains `hint_screen_texture`; assert no subtree contains `BackBufferCopy`.
- [ ] **Step 2: Run the isolated test and confirm failure on missing scenes.**
- [ ] **Step 3: Implement `linear_downsample.gdshader` and `LayeredBlurLinear`.** Use one low-resolution draw and linear filtering without mipmaps.
- [ ] **Step 4: Implement the fixed three-stage Kawase chain.** Use distinct down/up shader resources; do not add a backend branch to shader code.
- [ ] **Step 5: Implement `prewarm()`.** Render every pass once while its display is effectively invisible but nonzero alpha, then mark `prewarmed`; retain cold activation duration in metrics.
- [ ] **Step 6: Run the backend test at 1280x720 and 1920x1080 and confirm PASS.**
- [ ] **Step 7: Commit.**

  ```bash
  git add scripts/rendering/layered_blur_kawase.gd scripts/rendering/layered_blur_linear.gd shaders/layered_blur/kawase_down.gdshader shaders/layered_blur/kawase_up.gdshader shaders/layered_blur/linear_downsample.gdshader scenes/rendering/layered_blur_kawase.tscn scenes/rendering/layered_blur_linear.tscn tests/godot/test_layered_blur_backend.gd
  git commit -m "feat: add fixed layered blur backends"
  ```

### Task 3: Build the compositor and prove same-frame texture publication

**Files:**
- Create: `scripts/rendering/layered_blur_compositor.gd`
- Create: `shaders/layered_blur/panel_sample.gdshader`
- Create: `scenes/rendering/layered_blur_compositor.tscn`
- Create: `tests/godot/test_layered_blur_input.gd`
- Create: `tests/godot/test_layered_blur_input.tscn`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Consumes: Task 2 backend scenes.
- Produces: `LayeredBlurCompositor.configure(size: Vector2i, backend: LayeredBlurBackend.Mode) -> void`.
- Produces: `set_workspace_source(viewport: SubViewport) -> void`, `set_persistent_ui_source(viewport: SubViewport) -> void`.
- Produces: `workspace_blur_texture() -> Texture2D`, `ui_blur_texture() -> Texture2D`.
- Produces: `mark_workspace_dirty(revision: int) -> void`, `set_overlay_blur_required(required: bool) -> void`.

- [ ] **Step 1: Write the failing temporal/lifecycle test.** Stamp source frame IDs into a deterministic moving pattern and assert the published blur ID matches the displayed sharp ID on every one of 120 frames; resize at frame 40; toggle overlay blur at frames 60 and 90; print `PASS test_layered_blur_input`.
- [ ] **Step 2: Register `test_layered_blur_input.tscn:PASS test_layered_blur_input` in `tests/godot/run_all.sh`.** Add the same non-headless `NEURALESE_ISOLATED_TEST=1` runner exception used by `test_background_blur_cache.tscn`, because this test observes rendered Viewport textures.
- [ ] **Step 3: Run the isolated test and confirm it fails because the compositor is absent.**
- [ ] **Step 4: Implement the workspace-to-UI dependency graph and single-sample panel shader.** Preserve the last complete texture until the matching revision is ready; never publish a sharp-new/blur-old pair.
- [ ] **Step 5: Implement atomic resize.** Allocate all new targets, prewarm them, publish them together, then release old targets.
- [ ] **Step 6: Implement overlay lifecycle.** Allocate/update `ui_blur` only while requested; disable and release its targets after the overlay closes while leaving workspace blur valid.
- [ ] **Step 7: Run the test with both backends and both resolutions; confirm zero delayed frames and exact PASS marker.** Run: `NEURALESE_ISOLATED_TEST=1 "$GODOT_BIN" --path . --quit-after 300 --scene tests/godot/test_layered_blur_input.tscn`.
- [ ] **Step 8: Commit.**

  ```bash
  git add scripts/rendering/layered_blur_compositor.gd shaders/layered_blur/panel_sample.gdshader scenes/rendering/layered_blur_compositor.tscn tests/godot/test_layered_blur_input.gd tests/godot/test_layered_blur_input.tscn tests/godot/run_all.sh
  git commit -m "feat: compose same-frame layered blur textures"
  ```

### Task 4: Add a representative real-material fixture and interaction parity

**Files:**
- Create: `tests/performance/layered_blur_fixture.tscn`
- Create: `tests/performance/layered_blur_fixture.gd`
- Modify: `tests/godot/test_layered_blur_input.gd`

**Interfaces:**
- Consumes: Task 3 compositor.
- Produces: `configure_fixture(name: StringName, seed: int, variant: StringName) -> void`.
- Produces: `run_scenario(name: StringName, duration_seconds: float) -> Dictionary`.
- Produces fixtures `school-five-node` and `car-track`.
- Produces scenarios `idle`, `camera_motion`, `node_drag`, `dense_edit`, `workspace_stress`, and `overlay_motion`.

- [ ] **Step 1: Extend the failing input test.** Assert pan, zoom, node drag, Dense field edit, menu click, and modal input blocking produce the same observed state in legacy and layered topology.
- [ ] **Step 2: Build `school-five-node` from real registered graph scenes without adding generated catalog files.** Use five nodes including Dense and OutputAnswer plus real splines and current panel materials.
- [ ] **Step 3: Add `car-track` loading through the same path used by `.superpowers/low-perf-proxy/bench_project.gd`.**
- [ ] **Step 4: Implement deterministic scenario actions with a fixed default seed `20261004`.** Moving scenarios call `mark_workspace_dirty()` every frame and assert update count equals measured frame count.
- [ ] **Step 5: Run the input test and confirm state parity and exact PASS marker.**
- [ ] **Step 6: Commit.**

  ```bash
  git add tests/performance/layered_blur_fixture.tscn tests/performance/layered_blur_fixture.gd tests/godot/test_layered_blur_input.gd
  git commit -m "test: add representative layered blur workload"
  ```

### Task 5: Create a fair five-variant benchmark runner

**Files:**
- Create: `tests/performance/layered_blur_benchmark.gd`
- Create: `tests/performance/summarize_layered_blur.py`
- Create: `tests/performance/test_summarize_layered_blur.py`
- Modify: `.superpowers/low-perf-proxy/bench_project.gd`

**Interfaces:**
- Consumes: Task 4 fixture/scenario API.
- Produces CLI `--blur-variant=legacy-high|legacy-medium|legacy-low|layered-kawase|layered-linear`.
- Produces JSONL rows with environment, commit, fixture, seed, variant, scenario, resolution, warm/cold phase, frame statistics, threshold counts, RSS, render counters, and target update counts.
- Produces summary command `python tests/performance/summarize_layered_blur.py RAW.jsonl --output SUMMARY.md`.

- [ ] **Step 1: Write failing pytest coverage.** Reject mixed commits, renderer strings, resolutions, seeds, fixture revisions, or incomplete variant sets; assert percentile and threshold calculations on fixed samples.
- [ ] **Step 2: Run `python -m pytest tests/performance/test_summarize_layered_blur.py -v` and confirm failure on missing implementation.**
- [ ] **Step 3: Implement the GDScript runner.** Close onboarding/splash before timing; record cold activation separately; warm 60 frames; run the exact Task 4 scenario; emit one row per sample block and one aggregate row.
- [ ] **Step 4: Delegate existing perfbench scenarios to the canonical Task 4 driver.** Remove duplicated action generation from `bench_project.gd` only after output parity is tested.
- [ ] **Step 5: Implement the strict Python parser and Markdown summary.** Do not compare rows whose metadata differs.
- [ ] **Step 6: Re-run pytest and one short local Godot smoke run; confirm all five variants appear and metadata matches.**
- [ ] **Step 7: Commit.**

  ```bash
  git add tests/performance/layered_blur_benchmark.gd tests/performance/summarize_layered_blur.py tests/performance/test_summarize_layered_blur.py .superpowers/low-perf-proxy/bench_project.gd
  git commit -m "perf: add comparable layered blur benchmark"
  ```

### Task 6: Integrate verified llvmpipe and Godot MCP launch modes

**Files:**
- Modify: `.superpowers/low-perf-proxy/run.ps1`
- Modify: `.superpowers/low-perf-proxy/run-wsl-llvmpipe.sh`
- Modify: `.superpowers/low-perf-proxy/test-proxy.ps1`
- Create: `tests/performance/run_layered_blur_matrix.ps1`

**Interfaces:**
- Consumes: Task 5 CLI and JSONL schema.
- Produces PowerShell parameters `-BlurVariant`, `-Resolution`, `-Fixture`, `-Scenario`, `-Seed`, and `-McpEditor`.
- Produces WSL modes `--standalone-benchmark` and `--mcp-editor`.
- Produces fail-closed `screening`, `full-720p`, `stress`, and `motion-1080p` matrix commands.

- [ ] **Step 1: Extend `test-proxy.ps1` with failing assertions.** Require both resolutions, five variants, `torture` CPU set `0-1`, metadata path, and rejection of Dummy/native renderers.
- [ ] **Step 2: Implement argument plumbing without changing existing default behavior.**
- [ ] **Step 3: Implement `--mcp-editor`.** Launch the same Godot 4.7.1 binary under llvmpipe and `taskset`; verify Windows and WSL port 6550 are free before launch; fail with an actionable duplicate-client message rather than falling back.
- [ ] **Step 4: Implement `run_layered_blur_matrix.ps1`.** Define these exact matrices and write each run to a unique raw file: `screening` = all five variants × both fixtures × `camera_motion,node_drag` at 1280x720 once; `full-720p` = all five × both fixtures × `idle,camera_motion,node_drag,dense_edit,overlay_motion` three times with interleaved variant order; `stress` = all five × `school-five-node` × `workspace_stress` twice; `motion-1080p` = all five × both fixtures × `camera_motion,overlay_motion` three times. Resume only complete metadata-identical runs.
- [ ] **Step 5: Add host RSS sampling.** The standalone launcher records the Godot PID and polls `/proc/<pid>/status` once per second, then merges start/peak/end/cooldown RSS into the matching JSONL aggregate row.
- [ ] **Step 6: Run `./.superpowers/low-perf-proxy/test-proxy.ps1` and `./.superpowers/low-perf-proxy/run.ps1 -Profile torture -VerifyOnly`; confirm PASS and the exact renderer/limit lines.**
- [ ] **Step 7: Commit.**

  ```bash
  git add .superpowers/low-perf-proxy/run.ps1 .superpowers/low-perf-proxy/run-wsl-llvmpipe.sh .superpowers/low-perf-proxy/test-proxy.ps1 tests/performance/run_layered_blur_matrix.ps1
  git commit -m "perf: drive layered blur matrix on llvmpipe"
  ```

### Task 7: Validate visuals and motion through Godot MCP

**Files:**
- Modify: `tests/performance/layered_blur_fixture.gd`
- Create: `docs/performance/layered-blur-prototype-results.md`

**Interfaces:**
- Consumes: Task 6 WSL MCP editor and Task 4 scenarios.
- Produces: frozen matched screenshots and MCP profiler exports for every variant.
- Produces: an interaction and one-frame-latency verdict before timing claims.

- [ ] **Step 1: Start the WSL `torture` MCP editor and verify `godot_project get_info` reports this repo and Godot 4.7.1.**
- [ ] **Step 2: Run the fixture frozen at seed `20261004`; use `godot_runtime_state` to confirm identical camera, nodes, panels, and visible overlay before each capture.**
- [ ] **Step 3: Capture one matched frame per variant at 1280x720.** Judge backdrop contents, edge repetition/kaleidoscope artifacts, text readability, panel tint, corner geometry, and seams; record explicit pass/fail notes.
- [ ] **Step 4: Use `godot_profiler start/get_data` around 30 seconds each of `camera_motion`, `node_drag`, and `overlay_motion`.** Save median/p95/p99, spikes, frame-budget counts, and monitor trends.
- [ ] **Step 5: Use MCP input to click/focus/drag through every Task 4 parity action and record any behavioral difference.**
- [ ] **Step 6: Stop the game/editor cleanly and add environment plus MCP commands to the results document.**
- [ ] **Step 7: Commit only the report and intentional fixture adjustment.**

  ```bash
  git add tests/performance/layered_blur_fixture.gd docs/performance/layered-blur-prototype-results.md
  git commit -m "docs: record layered blur MCP validation"
  ```

### Task 8: Run the standalone torture matrix and decide

**Files:**
- Modify: `docs/performance/layered-blur-prototype-results.md`

**Interfaces:**
- Consumes: Task 6 matrix and Task 5 summary.
- Produces: raw JSONL, generated summary, memory curves, and one explicit recommendation: reject, revise, `KAWASE`, or `LINEAR_DOWNSAMPLE`. Production selection remains a later reviewed migration.

- [ ] **Step 1: Run `screening`; inspect metadata and abort on a topology, input, or renderer mismatch.**
- [ ] **Step 2: Run `full-720p`, `stress`, and `motion-1080p` with their specified repeat counts and interleaved order.**
- [ ] **Step 3: Generate the strict summary and confirm every comparison has identical commit, renderer, fixture revision, resolution, and seed.**
- [ ] **Step 4: Apply all decision gates from the spec.** Preserve failures; do not retune the workload or reduce moving-frame update frequency.
- [ ] **Step 5: Record the winning recommendation without changing `graphics_quality.gd` or any production default.** If neither passes, record the next falsifiable hypothesis.
- [ ] **Step 6: Run the full required verification from `AGENTS.md`.**

  ```bash
  python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration -v
  python -m tools.node_dev check
  GODOT_BIN=/path/to/godot bash tests/godot/run_all.sh
  python -m tools.node_dev godot-check --godot-bin "$GODOT_BIN" --timeout 300
  ```

- [ ] **Step 7: Commit the decision and report.**

  ```bash
  git add docs/performance/layered-blur-prototype-results.md
  git commit -m "perf: select layered blur prototype outcome"
  ```

### Task 9: Validate the winner on native Intel/WDDM before production migration

**Files:**
- Modify: `docs/performance/layered-blur-prototype-results.md`

**Interfaces:**
- Consumes: Task 8 winning backend and exact benchmark metadata.
- Produces: native Intel monoblock evidence; no production switch is authorized by this task.

- [ ] **Step 1: Run the same five variants, fixtures, seeds, movement scenarios, and resolutions on the available Windows Intel monoblock.** Record `dxdiag`, driver version, display resolution, RAM, dedicated/shared GPU memory, and power mode.
- [ ] **Step 2: Record Windows process private bytes, shared GPU memory, GPU engine utilization, frame-time statistics, and Event Viewer/WHEA/display-driver events during the 180-second stress scenario.**
- [ ] **Step 3: Compare native ranking with llvmpipe ranking.** Treat a ranking reversal as a failed portability gate requiring investigation.
- [ ] **Step 4: Run an extended 30-minute moving stress test with the winner and inspect memory plateau plus display-driver stability.**
- [ ] **Step 5: Document whether the evidence supports production integration.** State explicitly that absence of a crash is risk reduction, not proof of the historical `dxgmms2.sys` root cause without the school dump.
- [ ] **Step 6: Commit the native evidence.**

  ```bash
  git add docs/performance/layered-blur-prototype-results.md
  git commit -m "docs: validate layered blur on Intel WDDM"
  ```
