# Layered Blur Implementation Plan

## Goal

Add real backdrop blur to Medium without returning to per-material
`hint_screen_texture` reads. The implementation must cache a small fixed number
of visual layers, update them only when their contents change, and preserve the
current High and Low modes.

## Decision

Do not create one blurred texture per object or per z-index. Neuralese has three
useful visual boundaries, so the first production version needs at most three
cached backdrops:

```text
top-level windows / modal stack  -> modal_underlay_blur (only if nested)
persistent UI                    -> ui_blur
workspace objects and graph      -> workspace_blur
background                       -> existing background blur cache
```

The normal case uses only `workspace_blur` and `ui_blur`. A third modal cache is
created only when one translucent top-level window must blur another. This avoids
the combinatorial stacked-blur design discussed earlier.

## Current boundaries

- Workspace: `WIN_GRAPH/bg`, `WIN_GRAPH/GraphStorage`, graph connections, and the
  dynamically-created spline canvas layers in `scripts/glob.gd`.
- Persistent UI: `scenes/fg.tscn`, `WIN_GRAPH/menus`, `follow_menus`, and
  `NodePalette`. These already render above the workspace through CanvasLayers
  125-126.
- Top-level windows: dialogs, splash, tutorial/choice overlays, and other modal
  surfaces above the persistent UI.
- Simulation owns another workspace background and camera. It should consume the
  same cache component after Graph proves the architecture.
- Dataset and Net do not own an independent workspace background; they sit over
  the active shared background.

## Memory and work budget

At 1920x1080, one RGBA8 full-resolution target is about 7.9 MiB. A
quarter-resolution blur target is about 0.5 MiB. Two sharp layer targets plus two
quarter-resolution blur targets therefore cost about 16.8 MiB before any driver
double-buffering. At 1366x768 the same set is about 8.5 MiB.

The current 4x4 kernel at quarter resolution performs 16 samples for 1/16 as many
pixels, approximately one full-resolution sample per source pixel per invalidation.
It must not run every frame while the relevant layer is settled.

## Task 1: Prove a canonical WorkspaceViewport

Create a feature-flagged prototype, disabled by default:

- Add `scenes/workspace_viewport.tscn` and `scripts/workspace_viewport.gd`.
- The full-resolution SubViewport owns the background, graph nodes, connections,
  spline layers, and Graph camera. A full-screen SubViewportContainer displays it
  and forwards input.
- Keep persistent UI and top-level windows outside this viewport.
- Replace hard-coded camera/workspace paths with exported NodePaths or accessors;
  do not leave compatibility paths that silently point at the wrong viewport.
- Add tests for mouse coordinates, graph dragging, connection dragging, selection,
  wheel zoom, camera pan, window resize, and Windows 100%/150% scaling.
- Abort this architecture if input coordinates cannot remain byte-for-byte
  equivalent without broad changes to graph code.

Exit condition: High renders the existing visual baseline and every graph input
test passes with `--layered-blur` enabled.

## Task 2: Generalize the one-shot blur cache

Extract the scheduling now implemented in `scripts/bg.gd` into a reusable
`LayerBlurCache`:

- Inputs: a sharp ViewportTexture, downscale factor, and dirty revision.
- Outputs: sharp and blurred textures plus a `texture_ready(revision)` signal.
- State machine: sharp `UPDATE_ONCE`, then blur `UPDATE_ONCE` on the following
  frame, then both explicitly return to `UPDATE_DISABLED`.
- Coalesce multiple dirty notifications within one frame.
- Keep the previous complete blurred texture published until the new revision is
  ready; never expose the sharp-new/blur-old intermediate frame.
- Use the existing quarter-resolution 4x4 kernel first. A separable or dual-Kawase
  replacement is a later measured change, not part of the migration.

Add a renderer test asserting exactly one sharp render and one blur render per
revision, zero renders while settled, and correct behavior after resize.

## Task 3: Publish workspace blur

- Add global sampler `workspace_blur` and a workspace revision counter.
- Invalidate on graph node transform/appearance changes, connection changes,
  camera center/zoom, background changes, and viewport resize.
- During continuous camera movement, allow one coalesced update per frame. Stop
  immediately when the camera settles.
- Add a cached-workspace shader wrapper that samples `workspace_blur`; do not add
  another `hint_screen_texture`.
- Route UI panels that visually sit directly over the workspace to this sampler.
- Keep High on `block_screen.gdshader` and Low on flat glass for an immediate
  fallback and visual comparison.

Exit condition: Medium panels show nodes and connections behind them, no effective
screen-texture sampler exists in Medium, and idle viewports remain disabled.

## Task 4: Add the persistent UI composite

Create `UiBaseViewport` only after WorkspaceViewport is stable:

- It displays `workspace_sharp` and owns persistent UI that may appear behind a
  top-level window.
- UI panels inside it may sample `workspace_blur`, so there is no feedback loop.
- A second `LayerBlurCache` produces `ui_blur` from the completed UI base.
- Top-level windows sample `ui_blur` through a dedicated material wrapper.
- A workspace revision automatically invalidates UI; a UI-only change invalidates
  UI without rerendering workspace.

The dependency chain is strictly one-way:

```text
workspace revision -> workspace sharp -> workspace blur
                  -> UI sharp (samples workspace outputs) -> UI blur
                  -> top-level windows (sample UI blur)
```

Exit condition: a dialog blurs both graph content and persistent UI beneath it,
while ordinary UI panels blur only the workspace.

## Task 5: Handle nested top-level windows without per-window caches

- Keep one modal-underlay cache, not one cache per window.
- Rebuild it only when the modal stack changes or its underlying UI revision
  changes.
- The topmost translucent window samples `modal_underlay_blur`; lower windows are
  part of the cached underlay.
- If no nested translucent window exists, do not allocate this cache.
- Define modal ownership explicitly so a window never samples a texture containing
  itself.

Exit condition: nested dialogs have correct blur with a maximum of three cached
blur textures for the entire application.

## Task 6: Integrate quality modes and fallback

- High: current live backdrop, exact existing visual contract.
- Medium: layered cached blur with no screen reads.
- Low: flat glass, no blur cache allocation.
- If layered initialization or input validation fails, Medium falls back to the
  currently implemented background-only baked blur.
- Runtime High -> Medium -> Low -> High switching must free unused SubViewports and
  restore the exact High shader source and MSAA value.

## Task 7: Verification and rollout

Measure on the available Intel UHD monoblock and then on school hardware:

- Five-node scene idle for 10 minutes.
- Continuous graph pan/zoom for 2 minutes.
- Dense-layer input-field spam for 10 minutes.
- Repeated modal open/close and nested dialogs.
- Simulation and Dataset idle.

Record FPS, process RAM, shared GPU memory when available, drawn frames per second,
and whether `dxgmms2.sys` or a display-driver reset appears in Event Viewer. Run
High, current Medium background-only, and layered Medium from the same build.

The layered implementation ships only if:

- High remains within the existing pixel-comparison threshold.
- Medium has no `hint_screen_texture` path.
- Idle drawn frames approach zero.
- Memory plateaus during the Dense input spam test.
- Layered Medium is not slower than the current background-only Medium by more
  than 15% during continuous camera motion.

## Recommended delivery order

Ship the optimization already merged first. Implement Tasks 1-3 as the next
milestone; this provides graph-aware blur for most UI without touching top-level
window composition. Treat Tasks 4-5 as a separate milestone because moving the UI
into a canonical viewport carries most of the input and lifecycle risk.
