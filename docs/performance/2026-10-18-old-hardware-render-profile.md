# Neuralese on old hardware: where the frame goes

Date: 2026-10-18. Branch `robot-integration` (ce2bbb5 plus uncommitted robot work;
no rendering code changed). All timings are from the low-performance proxy, as
agreed: WSL Ubuntu 24.04, official Godot 4.7.1 Linux, Vulkan **Mobile** on Mesa
**llvmpipe** (Mesa 25.2.8, LLVM 20), 4 CPUs (`yernar` affinity 0-3), 4 GB, no
swap, 1280x720 unless stated. Project: built-in Car Track (15 graphs), the
proxy's own isolated user data.

## Headline

1. **High is slow for three reasons, and only three.** With 2D MSAA off,
   screen copies off and the 9-tap Gaussian off, High costs exactly what Medium
   costs on every screen measured (graph, dialog, simulation, datasets).
2. **MSAA 4x is the largest single cost** (+31-44 ms GPU per frame on
   llvmpipe), more than all blur work together. It is mostly redundant:
   splines are `Line2D.antialiased`, panels antialias their own edges in the
   shader. MSAA 2x costs ~2 ms.
3. **Screen copies are second** (+8 ms on the graph, +19-31 ms on the dialog,
   simulation and dataset screens). Godot makes one full-screen copy, plus a
   Gaussian blur of every mip level, for **each CanvasLayer** that contains a
   screen-reading panel. The top bar already limits its copy to a rectangle;
   dialogs, the simulation and the dataset tab copy the whole screen.
4. **The 9-tap Gaussian in the panel shader is cheap** (3-6 ms).
5. **Medium and Low are the same speed** (within 0-10%, both resolutions).
6. **Idle is clean**: after ~5 s of settling the app draws 0 frames per second.
7. **Scripts are ~6 ms of a ~37 ms Medium frame** while panning (llvmpipe CPU).
   The rest of the frame outside the GPU time is mostly the proxy's own window
   output and X11 pointer queries, which do not exist on Windows.

## Method

`/.superpowers/low-perf-proxy/bench_render_matrix.tscn` instances
`scenes/project.tscn`, dismisses startup dialogs, loads Car Track, and measures
cases with low-processor mode and VSync off (frame time = work):

- `graph_idle`: graph tab, camera nudged 0.05 px per frame (forces a redraw);
- `graph_pan`: graph tab, camera moving 12 px per frame;
- `graph_dialog`: the Export window open over the moving graph;
- `env_pan`: simulation tab, camera moving;
- `ds_idle`: dataset tab;
- `graph_zoom`: camera zoom changing every frame.

Per case it prints the median / p95 of the frame time, the root viewport's GPU
render time (`viewport_get_measured_render_time_gpu`), CPU render time and draw
calls, and a census: visible CanvasLayers, layers whose items read the screen
(each is one full-screen copy), MSAA, processing nodes. Ablation flags:
`--msaa=off|2|4`, `--no-screen-copies` (screen-reading panels switched to the
background-only shader, as Medium does), `--no-gauss` (`gaussian_mix` 0),
`--opaque-root`, `--find-idle-redraw`. 60-80 measured frames per case after 30
warm frames; one process per variant. llvmpipe GPU time is CPU raster time.

Runner (scratch, not committed) sets the proxy environment; since Mesa 25 the
ICD is `/usr/share/vulkan/icd.d/lvp_icd.json` (the committed
`run-wsl-llvmpipe.sh` still names `lvp_icd.x86_64.json` and fails its check).

## Results (llvmpipe, median frame ms / median GPU ms)

### Graphics levels, 1280x720

| Case | High | Medium | Low |
|---|---|---|---|
| Graph, redraw only | 81.5 / 58.0 | 38.4 / 13.5 | 39.6 / 13.2 |
| Graph, camera moving | 82.2 / 58.9 | 39.1 / 13.6 | 39.9 / 13.7 |
| Dialog over moving graph | 124.4 / 104.1 | 47.6 / 22.3 | 43.2 / 18.3 |
| Simulation, camera moving | 94.5 / 80.7 | 33.8 / 11.0 | 32.9 / 10.6 |
| Dataset tab | 86.1 / 71.3 | 27.8 / 11.9 | 27.9 / 11.5 |

### High taken apart, 1280x720

| High variant | Graph moving | Dialog | Simulation | Datasets |
|---|---|---|---|---|
| As shipped (MSAA 4x) | 82.2 / 58.9 | 124.4 / 104.1 | 94.5 / 80.7 | 86.1 / 71.3 |
| MSAA off | 51.3 / 28.2 | 80.6 / 60.2 | 57.7 / 44.9 | 51.7 / 39.4 |
| MSAA 2x | 52.6 / 30.3 | 84.9 / 65.5 | - | - |
| No screen copies | 73.1 / 50.6 | 98.5 / 78.5 | 64.8 / 50.2 | 70.0 / 52.0 |
| No 9-tap Gaussian | 81.5 / 56.0 | 123.3 / 97.6 | 84.5 / 69.9 | 76.5 / 63.0 |
| All three off | **41.0 / 14.3** | **43.9 / 20.9** | **32.1 / 11.0** | **28.8 / 12.8** |
| Medium, for reference | 39.1 / 13.6 | 47.6 / 22.3 | 33.8 / 11.0 | 27.8 / 11.9 |
| Medium + MSAA 4x | 69.3 / 46.9 | 85.3 / 63.3 | - | - |

The simulation and dataset tabs create their panels when shown; their "no
screen copies" and "all three off" rows come from a re-run that applies the
ablation per case (the census confirms 0 screen-reading layers).

### 1920x1080 (school monoblocks are 1080p)

| Case | High | Medium | Low |
|---|---|---|---|
| Graph, camera moving | 161.4 / 123.1 | 52.7 / 20.1 | 53.0 / 18.6 |
| Dialog over moving graph | 249.1 / 221.9 | 62.3 / 33.8 | 58.3 / 30.6 |
| Simulation, camera moving | 182.6 / 159.0 | 54.0 / 20.7 | 50.5 / 18.2 |

High scales with pixel count (about 2x from 720p); Medium/Low grow ~35%.

### Renderer: GL Compatibility on llvmpipe GL, 1280x720

| Case | High | Medium | Low |
|---|---|---|---|
| Graph, camera moving | 51.9 / 34.2 | 43.8 / 19.4 | 45.4 / 19.3 |
| Dialog | 76.8 / 62.0 | 49.5 / 30.1 | 46.3 / 26.4 |
| Simulation | 51.0 / 39.1 | 45.3 / 21.6 | 37.5 / 17.7 |
| Datasets | 45.2 / 35.0 | 31.1 / 18.1 | 29.4 / 17.5 |

High looks faster on GL only because Compatibility has **no 2D MSAA at all**
(`drivers/gles3/storage/texture_storage.cpp`: "2D MSAA is not yet supported
for GLES3"). At equal settings (Medium/Low) Vulkan Mobile is 5-25% faster on
llvmpipe. llvmpipe does not reproduce Intel's Windows drivers, which decide
this question on real machines (see Research).

### Other measurements

- CanvasLayers with visible items: 7 on the graph (layers 0, 126, 125, -127,
  -124, -128, -128), 8 with a dialog, 6 in the simulation, 5 on datasets.
- Screen-reading layers on High: graph 1 (top bar, rectangle copy), dialog +1
  (full screen), simulation 2, datasets 2 (one in the root canvas).
- Idle: 0 frames drawn per second once settled, with any one script's
  processing disabled or none. The 2-8 frames/s seen right after loading are
  settling animations.
- Zoom vs pan (Medium): 40.7 vs 39.2 ms median, 57 vs 52 ms p95. The
  rasterized JetBrains fonts (no MSDF) do not cause notable zoom stutter here.
- Opaque root viewport (Low): 39.3 vs 39.9 ms. `transparent_background` is free.
- Reported video memory: Medium 90 MB, High 104 MB at 720p; 109 vs 141 MB at
  1080p (High adds the MSAA buffer and the backbuffer mip chain).

### CPU side (Medium, graph moving, Godot local script profiler)

`--debug --profiling`, 11 one-second samples during the moving-camera case:
frame ~37 ms (instrumented), scripts 6.4-8.9 ms. Per frame:

| Function | ms |
|---|---|
| `graph_manager.gd:1359 _process` (connection/graph hit tests, per-graph visibility) | 2.42 |
| `local_training_worker.gd:120 _poll_bootstrap` (*proxy artifact*: the Windows Python worker cannot start in WSL, so it polls a file every frame until timeout) | 1.16 |
| `Connection.is_mouse_inside` | 0.66 |
| `NodePalette._process` | 0.57 |
| `graph_manager._top_graph_under_mouse` | 0.30 |
| 72 `BlockComponent._process` together | ~0.3 |

What remains between frame time and GPU + scripts (~17-19 ms on Medium) is the
proxy's window output (WSLg/llvmpipe present) and X11 pointer queries; an
earlier investigation measured those at ~9 ms and ~7.7 ms per frame
(`codex/layered-blur-prototype`, docs/performance/2026-10-06-root-render-bottlenecks.md).
On Windows `DisplayServerWindows::mouse_get_position` is `GetCursorPos` plus an
`EnumDisplayMonitors` walk per call: much cheaper than X11, but still per call.

## Why (Godot 4.7.1 source)

- **One copy per CanvasLayer.** `RendererViewport::_draw_viewport` renders each
  canvas (CanvasLayer) with its own `render_canvas` call;
  `RendererCanvasRenderRD::canvas_render_items` resets
  `material_screen_texture_cached` at the start of each call and copies the
  whole render target to the back buffer before the first screen-reading item
  of that canvas. A `BackBufferCopy` with a rect limits both the copy and the
  mip blur to that rect (`render_target_copy_to_back_buffer(region, ...)`).
- **Mipmaps are a Gaussian chain.** With a mipmapped `hint_screen_texture`
  (`block_screen.gdshader` uses `filter_linear_mipmap`),
  `TextureStorage::render_target_copy_to_back_buffer` runs `gaussian_blur`
  into every mip level after the copy. The GL renderer does the same.
- **MSAA is paid per layer.** Each canvas is a separate draw list on the
  multisampled framebuffer with a resolve attachment; every draw-list end
  resolves the whole screen, and every screen copy splits a draw list again.
  7-8 layers means 7-8 full-screen resolves per frame on High.
- **Low-processor mode** (`glob.gd`) only skips redraws when nothing changed
  and caps at ~145 FPS; since 4.x it subtracts the frame's own time from the
  sleep (`OS::add_frame_delay`), so it adds no latency on slow machines.
- Upstream confirmation: Godot issue #108935 (Intel UHD, i7-10510U): one empty
  full-screen screen-texture read costs ~4 ms, two layers ~7 ms, mipmapped
  ~8 ms; rendering lead clayjohn: "especially expensive on fill-rate bound
  hardware like mobile phones and iGPUs ... strongly correlates with your
  screen resolution ... rely on the BackBufferCopy node with a limited rect";
  a Viewport texture is cheaper than the screen texture. Proposal #7641:
  screen-texture blur "prohibitively slow on some devices", a 1/2-resolution
  viewport makes it feasible.

## Research: the target hardware

- The team's reference device is an Intel **UHD 730** monoblock with **8 GB**
  shared RAM (the school `dxgmms2.sys` BSOD report). UHD 730: 24 EUs (192
  ALUs), about half of Iris Xe 96EU in 3DMark Time Spy (608 vs 1298).
- Budget school-class devices on sale in Kazakhstan: Intel N100-class
  monoblocks with 8 GB DDR4 (e.g. MSI PRO AP162T), Celeron N4000/N4020/N5100/
  J4105 laptops with 4-8 GB (Kaspi, Technodom, OZON.kz "ноутбуки для школы").
  Alder Lake-N (N100) supports **single-channel memory only**, 24 EUs at
  450-750 MHz, at most 38.4 GB/s (DDR5-4800) or 25.6 GB/s (DDR4-3200) shared
  between CPU and GPU. Integrated GPUs are bandwidth-bound; single channel
  costs them double-digit percentages.
- Ministry orders: No. 79 (2020-03-02) sets minimum requirements for hardware
  in education organisations; No. 456 (2022-11-14) for digital objects. Their
  hardware annexes could not be retrieved here; goszakup.gov.kz tenders would
  give exact school configurations.
- What full-screen passes mean on such machines (estimate, not measured): one
  1920x1080 RGBA8 read + write is ~16.6 MB; a 4x MSAA buffer is ~33 MB, and
  High resolves it per CanvasLayer. A few hundred MB per frame of traffic is a
  large share of a 25-38 GB/s single-channel budget at 30 FPS.

## Recommendations, in order

1. **Turn 2D MSAA off on High (or use 2x).** Saves 31-44 ms GPU per frame on
   llvmpipe; 2x keeps most of the saving. Before: check the few things drawn
   without antialiasing (e.g. `scripts/arrow_2d.gd` uses
   `draw_line(..., false)`, `Polygon2D`), and give them `antialiased = true`;
   Godot's 2D antialiasing docs recommend per-node antialiasing over MSAA for
   cost. Caveat: on real Intel GPUs MSAA has hardware compression, so the gain
   may be smaller than on llvmpipe; GL Compatibility (the fallback for GPUs
   without Vulkan) never had 2D MSAA, so those machines already render this way.
2. **Stop full-screen copies for dialogs and the simulation/dataset panels.**
   Cheapest: a rectangular `BackBufferCopy` sized to the window plus the blur
   halo, as `top_panel.gd` already does for the top bar (copy and mip blur are
   then limited to the rectangle). Caveats: still one copy per CanvasLayer; the
   rectangle must cover the kernel's reach or edges sample stale pixels; the
   mip chain of a small rectangle is cheap but the blur radius is then limited
   by its size. For modal windows, the workspace behind rarely changes: blurring
   it once when the window opens and sampling that texture would remove the
   per-frame copy entirely (caveat: anything animating behind looks frozen).
   The shared low-resolution backdrop (the layered prototype) is the general
   solution and its speed is proven, but its caveats are real: one-frame
   ordering between SubViewports (#65545), never `get_image()` in the loop
   (#75877), input re-routing, and render-target memory on 8 GB shared RAM.
3. **Leave the 9-tap Gaussian**: 3-6 ms on llvmpipe, not worth visual risk now.
4. **Make Low mean something, or drop it.** It is not faster than Medium. Real
   savings left at Medium/Low are elsewhere: the background SubViewport is
   re-rendered at full resolution on every camera move at all levels
   (`scripts/bg.gd` signature includes camera centre and zoom), and the root
   still draws the full-screen background image and grid.
5. **Read the pointer once per frame.** `graph_manager._process`,
   `Connection.is_mouse_inside`, block components and the palette each query
   the mouse; one shared sample per frame removes repeated `GetCursorPos` +
   `EnumDisplayMonitors` calls on Windows (and ~7.7 ms of X11 round trips on
   the proxy). Cheap and invisible.
6. **Renderer on real Intel machines (not measurable here).** Godot's own
   proposal to make Direct3D 12 the Windows default (#12234, closed) says Intel
   has the Vulkan driver that "runs into the most issues in Godot" and that
   D3D12 "may perform better on those GPUs"; Vulkan on Windows presents without
   the DXGI flip model (#5692), D3D12 presents through DXGI. A D3D12 run of the
   same bench on the UHD 730 monoblock is the next measurement worth doing;
   Godot falls back D3D12 -> Vulkan -> OpenGL automatically. A user report in
   that thread saw D3D12 much slower than Vulkan in a 3D scene, so measure
   before switching.
7. **Resolution.** On 1080p monoblocks High is 3-4x Medium. If Low should be a
   real low-end mode, rendering the workspace at a lower internal resolution
   is the lever (caveat: text sharpness; keep UI text at native resolution).

## Not covered / open

- No real Intel numbers: the proxy cannot show Intel driver, WDDM or
  presentation costs, nor the `dxgmms2.sys` crash (video memory manager).
- Graph size: Car Track has 15 graphs; a 5-node school graph was measured in
  the earlier prototype work (Legacy High 131 ms, Medium 52 ms, Low 48 ms,
  2 CPUs, `docs/performance/2026-10-05-camera-render-bottlenecks.md` there).
- Text: MSDF for the JetBrains fonts was not tried (zoom showed no stutter).

## Reproduce

```bash
# from Windows: one run per argument set, results appended to OUT
wsl -d Ubuntu -- env OUT=/mnt/c/.../llvm_720.txt bash bench_matrix_llvmpipe.sh \
  "--graphics=high --frames=80" "--graphics=medium --frames=80" \
  "--graphics=high --frames=80 --msaa=off --no-screen-copies --no-gauss"
```

The runner and raw logs are in the session scratchpad; the bench scenes
(`bench_render_matrix`, `bench_robot_lidar`, `bench_robot_lidar_app`) are
untracked files in `.superpowers/low-perf-proxy/`.

## Sources

- Godot 4.7.1 source: `servers/rendering/renderer_viewport.cpp`,
  `servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp`,
  `servers/rendering/renderer_rd/storage_rd/texture_storage.cpp`,
  `drivers/gles3/storage/texture_storage.cpp`, `core/os/os.cpp`,
  `platform/windows/display_server_windows.cpp`, `scene/main/viewport.cpp`.
- https://github.com/godotengine/godot/issues/108935
- https://github.com/godotengine/godot-proposals/issues/7641
- https://github.com/godotengine/godot-proposals/issues/12234
- https://github.com/godotengine/godot-proposals/issues/5692
- https://github.com/godotengine/godot/issues/72823
- https://github.com/godotengine/godot/issues/90030
- https://docs.godotengine.org/en/4.7/tutorials/shaders/screen-reading_shaders.html
- https://docs.godotengine.org/en/4.7/tutorials/2d/2d_antialiasing.html
- https://docs.godotengine.org/en/4.7/tutorials/rendering/renderers.html
- https://docs.godotengine.org/en/4.7/tutorials/ui/gui_using_fonts.html
- https://www.notebookcheck.net/N100-vs-Celeron-N4020-vs-N95_14932_11535_14981.247596.0.html
- https://www.eatyourbytes.com/cpu-detail/intel-n100/
- https://nanoreview.net/ru/gpu-compare/intel-uhd-graphics-730-vs-intel-iris-xe-graphics-g7-96eu
- https://www.dns-shop.kz/catalog/17a8936316404e77/monobloki/
- https://ozon.kz/category/noutbuki-dlya-shkoly/
- https://www.technodom.kz/catalog/noutbuki-i-komp-jutery/noutbuki-i-aksessuary/noutbuki/f/cl-notebooks-processor-series-processor/intel-celeron
- https://online.zakon.kz/Document/?doc_id=33043063 (order No. 79)
- https://prg.kz/Document/?doc_id=37774940 (order No. 456)
