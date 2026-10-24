# Layered blur prototype design

## Status and purpose

This document specifies an experiment, not a production migration. The existing
High, Medium, and Low paths remain the baseline and remain the default until the
experiment produces repeatable visual and timing evidence.

The experiment answers one question: can Neuralese keep real backdrop blur while
removing per-CanvasLayer screen copies and mip generation from the moving-frame
hot path?

The relevant current implementation is:

- `shaders/block_body.gdshaderinc`: declares `hint_screen_texture`, samples a
  mip level, and optionally adds a nine-tap Gaussian sample.
- `scripts/graphics_quality.gd`: chooses the current High, Medium, and Low paths.
- `scripts/bg.gd`: implements the current Medium background-only bake.
- `scripts/top_panel.gd`: installs a rectangular `BackBufferCopy` for the top
  strip in the current High path.
- `scenes/project.tscn`, `scenes/fg.tscn`, `scenes/menus.tscn`, and
  `scenes/node_palette.tscn`: define the current workspace and CanvasLayer split.

## What the Godot renderer actually does

Godot cannot safely sample a framebuffer while writing it. The documented 2D
fallback for the first `hint_screen_texture` material is a full-screen copy.
`BackBufferCopy` requests the same operation explicitly and can restrict it to a
rectangle. A mipmapped sampler also asks Godot to build the backbuffer mip chain.

This is not merely theoretical for the target hardware. Godot issue #108935
reports about 4 ms for one otherwise trivial full-screen screen-texture sample
on Intel UHD, about 7 ms when repeated in two CanvasLayers, and about 8 ms for a
mipmapped screen sample. Godot proposal #7641 independently reports that even
one screen copy can be prohibitive on mobile-class hardware and that a
lower-resolution Viewport texture is substantially cheaper.

Sources:

- <https://docs.godotengine.org/en/4.7/tutorials/shaders/screen-reading_shaders.html>
- <https://github.com/godotengine/godot/issues/108935>
- <https://github.com/godotengine/godot-proposals/issues/7641>
- Godot 4.7.1 renderer implementation:
  `servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp`

Therefore the prototype must not contain `BackBufferCopy`,
`hint_screen_texture`, or a screen sampler with mipmaps in either new backend.
Using one carefully placed `BackBufferCopy` is retained only as a possible
diagnostic control, never as the proposed architecture.

## Why movement is the decisive workload

A stationary 10 FPS screen may appear healthy because no spatial change exposes
the missing frames. Motion does not necessarily create the original cost; it
makes that cost visible.

During camera pan, zoom, node drag, spline animation, or node parameter changes,
the workspace source changes every frame. Dirty-only caching therefore provides
no saving in the moving-frame worst case. The prototype is acceptable only if it
rebuilds the relevant blur every moving frame and still improves frame time.

The proposed gain comes from bounded shared work:

1. Render workspace content once into one full-resolution source.
2. Generate one low-resolution workspace blur per frame.
3. Let every persistent UI panel sample that same blur texture once.
4. Compose workspace plus persistent UI once.
5. Generate one low-resolution UI-underlay blur only when a top-level overlay
   requiring it is visible.

Panel count must not increase the number of source copies or blur passes.

## Semantic layers

The experiment uses the same three boundaries visible in the current scene:

1. **Workspace**: deep background, graph nodes, splines, and workspace effects.
2. **Persistent UI**: `fg`, top bar, menus, and node palette.
3. **Top-level overlays**: splash/dialog/tutorial surfaces that blur everything
   below them.

The resulting textures are:

- `workspace_sharp`: one full-resolution workspace render.
- `workspace_blur`: one shared low-resolution blurred workspace.
- `ui_composite`: workspace plus persistent UI.
- `ui_blur`: one shared low-resolution blurred `ui_composite`, allocated and
  updated only while a top-level overlay needs it.

No per-panel, per-object, or per-z-index blur textures are allowed.

## Two fixed backends

These are implementation backends, not user-facing quality settings. Production
will eventually select one fixed default in code. The benchmark may override the
selection through a debug-only command-line argument so both implementations
can be measured from the same checkout.

### `KAWASE`

Use separate shaders for a small dual-filter chain:

1. full resolution to half resolution, four bilinear taps;
2. half resolution to quarter resolution, four bilinear taps with a tunable
   Kawase offset;
3. quarter resolution to half resolution, an eight-tap upsample;
4. panels sample the final half-resolution texture once with linear filtering.

The prototype starts with offsets `1.0` and `2.0`; visual calibration may change
the offsets but not the number of passes. This shape follows the bandwidth-aware
dual-filter family described by ARM rather than the current per-panel Gaussian:
<https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_slides.pdf>.

### `LINEAR_DOWNSAMPLE`

Use one eighth-resolution target and no convolution pass. One low-resolution
draw samples the sharp source with linear filtering; panels sample that result
once with linear filtering. This deliberately represents the cheapest acceptable
fallback and exposes the downsample/interpolation look rather than disguising it
behind extra taps.

The two backends use distinct shader resources. There is no dynamic backend
branch in a fragment shader.

## Rendering and input topology

The representative app prototype uses nested `SubViewportContainer` and
`SubViewport` nodes so the workspace is rendered once and mouse input can still
reach the real Controls and graph surface. Existing CanvasLayers can be directed
to a specific viewport with `CanvasLayer.custom_viewport`, but this must be
proven in a minimal fixture before applying it to `fg`, menus, and node palette.

The dependency order is:

```text
workspace_sharp -> workspace_blur -> ui_composite -> ui_blur -> top overlays
```

Godot has had one-frame ordering defects between dependent SubViewports. The
prototype must encode dependencies through texture use, instrument a frame ID in
the source, and reject any topology in which the panel blur trails the workspace
by one frame. Relevant upstream report:
<https://github.com/godotengine/godot/issues/65545>.

Calling `ViewportTexture.get_image()` in the moving loop is forbidden because it
forces a GPU-to-CPU synchronization and is a documented stutter source:
<https://github.com/godotengine/godot/issues/75877>.

Input is a release blocker. Camera pan, zoom, node drag, text-field focus, menu
clicks, and top-level modal blocking must behave identically before performance
results count.

## Prototype variants

Every run selects exactly one variant before the scene is created:

- `legacy-high`
- `legacy-medium`
- `legacy-low`
- `layered-kawase`
- `layered-linear`

`layered-kawase-msaa4` is permitted as an ablation only. It is not a third
product mode; it isolates the existing 4x MSAA cost from the blur architecture.

The new variants default to disabled global 2D MSAA. Existing analytic shader AA
and `Line2D` antialiasing remain enabled. Visual evidence, not an assumption,
decides whether this is acceptable.

## Representative workloads

The benchmark uses real Neuralese scenes, shaders, panels, graph node scenes,
splines, fonts, and background. It must not use a standalone colored shader card.
It supplies two deterministic fixtures:

- `school-five-node`: five real nodes including Dense and OutputAnswer, with the
  same small graph scale described in the school incident.
- `car-track`: the existing built-in Car Track project used by the llvmpipe
  harness.

Each variant runs the same seeded action script after startup/onboarding is
closed:

1. `idle`: 30 seconds, no input.
2. `camera_motion`: 60 seconds of continuous pan plus periodic zoom.
3. `node_drag`: 60 seconds of continuous real node dragging.
4. `dense_edit`: 60 seconds of real Dense input edits while the camera moves.
5. `workspace_stress`: 180 seconds of deterministic node creation, parameter
   mutation, scene rebuild, and camera activity.
6. `overlay_motion`: 60 seconds with a top-level overlay visible over a moving
   workspace.

All moving scenarios force blur refresh every frame. A separate idle run may
exercise dirty-only updates, but its result cannot be used to claim that motion
was fixed.

## Measurement protocol

The existing proxy remains the environment source:
`.superpowers/low-perf-proxy/run.ps1` and
`.superpowers/low-perf-proxy/run-wsl-llvmpipe.sh`.

Required environment checks are Godot 4.7.1, Vulkan Mobile, llvmpipe, 4 GiB RAM,
zero swap, 1280x720, and the two-CPU `torture` affinity. A second 1920x1080 matrix
is required because framebuffer-copy cost scales with pixel count.

The benchmark has two observation paths:

- **Godot MCP in the WSL llvmpipe editor** drives input, freezes identical visual
  frames, captures screenshots, and gathers `godot_profiler` time-series data.
- **The standalone harness** executes the same seeded scenario without the
  editor, emits durable JSONL, and records host RSS from `/proc`. This avoids
  treating the editor or MCP transport as part of the product frame time.

The WSL editor must fail closed if port 6550 is held by another MCP client. No
benchmark may silently fall back to a Windows editor, Dummy renderer, native
GPU, or a different Godot version.

For each scenario and variant, record:

- median, p95, p99, maximum, and standard deviation of frame time;
- frames above 16.67, 33.33, 50, 100, 250, and 2,000 ms;
- process RSS at start, peak, end, and after a 20-second cooldown;
- Godot render-object, draw-call, texture-memory, and video-memory monitors when
  the renderer exposes them;
- cold first-use time separately from warmed steady state;
- a screenshot and the exact fixture seed, resolution, commit, renderer string,
  and command line.

Warm every backend once before steady-state measurement. Keep the cold result:
Godot compiles shaders on first visible use, and delayed SubViewport visibility
can create a one-time stutter. Upstream context:
<https://github.com/godotengine/godot/issues/42631>.

## Proposed decision gates

These are prototype gates, not promised results:

- Both new variants must reduce both median and p95 moving-frame time by at
  least 35% relative to `legacy-high` in every moving scenario on `torture`.
- `layered-kawase` must be no more than 25% slower than `legacy-medium` at p95
  during `camera_motion` and `node_drag`.
- `layered-linear` must be no more than 10% slower than `legacy-medium` at p95 in
  the same scenarios.
- No new variant may produce a frame above 2 seconds after warmup.
- RSS and renderer texture-memory curves must plateau during the 180-second
  stress run and return near their pre-run level after cooldown.
- `layered-kawase` must preserve recognizable High-style backdrop blur without
  repeated/kaleidoscopic contours. `layered-linear` may be softer and less
  accurate, but text, silhouettes, and panel boundaries must remain readable.
- All interaction-parity and one-frame-latency tests must pass.

If a gate fails, keep the raw result and reject or revise the backend. Do not
silently lower update frequency, hide panels, reduce the source fixture, or
change the action seed.

## Limits of llvmpipe evidence

llvmpipe is intentionally much slower and is useful for relative frame-time,
CPU/RAM pressure, and memory-growth tests. It does not emulate Intel UHD, WDDM,
DXGI scheduling, or `dxgmms2.sys`; it cannot prove that a Windows driver crash is
fixed.

The 128 MB shown for Intel integrated graphics is not a hard total VRAM budget.
Intel documents that integrated graphics use dynamically allocated shared system
memory: <https://www.intel.com/content/www/us/en/support/articles/000041253/graphics.html>.

After the llvmpipe decision, the winning backend must run the same matrix on the
available Windows Intel monoblock. A school-device claim additionally requires a
crash dump or WPR/GPU trace from that device. The prototype can reduce the exact
copy/mipmap pressure correlated with the symptoms; it cannot retroactively prove
the cause of `SYSTEM_THREAD_EXCEPTION_NOT_HANDLED` in `dxgmms2.sys`.

## Non-goals

- No user-facing graphics selector.
- No production removal of High, Medium, or Low during the experiment.
- No per-object or arbitrary stacked blur.
- No addon modifications.
- No CPU image readback or per-frame `ImageTexture` creation.
- No claim that llvmpipe reproduces the Windows crash.
