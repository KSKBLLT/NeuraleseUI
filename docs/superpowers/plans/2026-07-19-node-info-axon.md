# Node Info and Axon Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static Input2D info popup with complete localized documentation for every active node and add a one-click, localized Ask Axon flow with a visual-only source label.

**Architecture:** `JasonDocs` remains the authored source of truth. Python tooling compiles it into one exportable runtime JSON, a focused GDScript catalog localizes and renders it, a dedicated info-menu controller handles the selected node, and `AIHelpMenu` accepts a one-shot context request while keeping source metadata separate from API text.

**Tech Stack:** Godot 4.7, GDScript, Python 3 standard library, JasonDocs JSON schema, existing SplashMenu/BlockComponent/Axon APIs.

## Global Constraints

- Do not add a hardcoded node-type switch or a second manually authored documentation registry.
- Keep `JasonDocs/<node_id>/node.json` as the only authored source of node information.
- Keep the existing Axon API request and response formats unchanged.
- Localize user-facing text for `en`, `ru`, and `kz`, with English fallback.
- The source label is presentation metadata and must never be included in `glob.update_message_stream()` text.
- Use the existing login splash before opening Axon for unauthenticated users.
- Preserve all existing graph, node-palette, macOS input, updater, and dialog behavior.

---

### Task 1: Build an Exportable Runtime Catalog

**Files:**
- Create: `tools/jasondocs/runtime_catalog.py`
- Create: `tests/jasondocs/test_runtime_catalog.py`
- Modify: `tools/jasondocs/cli.py`
- Modify: `export_presets.cfg`
- Generate: `resources/node_info_catalog.json`

**Interfaces:**
- Consumes: validated documents from `JasonDocs/<node_id>/node.json`.
- Produces: `build_runtime_catalog(docs_root: Path) -> dict[str, Any]`, `write_runtime_catalog(docs_root: Path, target: Path) -> None`, and a `python -m tools.jasondocs runtime` command.
- The catalog shape is `{"schema_version": 1, "nodes": {node_id: {"status", "generated", "docs"}}}` with generated metadata limited to `node_id`, `title_candidates`, `ports`, and `settings`.

- [x] **Step 1: Write the failing Python tests**

Test a two-node temporary JasonDocs tree and assert deterministic key ordering, retained localized docs, stripped scene-only metadata, and stale-artifact detection:

```python
class RuntimeCatalogTests(unittest.TestCase):
    def test_builds_compact_catalog_from_jasondocs(self):
        catalog = build_runtime_catalog(self.docs_root)
        self.assertEqual(list(catalog["nodes"]), ["input", "run_model"])
        self.assertEqual(catalog["nodes"]["input"]["docs"]["title"]["ru"], "Ввод2D")
        self.assertNotIn("scene_path", catalog["nodes"]["input"]["generated"])

    def test_reports_stale_runtime_catalog(self):
        self.target.write_text("{}", encoding="utf-8")
        self.assertFalse(runtime_catalog_is_current(self.docs_root, self.target))
```

- [x] **Step 2: Run the test and verify RED**

Run: `python3 -m unittest tests.jasondocs.test_runtime_catalog -v`

Expected: import failure for `tools.jasondocs.runtime_catalog`.

- [x] **Step 3: Implement the catalog compiler and CLI command**

Use JSON parsing and deterministic sorted node directories. Add:

```python
RUNTIME_SCHEMA_VERSION = 1

def build_runtime_catalog(docs_root: Path) -> dict[str, Any]:
    nodes: dict[str, Any] = {}
    for child in sorted(docs_root.iterdir(), key=lambda path: path.name):
        source = child / "node.json"
        if not source.exists():
            continue
        document = load_json(source)
        generated = document.get("generated", {})
        nodes[document["node_id"]] = {
            "status": document.get("status", "stable"),
            "generated": {
                "node_id": generated.get("node_id", document["node_id"]),
                "title_candidates": generated.get("title_candidates", {}),
                "ports": generated.get("ports", []),
                "settings": generated.get("settings", []),
            },
            "docs": document.get("docs", {}),
        }
    return {"schema_version": RUNTIME_SCHEMA_VERSION, "nodes": nodes}
```

`cmd_runtime` validates JasonDocs, writes `resources/node_info_catalog.json`, and prints its node count. `cmd_validate` also fails when the committed runtime catalog is stale.

- [x] **Step 4: Include the runtime JSON in every export preset**

Set every preset's `include_filter` to include `resources/node_info_catalog.json`, preserving existing `*.yaml` filters on Windows and macOS.

- [x] **Step 5: Run tests and generate the first artifact**

Run:

```bash
python3 -m unittest tests.jasondocs.test_runtime_catalog -v
python3 -m tools.jasondocs runtime
```

Expected: unit tests pass and the runtime command writes one catalog containing all active JasonDocs nodes.

- [x] **Step 6: Commit**

```bash
git add tools/jasondocs/runtime_catalog.py tools/jasondocs/cli.py tests/jasondocs/test_runtime_catalog.py resources/node_info_catalog.json export_presets.cfg
git commit -m "feat: compile node docs for runtime"
```

### Task 2: Add the Localized Node Info Catalog

**Files:**
- Create: `scripts/node_info_catalog.gd`
- Create: `tests/godot/test_node_info_catalog.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Consumes: `res://resources/node_info_catalog.json`.
- Produces: static `get_info(node_id: String, lang: String) -> Dictionary`, `render_bbcode(info: Dictionary) -> String`, `action_label(lang: String) -> String`, and `make_axon_request(info: Dictionary, lang: String, request_id: String) -> Dictionary`.
- A successful info dictionary contains `available`, `node_id`, `title`, `summary`, `operation`, `ports`, `settings`, and `compact`.

- [x] **Step 1: Write the failing Godot test**

The test loads the real generated catalog and checks different content for `input` and `run_model`, three-language templates, English fallback, BBCode escaping, and unavailable-node behavior:

```gdscript
var input_info := NodeInfoCatalog.get_info("input", "ru")
var run_info := NodeInfoCatalog.get_info("run_model", "ru")
_expect(input_info.available, "input docs available")
_expect(input_info.title != run_info.title, "node-specific titles")
_expect_equal(NodeInfoCatalog.action_label("kz"), "Аксоннан сұрау", "Kazakh action")
var request := NodeInfoCatalog.make_axon_request(run_info, "en", "req-1")
_expect_equal(request.question, "What does %s do in this context and overall?" % run_info.title, "English question")
_expect_equal(request.source_label, "From %s info" % run_info.title, "English source")
_expect(NodeInfoCatalog.render_bbcode({"summary": "[bad]"}).contains("[lb]bad[rb]"), "BBCode escaping")
```

- [x] **Step 2: Run the test and verify RED**

Run: `godot --headless --path . --quit-after 300 --script tests/godot/test_node_info_catalog.gd`

Expected: parse/load failure because `NodeInfoCatalog` does not exist.

- [x] **Step 3: Implement the catalog**

Implement one cached JSON load, localized lookup with `lang -> en -> fallback`, normalized port/setting rows, safe BBCode escaping, and exact templates:

```gdscript
const CATALOG_PATH := "res://resources/node_info_catalog.json"
const ACTION_LABELS := {"en": "Ask Axon", "ru": "Спросить Аксона", "kz": "Аксоннан сұрау"}
const QUESTION_TEMPLATES := {
    "en": "What does %s do in this context and overall?",
    "ru": "Что делает %s в этом контексте и в целом?",
    "kz": "%s осы контексте және жалпы не істейді?",
}
const SOURCE_TEMPLATES := {
    "en": "From %s info",
    "ru": "Из описания %s",
    "kz": "%s сипаттамасынан",
}
```

Unknown IDs return `available = false` with a localized unavailable message and never throw.

- [x] **Step 4: Register and run the test**

Add `test_node_info_catalog.gd:PASS test_node_info_catalog` to `tests/godot/run_all.sh`, then run the test directly and through `run_all.sh`.

- [x] **Step 5: Commit**

```bash
git add scripts/node_info_catalog.gd tests/godot/test_node_info_catalog.gd tests/godot/run_all.sh
git commit -m "feat: load localized node information"
```

### Task 3: Complete Documentation for Every Active Node

**Files:**
- Modify: all active `JasonDocs/*/node.json` documents.
- Regenerate: `resources/node_info_catalog.json`

**Interfaces:**
- Consumes: generated ports/settings and factual behavior from node scenes/scripts; matching concepts from `neuralese-backend/axon/node_docs_compact.md` are reference material only.
- Produces: non-empty `title`, `summary`, `operation`, `compact.body`, every generated port description, and every generated setting description in `en`, `ru`, and `kz`.

- [x] **Step 1: Verify current validation fails for missing prose**

Run: `python3 -m tools.jasondocs validate`

Expected: errors listing missing trilingual prose for active nodes.

- [x] **Step 2: Author model-building node documentation**

Complete `neuron`, `layer`, `conv2d`, `maxpool`, `dropout`, `softmax`, `flatten`, `reshape2d`, `concat`, and `augment_tf`. Each operation must explain tensor transformation, each port description must name direction and accepted data, and each setting description must explain its effect without claiming unsupported behavior.

- [x] **Step 3: Author input/output node documentation**

Complete `input`, `input_1d`, `classifier`, `model_name`, and `lua_env`. Explain image/tabular input, labels, model naming, and Lua environment responsibilities using current generated metadata.

- [x] **Step 4: Author training-flow node documentation**

Complete `dataset`, `train_begin`, `run_model`, `output_map`, `train_input`, and `train_rl`. Describe the actual graph role and every generated port/setting; do not introduce inference behavior absent from the node.

- [x] **Step 5: Regenerate and validate**

Run:

```bash
python3 -m tools.jasondocs sync
python3 -m tools.jasondocs runtime
python3 -m tools.jasondocs validate
```

Expected: `JasonDocs validation passed`, generated metadata remains current, and manual `docs` prose survives sync.

- [x] **Step 6: Run node-info tests and commit**

```bash
godot --headless --path . --quit-after 300 --script tests/godot/test_node_info_catalog.gd
git add JasonDocs resources/node_info_catalog.json
git commit -m "docs: describe every graph node"
```

### Task 4: Replace the Static Get Info Popup

**Files:**
- Create: `scripts/node_info_menu.gd`
- Create: `tests/godot/test_node_info_menu.gd`
- Modify: `scripts/edit_graph.gd`
- Modify: `scenes/menus.tscn`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Consumes: `NodeInfoCatalog.get_info()` and selected Graph metadata `created_with`.
- Produces: `show_for_node(node: Graph, at: Vector2) -> void` and an `axon_context_requested(request: Dictionary)` signal.

- [x] **Step 1: Write the failing scene/controller test**

Instantiate `scenes/menus.tscn` and assert that `debug_info` uses `node_info_menu.gd`, contains `top_button` with hint `ask_axon`, has no `bottom_button`, and renders different content after `configure_for_node_id("input")` and `configure_for_node_id("run_model")`.

- [x] **Step 2: Run the test and verify RED**

Run: `godot --headless --path . --quit-after 300 --script tests/godot/test_node_info_menu.gd`

Expected: missing controller/method and existing `bottom_button` assertion failure.

- [x] **Step 3: Implement `NodeInfoMenu`**

The controller stores the normalized info, updates menu title/body/action label, disables Ask Axon for unavailable docs, and emits one request on the top button:

```gdscript
extends BlockComponent
class_name NodeInfoMenu

signal axon_context_requested(request: Dictionary)

func configure_for_node_id(node_id: String, lang: String = glob.get_lang()) -> void:
    current_info = NodeInfoCatalog.get_info(node_id, lang)
    text = "%s node *" % current_info.title
    $rich_text_row/RichTextLabel.text = NodeInfoCatalog.render_bbcode(current_info)
    $top_button.text = NodeInfoCatalog.action_label(lang)

func show_for_node(node: Graph, at: Vector2) -> void:
    configure_for_node_id(str(node.get_meta("created_with", "")))
    menu_show(pos_clamp(at))
```

- [x] **Step 4: Update the menu scene and caller**

Attach the controller, remove `bottom_button`, change the top hint to `ask_axon`, and replace the static `edit_graph.gd` opening block with `info_menu.show_for_node(of_node, position)`.

- [x] **Step 5: Run direct and full tests**

Register the test in `run_all.sh`, run it directly, then run all Godot tests.

- [x] **Step 6: Commit**

```bash
git add scripts/node_info_menu.gd scripts/edit_graph.gd scenes/menus.tscn tests/godot/test_node_info_menu.gd tests/godot/run_all.sh
git commit -m "feat: show selected node documentation"
```

### Task 5: Send a One-Shot Node Question to Axon

**Files:**
- Create: `scripts/axon_context_gate.gd`
- Create: `tests/godot/test_axon_context.gd`
- Modify: `scripts/node_info_menu.gd`
- Modify: `scripts/ai_help.gd`
- Modify: `scenes/ai_help.tscn`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Consumes: request dictionaries with `request_id`, `question`, and `source_label`.
- Produces: `AxonContextGate.consume(request: Dictionary) -> bool`, `AIHelpMenu.queue_context_request(request: Dictionary) -> bool`, and `AIHelpMenu.send_message(text: String, source_label: String = "")`.

- [x] **Step 1: Write failing gate and presentation tests**

Verify the same request ID is consumed only once, different IDs are accepted, user-message source labels are optional, and the API text remains exactly the question:

```gdscript
var gate := AxonContextGate.new()
_expect(gate.consume({"request_id": "a"}), "first request accepted")
_expect(not gate.consume({"request_id": "a"}), "duplicate rejected")
_expect(gate.consume({"request_id": "b"}), "new request accepted")

var payload := AxonContextGate.presentation({
    "question": "What does RunModel do?",
    "source_label": "From RunModel info",
})
_expect_equal(payload.api_text, "What does RunModel do?", "API text")
_expect_equal(payload.message.source_label, "From RunModel info", "visual source")
```

- [x] **Step 2: Run the test and verify RED**

Run: `godot --headless --path . --quit-after 300 --script tests/godot/test_axon_context.gd`

Expected: load failure because `AxonContextGate` does not exist.

- [x] **Step 3: Implement the one-shot gate**

Store consumed non-empty request IDs in a dictionary. `presentation()` returns separate `api_text` and `message` values and never concatenates `source_label` into `api_text`.

- [x] **Step 4: Add source metadata to the user-message scene**

Wrap the user RichTextLabel in a `VBoxContainer`, add a hidden `Label` named `source`, and preserve the existing message bubble style. `AIHelpMenu.add_message()` reveals it only when `source_label` is non-empty and stores the duplicated message root for cleanup.

- [x] **Step 5: Extend Axon without changing its backend call**

Change `send_message` to:

```gdscript
func send_message(text: String, source_label: String = ""):
    add_message({"user": true, "text": text, "source_label": source_label, "id": user_id})
    # Existing cache and pending-message logic remains unchanged.
    var sock = await glob.update_message_stream(text, chat_id, text_receive, glob.def, false, user_id, ai_id)
```

Add `queue_context_request()` to consume once and defer `send_message(request.question, request.source_label)` until the Axon scene is ready.

- [x] **Step 6: Connect login and opening flow**

On `axon_context_requested`, hide the info menu, invoke the existing login splash when needed, stop on canceled login, open `ai_help`, and pass the request to `queue_context_request()`. Generate a unique request ID per button release.

- [x] **Step 7: Run direct and full tests**

Register `test_axon_context.gd` in `run_all.sh`. Run it directly, then run the complete Godot suite and verify no network call occurs in tests.

- [x] **Step 8: Commit**

```bash
git add scripts/axon_context_gate.gd scripts/node_info_menu.gd scripts/ai_help.gd scenes/ai_help.tscn tests/godot/test_axon_context.gd tests/godot/run_all.sh
git commit -m "feat: ask Axon from node information"
```

### Task 6: Final Regression and Packaging Verification

**Files:**
- Modify only if verification finds a feature-related defect.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified branch state ready to push to the existing draft PR.

- [x] **Step 1: Validate authored and generated docs**

Run:

```bash
python3 -m tools.jasondocs validate
python3 -m unittest tests.jasondocs.test_runtime_catalog -v
git diff --check
```

- [x] **Step 2: Run all Godot tests**

Run: `GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot" bash tests/godot/run_all.sh`

Expected: every existing and new marker passes.

- [x] **Step 3: Run project parse/import check**

Run: `"/Applications/Godot.app/Contents/MacOS/Godot" --headless --path . --import --quit-after 300`

Expected: exit code 0 with no new parse errors from modified files.

- [x] **Step 4: Verify runtime artifact and export filters**

Assert the runtime catalog contains exactly the active graph IDs and every export preset includes `resources/node_info_catalog.json`.

- [x] **Step 5: Review scope and commit final fixes if needed**

Inspect `git diff origin/codex/node-palette-drag-drop...HEAD`, confirm no Axon output/backend changes and no unrelated scene churn, then commit only necessary corrections.

- [x] **Step 6: Push the feature branch**

```bash
git push origin codex/node-palette-drag-drop
```

Update draft PR #5 with a concise summary of the Node Info/Axon addition and exact verification commands.
