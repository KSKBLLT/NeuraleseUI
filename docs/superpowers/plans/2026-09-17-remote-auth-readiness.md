# Remote Auth Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let onboarding run immediately while every protected remote feature fails safely and predictably until a real bearer session exists.

**Architecture:** A machine-readable endpoint catalog classifies every REST and WebSocket route. A pure policy layer distinguishes local identity from bearer readiness, shared UI helpers handle interactive errors, and REST/WS transports enforce the same policy as a final fail-closed boundary. A static audit keeps the endpoint inventory complete as the codebase evolves.

**Tech Stack:** Godot 4.7.1, GDScript, Python 3.11, pytest, existing `CookieManager`, `WebAPI`, `Sockets`, and Godot marker-based test runner.

**Spec:** `docs/superpowers/specs/2026-09-17-remote-auth-readiness-design.md`

## Global Constraints

- Do not make onboarding, the tutorial prompt, or local workspace startup await authentication.
- Do not queue or automatically replay a rejected action.
- Show `ui.error` only for an explicit user action; background work must fail silently.
- Keep local projects, datasets, simulations, built-in projects, local training, local inference, and local export independent of authentication.
- A protected request must not create an `HTTPClient`, `HTTPRequest`, `WebSocketPeer`, network thread, or socket connection without a bearer token.
- Do not treat `glob.logged_in()` or `glob._logged_in` as proof of remote authorization.
- Do not stage the untracked DLL, EXE, or log artifacts currently present in the worktree.
- Preserve the existing startup changes in `scripts/startup/profile_onboarding.gd`, `scripts/startup/startup_flow_coordinator.gd`, and their two Godot tests.

---

### Task 1: Define the Endpoint Catalog and Readiness Policy

**Files:**
- Create: `resources/network_endpoint_policy.json`
- Create: `scripts/auth/remote_endpoint_policy.gd`
- Create: `scripts/auth/remote_session_gate.gd`
- Create: `tests/godot/test_remote_endpoint_policy.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Produces: `RemoteEndpointPolicy.rest_access(page: String) -> int`, `RemoteEndpointPolicy.websocket_access(page: String) -> int`, `RemoteEndpointPolicy.canonical_rest(page: String) -> String`, and `RemoteEndpointPolicy.canonical_websocket(page: String) -> String`.
- Produces: `RemoteSessionGate.has_bearer(headers: Dictionary) -> bool` and `RemoteSessionGate.error_text(language: String) -> String`.
- Access values are `PUBLIC`, `AUTH_REQUIRED`, `EXTERNAL_PUBLIC`, and `UNKNOWN`; unknown Neuralese routes are denied.

- [ ] **Step 1: Write the failing policy test**

Create a marker-based `SceneTree` test covering aliases, protected routes, public routes, absolute URLs, unknown internal paths, bearer validation, and all three localized messages:

```gdscript
const EndpointPolicy = preload("res://scripts/auth/remote_endpoint_policy.gd")
const SessionGate = preload("res://scripts/auth/remote_session_gate.gd")

func _run() -> void:
	_expect_equal(
		EndpointPolicy.canonical_rest("ask_once"),
		"api/axon/ask-once",
		"Axon alias is canonical"
	)
	_expect_equal(
		EndpointPolicy.rest_access("classroom/join"),
		EndpointPolicy.Access.AUTH_REQUIRED,
		"classroom join is protected"
	)
	_expect_equal(
		EndpointPolicy.rest_access("health"),
		EndpointPolicy.Access.PUBLIC,
		"health is public"
	)
	_expect_equal(
		EndpointPolicy.rest_access("api/new-unclassified-route"),
		EndpointPolicy.Access.UNKNOWN,
		"unknown internal route fails closed"
	)
	_expect(SessionGate.has_bearer({"Authorization": "Bearer token"}), "bearer accepted")
	_expect(not SessionGate.has_bearer({"user": "local child"}), "local identity rejected")
	_expect(not SessionGate.error_text("ru").is_empty(), "Russian error copy")
	_expect(not SessionGate.error_text("en").is_empty(), "English error copy")
	_expect(not SessionGate.error_text("kz").is_empty(), "Kazakh error copy")
```

- [ ] **Step 2: Run the test and verify RED**

Run: `& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_remote_endpoint_policy.gd`

Expected: load failure because both policy scripts are absent.

- [ ] **Step 3: Add the machine-readable endpoint catalog**

Create schema version 1 with the complete current aliases from `web.gd` and `sockets.gd`, the route classifications, and the narrow audit allowlists:

```json
{
  "schema_version": 1,
  "rest": {
    "aliases": {
      "save": "api/projects/save",
      "project": "api/projects/get",
      "delete_project": "api/projects/delete",
      "project_list": "api/projects/list",
      "get_chat": "api/projects/get-chat",
      "clear_chat": "api/projects/clear-chat",
      "reg_dataset": "api/projects/register-dataset",
      "datasets": "api/datasets",
      "ask_once": "api/axon/ask-once",
      "classroom/create": "api/classrooms/create",
      "classroom/join": "api/classrooms/join",
      "classroom/meta": "api/classrooms/meta",
      "classroom/leave": "api/classrooms/leave",
      "classroom/update_meta": "api/classrooms/update-meta",
      "classroom/update_lessons": "api/classrooms/update-lessons",
      "classroom/lesson_auto_project": "api/classrooms/lesson-auto-project",
      "classroom/update_state": "api/classrooms/update-state",
      "classroom/mark_explanation_made": "api/classrooms/mark-explanation-made",
      "classroom/get_state": "api/classrooms/get-state",
      "classroom/events": "api/classrooms/events"
    },
    "public": ["health", "login", "create_user", "api/pilot/onboarding/register"],
    "auth_required": [
      "api/projects/save",
      "api/projects/get",
      "api/projects/delete",
      "api/projects/list",
      "api/projects/get-chat",
      "api/projects/clear-chat",
      "api/projects/register-dataset",
      "api/datasets",
      "api/axon/ask-once",
      "api/classrooms/create",
      "api/classrooms/join",
      "api/classrooms/meta",
      "api/classrooms/leave",
      "api/classrooms/update-meta",
      "api/classrooms/update-lessons",
      "api/classrooms/lesson-auto-project",
      "api/classrooms/update-state",
      "api/classrooms/mark-explanation-made",
      "api/classrooms/get-state",
      "api/classrooms/events",
      "export",
      "delete_ctx",
      "cache_ds",
      "transcribe_file"
    ]
  },
  "websocket": {
    "aliases": {"ws/talk": "ws/axon/talk"},
    "auth_required": ["ws/axon/talk", "ws/train", "ws/infer", "ws/ds_load"]
  },
  "raw_transport_allowlist": {
    "HTTPClient.new": ["scripts/web.gd"],
    "HTTPRequest.new": ["scripts/auth/auth_session.gd", "scripts/transcriber.gd"],
    "WebSocketPeer.new": ["scripts/socket_connection.gd"],
    "TCPServer.new": ["scripts/auth/oauth_loopback_receiver.gd"],
    "web._request": ["scripts/cookie_manager.gd"]
  },
  "dynamic_high_level_calls": [
    {
      "path": "scripts/glob.gd",
      "function": "download_update",
      "api": "web.GET",
      "access": "external_public"
    },
    {
      "path": "scripts/lanpop.gd",
      "function": "_on_button_pressed",
      "api": "web.HEALTH",
      "access": "external_public"
    }
  ]
}
```

- [ ] **Step 4: Implement the pure policies**

`RemoteEndpointPolicy` loads the JSON once, validates `schema_version == 1`, normalizes leading slashes, applies aliases, treats absolute HTTP(S) URLs as `EXTERNAL_PUBLIC`, and returns `UNKNOWN` for an unlisted relative route. `RemoteSessionGate.has_bearer()` accepts only a non-empty case-sensitive `Bearer ` value after trimming.

Use the exact localized copy from the design spec in `RemoteSessionGate.error_text()` with English fallback.

- [ ] **Step 5: Register and run the test**

Add `test_remote_endpoint_policy.gd:PASS test_remote_endpoint_policy` to `tests/godot/run_all.sh`, run the test directly, then run:

```bash
python -m pytest tests/release -v
python -m tools.node_dev check
```

Expected: the new Godot test and existing Python checks pass.

- [ ] **Step 6: Commit only the policy task**

```bash
git add resources/network_endpoint_policy.json scripts/auth/remote_endpoint_policy.gd scripts/auth/remote_session_gate.gd tests/godot/test_remote_endpoint_policy.gd tests/godot/run_all.sh
git commit -m "feat: define remote endpoint access policy"
```

### Task 2: Enforce Bearer Readiness in REST and WebSocket Transports

**Files:**
- Modify: `scripts/web.gd`
- Modify: `scripts/sockets.gd`
- Modify: `scripts/cookie_manager.gd`
- Modify: `scripts/transcriber.gd`
- Create: `tests/godot/test_remote_transport_guards.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Consumes: Task 1 endpoint classification and `cookies.get_bearer_auth_header()`.
- Produces: `WebAPI._access_headers(page: String, supplied: Dictionary) -> Dictionary` with `{allowed, headers, error_code}`.
- Produces: `Sockets.connect_to(...) -> SocketConnection` as a nullable result; `null` means the protected connection was refused before peer creation.
- A denied REST response uses `{"ok": false, "code": 0, "error_code": "auth_not_ready", "body": PackedByteArray()}`.

- [ ] **Step 1: Write the failing transport test**

Instantiate the transport scripts with injectable auth-header providers. Assert that a protected request with `{}` does not grow `web._threads`, a public request is allowed without bearer, a protected request receives the current bearer header, and a protected WebSocket returns `null` without changing `sockets._conns`.

```gdscript
web.set_auth_header_provider(func() -> Dictionary: return {})
var before := web._threads.size()
var denied = await web.POST("ask_once", {"text": "hello"})
_expect_equal(denied.get("error_code"), "auth_not_ready", "REST denied")
_expect_equal(web._threads.size(), before, "denial creates no thread")

sockets.set_auth_header_provider(func() -> Dictionary: return {})
var socket = sockets.connect_to("ws/talk")
_expect(socket == null, "WebSocket denied")
_expect(sockets._conns.is_empty(), "denial stores no connection")
```

- [ ] **Step 2: Run the test and verify RED**

Run: `& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_remote_transport_guards.gd`

Expected: missing provider/access methods and a protected connection is currently created.

- [ ] **Step 3: Move route canonicalization behind the policy**

Replace the private alias dictionaries in `web.gd` and `sockets.gd` with calls to `RemoteEndpointPolicy`. Keep `_compose_url()` behavior unchanged after canonicalization.

- [ ] **Step 4: Add fail-closed REST preparation**

Before creating `Thread.new()`, classify the original page. For `AUTH_REQUIRED`, ignore caller-provided `Authorization`, obtain `cookies.get_bearer_auth_header()`, validate it with `RemoteSessionGate`, and return the denied asynchronous shape if absent. For `PUBLIC` and approved `EXTERNAL_PUBLIC`, do not attach the Neuralese bearer. For `UNKNOWN`, return `error_code = "unclassified_endpoint"` and log the route.

Preserve the existing `POST`/`JPOST`/`GET`/`GET_SSE` return contracts, including deferred completion for `RequestHandle` callers. Update `_parse_json_response()` to pass through a top-level `error_code`, so `JPOST` callers receive `auth_not_ready` instead of losing it while parsing an empty body.

- [ ] **Step 5: Add fail-closed WebSocket preparation**

Classify before `SocketConnection.new()`. For a protected route, obtain and validate the bearer header internally. Return `null` before constructing a peer when absent; log `auth_not_ready` without calling `ui.error`. Return `null` for an unknown route with an actionable warning.

- [ ] **Step 6: Protect the direct transcription transport**

In `Transcriber._request_raw()`, validate `cookies.get_bearer_auth_header()` before `HTTPRequest.new()`. On refusal, return a `RequestHandle` completed on the next main-loop turn with `error_code = "auth_not_ready"`; do not allocate `HTTPRequest`. On success, append the bearer header to the raw audio request. Extend the transport test to assert both branches.

- [ ] **Step 7: Neutralize the ambiguous header API during migration**

Keep `get_bearer_auth_header()` and `has_auth_session()`. Remove `CookieManager.get_auth_header()` after the call-site migrations in Tasks 3–5; until then, mark it deprecated and make it return only `get_bearer_auth_header()` so local profile dictionaries can never become request headers.

- [ ] **Step 8: Register and run transport tests**

Add `test_remote_transport_guards.gd:PASS test_remote_transport_guards` to `run_all.sh`. Run both new Godot tests and verify no live network is required.

- [ ] **Step 9: Commit**

```bash
git add scripts/web.gd scripts/sockets.gd scripts/cookie_manager.gd scripts/transcriber.gd tests/godot/test_remote_transport_guards.gd tests/godot/run_all.sh
git commit -m "fix: refuse protected traffic without bearer auth"
```

### Task 3: Add the Shared Interactive Guard and Fix Axon

**Files:**
- Modify: `scripts/glob.gd`
- Modify: `scripts/top_panel.gd`
- Modify: `scripts/node_info_menu.gd`
- Modify: `scripts/ai_help.gd`
- Create: `tests/godot/test_axon_auth_readiness.gd`
- Modify: `tests/godot/test_auth_ui_identity.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Produces: `glob.remote_session_ready() -> bool` and `glob.require_remote_session(show_error: bool = true) -> bool`.
- Produces: `glob.require_remote_session_for_action(run_but: BlockComponent = null) -> bool`, which preserves button unblock behavior but never opens a login splash.
- Axon low-level functions return neutral values on silent refusal: `update_message_stream -> null`, `ask_once -> ""`, `request_chat -> []`, and `clear_chat -> false`.

- [ ] **Step 1: Write failing Axon readiness tests**

Cover these behaviors with fake auth/UI callables or a minimal test adapter:

- local `_logged_in` plus no bearer is not remote-ready;
- one explicit guard call produces exactly one localized error;
- `AIHelpMenu.send_message()` with no bearer leaves `_message_list` unchanged;
- `AIHelpMenu.re_recv()` with no bearer produces no error and no request;
- the top-bar and node-info Axon entry points use the remote guard rather than `glob.logged_in()`.

- [ ] **Step 2: Run the test and verify RED**

Run: `& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_axon_auth_readiness.gd`

Expected: Axon currently accepts local identity as login and mutates message UI before the socket refusal.

- [ ] **Step 3: Implement the shared guard**

```gdscript
func remote_session_ready() -> bool:
	return RemoteSessionGate.has_bearer(cookies.get_bearer_auth_header())

func require_remote_session(show_error: bool = true) -> bool:
	if remote_session_ready():
		return true
	if show_error:
		ui.error(RemoteSessionGate.error_text(str(get_lang())))
	return false
```

`require_remote_session_for_action()` waits for a pressed `BlockComponent` to release and always unblocks it, matching the safe input behavior currently embedded in `splash_login()`.

- [ ] **Step 4: Guard every Axon interaction before mutation**

Update `top_panel._on_ai_released()` and `node_info_menu._open_axon_context()` to call the shared interactive guard and return without opening any splash on failure.

At the first line of `AIHelpMenu.send_message()`, refuse before generating IDs, adding bubbles, changing cache, disabling the input, or changing button textures. Apply the same ordering to `on_send()` voice start/transcription and `_on_cl_released()` chat clearing.

- [ ] **Step 5: Make Axon preload and history silent**

Change `AIHelpMenu.re_recv()` from `glob._logged_in` to `glob.remote_session_ready()`. Add silent low-level checks in `glob.update_message_stream()`, `ask_once()`, `request_chat()`, and `clear_chat()` so hidden preload and project switching never show a toast or create a protected request.

Handle nullable `sockets.connect_to()` before dereferencing or adding to `message_sockets`.

- [ ] **Step 6: Update identity tests**

Keep the existing assertion that a pilot session counts as signed in for identity UI, and add a separate assertion that local identity without bearer is not remote-ready. This documents that both states intentionally coexist.

- [ ] **Step 7: Run relevant and full auth tests**

Run:

```bash
& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_auth_ui_identity.gd
& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_axon_auth_readiness.gd
& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_axon_context.gd
```

Expected: all markers pass without a live backend.

- [ ] **Step 8: Commit**

```bash
git add scripts/glob.gd scripts/top_panel.gd scripts/node_info_menu.gd scripts/ai_help.gd tests/godot/test_axon_auth_readiness.gd tests/godot/test_auth_ui_identity.gd tests/godot/run_all.sh
git commit -m "fix: gate Axon on remote session readiness"
```

### Task 4: Separate Interactive and Background Classroom Calls

**Files:**
- Modify: `scripts/learner.gd`
- Modify: `scripts/settings.gd`
- Modify: `scripts/classroom_create.gd`
- Create: `tests/godot/test_classroom_auth_readiness.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Interactive callers consume `glob.require_remote_session()`.
- Background learner methods consume `glob.remote_session_ready()` and return a neutral result without UI.
- `leave_classroom() -> bool` returns `false` without clearing profile state when the request cannot start.

- [ ] **Step 1: Write failing classroom behavior tests**

Test that missing bearer causes `cache_classroom_data()`, `classroom_stream()`, `push_classroom_event()`, `fetch_lesson_auto_project_blob()`, and `mark_explanation_made()` to return silently. Test that `leave_classroom()` keeps `my_classroom`, and `upload_lesson_customs()` keeps `classroom_data` unchanged, when remote auth is unavailable.

- [ ] **Step 2: Run the test and verify RED**

Run: `& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_classroom_auth_readiness.gd`

Expected: current leave/upload paths mutate local state even when protected transport cannot run.

- [ ] **Step 3: Guard explicit classroom controls**

In `settings.gd`, guard join, leave, continue, lock/unlock, upload, and teacher/student state buttons before changing layouts or local state. In `classroom_create.gd`, guard before reading the creation result, closing the menu, or opening settings.

- [ ] **Step 4: Make background classroom methods silent**

At the start of metadata cache, SSE, automatic event mirroring, auto-project fetch, and explanation telemetry, return a neutral result when `glob.remote_session_ready()` is false. Replace `cookies.user()` checks, because a local profile name is not bearer readiness.

- [ ] **Step 5: Preserve state until an operation is accepted**

Move the `my_classroom` clear in `leave_classroom()` after a successful response. Move `classroom_data.lesson_customs` mutation after readiness and either after accepted dispatch or successful response. Return typed failure values so calling UI does not proceed to a success layout.

- [ ] **Step 6: Register and run tests**

Run the new classroom test, `test_startup_flow_coordinator.gd`, and `test_profile_onboarding.gd`. Assert startup background calls emit no error toast while auth is pending.

- [ ] **Step 7: Commit**

```bash
git add scripts/learner.gd scripts/settings.gd scripts/classroom_create.gd tests/godot/test_classroom_auth_readiness.gd tests/godot/run_all.sh
git commit -m "fix: skip classroom networking until auth is ready"
```

### Task 5: Gate Remote Fallbacks Without Touching Local Runtime

**Files:**
- Modify: `scripts/run_manager.gd`
- Modify: `scripts/lua_process.gd`
- Modify: `scripts/model_export.gd`
- Modify: `scripts/top_panel.gd`
- Modify: `scripts/glob.gd`
- Modify: `scripts/project_create.gd`
- Modify: `scripts/workslist.gd`
- Create: `tests/godot/test_remote_fallback_auth_readiness.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Local branches return before consulting remote readiness.
- Remote train/open-infer functions call `require_remote_session_for_action()` and handle a nullable socket.
- Remote project CRUD functions return `false` or an empty result before mutating project/graph state when auth is unavailable.

- [ ] **Step 1: Write failing local-versus-remote tests**

Cover four invariants:

```gdscript
_expect(local_project_action_without_token, "local projects remain available")
_expect(local_inference_action_without_token, "local inference remains available")
_expect(not remote_project_action_without_token, "remote project action is refused")
_expect(not remote_inference_action_without_token, "remote inference is refused")
```

Also assert refusal occurs before `input.set_state_open()`, progress/spinner state, `parsed_projects` mutation, and graph replacement.

- [ ] **Step 2: Run the test and verify RED**

Run: `& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --quit-after 300 --script tests/godot/test_remote_fallback_auth_readiness.gd`

Expected: existing remote paths still consult `glob.logged_in()`/`get_auth_header()` or mutate state before the protected call.

- [ ] **Step 3: Migrate remote training and inference**

Replace both `glob.splash_login()` uses in `run_manager.gd` with `require_remote_session_for_action()`. Keep the `FULLY_LOCAL_TRAINING` branches above those checks. Replace caller-supplied auth headers with transport-owned bearer attachment. If `sockets.connect_to()` returns `null`, return `false` before writing `training_sockets`, `inference_sockets`, or node open state.

Guard `upl_dataset()` and remote `delete_ctx()` silently or interactively according to their caller; neither may create a socket/request without bearer.

- [ ] **Step 4: Migrate model export**

Keep `nn.FULLY_LOCAL_TRAINING` export unchanged. For remote export, guard in `top_panel.gd` before opening `model_export` and again inside `_on_trainn_released()` before `set_downloading()`, so session loss while the menu is open leaves the button and progress bar untouched.

- [ ] **Step 5: Migrate remote project CRUD**

Keep every `LocalSave` branch first. For remote mode:

- guard `request_projects()` and `load_scene()` before their calls;
- guard `create_empty_project()` before adding to `parsed_projects`;
- guard `delete_project()` before POST and `parsed_projects.erase()`;
- guard `save()`/`save_empty()` before cache/state indicating success;
- guard the corresponding `workslist.gd`, `project_create.gd`, and top-panel user actions so the one visible error occurs before menu/progress changes.

Low-level functions return neutral failure without their own toast, preventing duplicate errors.

- [ ] **Step 6: Remove remaining compatibility authorization calls**

Replace `_missing_remote_login_for_model()` with `not glob.remote_session_ready()` while retaining its local-model exception. Replace all remaining `cookies.get_auth_header()` references with either transport-owned auth or `get_bearer_auth_header()` in the auth layer, then delete `get_auth_header()` from `cookie_manager.gd`.

- [ ] **Step 7: Register and run tests**

Run the new fallback test plus training dataset, runtime error, simulation model runner, project gallery, built-in project switch, and startup coordinator tests.

- [ ] **Step 8: Commit**

```bash
git add scripts/run_manager.gd scripts/lua_process.gd scripts/model_export.gd scripts/top_panel.gd scripts/glob.gd scripts/project_create.gd scripts/workslist.gd scripts/cookie_manager.gd tests/godot/test_remote_fallback_auth_readiness.gd tests/godot/run_all.sh
git commit -m "fix: gate remote fallbacks without blocking local work"
```

### Task 6: Add a Closed-World Network Boundary Audit

**Files:**
- Create: `tools/network_boundary_audit.py`
- Create: `tests/release/test_network_auth_boundaries.py`
- Modify: `resources/network_endpoint_policy.json`

**Interfaces:**
- Produces: `audit_repository(root: Path, policy_path: Path) -> list[Violation]`.
- `Violation` contains `path`, `line`, `rule`, and `message`.
- The CLI exits 0 with `Network boundary audit passed` or exits 1 after printing every violation.

- [ ] **Step 1: Write failing Python audit tests**

Use temporary GDScript fixtures to prove the audit catches:

- an unclassified literal REST route;
- an unclassified WebSocket route;
- a dynamic route outside the allowlist;
- `HTTPRequest.new()` in an unapproved file;
- `web._request()` outside approved transport/auth code;
- any `cookies.get_auth_header()` usage;
- commented-out examples without treating them as live calls.

```python
def test_rejects_unclassified_route(tmp_path: Path):
    write_script(tmp_path, 'scripts/feature.gd', 'web.POST("api/new-route", {})')
    violations = audit_repository(tmp_path, POLICY)
    assert any(v.rule == "unclassified-rest-route" for v in violations)

def test_ignores_commented_transport_example(tmp_path: Path):
    write_script(tmp_path, 'scripts/feature.gd', '# HTTPRequest.new()')
    assert audit_repository(tmp_path, POLICY) == []
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `python -m pytest tests/release/test_network_auth_boundaries.py -v`

Expected: import failure because `tools.network_boundary_audit` does not exist.

- [ ] **Step 3: Implement comment-aware scanning**

Strip GDScript line comments while preserving line numbers and quoted strings. Scan `scripts/**/*.gd` for the approved primitives and high-level calls. Resolve literal routes through the JSON catalog. Require every non-literal route call to match an exact `{path, function, API}` allowlist entry.

- [ ] **Step 4: Seed narrow allowlists**

Approve only the current owners:

- `HTTPClient.new`: `scripts/web.gd`;
- `HTTPRequest.new`: `scripts/auth/auth_session.gd`, `scripts/transcriber.gd`;
- `WebSocketPeer.new`: `scripts/socket_connection.gd`;
- `TCPServer.new`: `scripts/auth/oauth_loopback_receiver.gd`;
- `web._request`: `scripts/cookie_manager.gd` auth adapter;
- dynamic absolute updater download and LAN health call sites in their exact functions.

Do not allow an entire directory or wildcard file set.

- [ ] **Step 5: Run the audit against the repository**

Run:

```bash
python -m tools.network_boundary_audit
python -m pytest tests/release/test_network_auth_boundaries.py -v
```

Expected: `Network boundary audit passed`; every remaining route is classified and every raw transport is intentional.

- [ ] **Step 6: Commit**

```bash
git add tools/network_boundary_audit.py tests/release/test_network_auth_boundaries.py resources/network_endpoint_policy.json
git commit -m "test: enforce network authentication boundaries"
```

### Task 7: Full Regression and Offline Startup Verification

**Files:**
- Modify only feature files when verification identifies a defect.

**Interfaces:**
- Consumes: Tasks 1–6 and the existing non-blocking startup changes.
- Produces: a verified branch where local startup and work remain available without auth while protected remote operations are fail-closed.

- [ ] **Step 1: Refresh Godot's class cache**

Run:

```bash
& 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe' --headless --path . --import
```

Expected: exit code 0 and the new `class_name` scripts resolve in the test runner.

- [ ] **Step 2: Run the fast repository suites**

Run exactly:

```bash
python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration -v
python -m tools.node_dev check
python -m tools.network_boundary_audit
```

Expected: all tests pass and generated catalogs remain current.

- [ ] **Step 3: Run the complete Godot suite**

Run:

```powershell
$env:GODOT_BIN = 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe'
bash tests/godot/run_all.sh
```

Expected: every registered marker passes. Because the runner is fail-fast per invocation semantics, rerun the complete suite after fixing any first failure.

- [ ] **Step 4: Run generated-scene validation**

Run: `python -m tools.node_dev godot-check --godot-bin "D:\SteamLibrary\steamapps\common\Godot Engine\godot.exe" --timeout 300`

Expected: all generated node scenes validate.

- [ ] **Step 5: Perform the offline/throttled manual matrix**

Verify in Russian, English, and Kazakh:

1. Start with a saved local/pilot profile and blocked or throttled internet.
2. Confirm "Who is working now?" and the tutorial prompt appear without waiting for a token.
3. Click Axon before auth completes; confirm one localized error, no Axon window, no pending bubble, and no socket.
4. Open local projects, built-ins, simulations, local inference, and local training; confirm they still work.
5. Try classroom and remote export actions; confirm one error and no partial layout/progress mutation.
6. Restore network and wait for `auth_login_completed`.
7. Click the same actions again; confirm they execute normally and were not automatically replayed.
8. Clear the session while Axon is open; confirm send, record, and clear-chat refuse before changing UI.

- [ ] **Step 6: Inspect the final diff and worktree**

Run:

```bash
git diff --check
git status --short
```

Confirm no generated files were hand-edited, no untracked DLL/EXE/log artifact is staged, and changes remain limited to the auth-readiness design.

- [ ] **Step 7: Commit verification-only corrections if required**

Stage corrections by explicit filename and commit:

```bash
git commit -m "fix: complete remote auth readiness regressions"
```

Do not create an empty commit when verification required no corrections.
