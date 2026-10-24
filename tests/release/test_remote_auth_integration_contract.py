from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig")


def _function(relative: str, name: str) -> str:
    lines = _source(relative).splitlines()
    start = next(
        index for index, line in enumerate(lines) if line.startswith(f"func {name}(")
    )
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if lines[index].startswith("func ")
        ),
        len(lines),
    )
    return "\n".join(lines[start:end])


def test_remote_readiness_is_distinct_from_local_identity() -> None:
    body = _function("scripts/glob.gd", "remote_session_ready")
    assert "get_bearer_auth_header" in body
    assert "logged_in()" not in body
    assert "_logged_in" not in body


def test_transport_guards_run_before_network_allocation() -> None:
    rest = _function("scripts/web.gd", "_request")
    assert rest.index("_access_headers") < rest.index("Thread.new")

    websocket = _function("scripts/sockets.gd", "connect_to")
    assert websocket.index("prepare_headers") < websocket.index("SocketConnection.new")

    transcription = _function("scripts/transcriber.gd", "_request_raw")
    assert transcription.index("prepare_headers") < transcription.index("HTTPRequest.new")


def test_axon_refuses_before_mutating_message_ui() -> None:
    send = _function("scripts/ai_help.gd", "send_message")
    assert send.index("require_remote_session") < send.index("add_message")

    clear = _function("scripts/ai_help.gd", "_on_cl_released")
    assert clear.index("require_remote_session") < clear.index("_message_list.clear")


def test_classroom_state_is_preserved_when_auth_is_missing() -> None:
    leave = _function("scripts/learner.gd", "leave_classroom")
    assert leave.index("remote_session_ready") < leave.index(
        'set_profile("my_classroom", "")'
    )

    upload = _function("scripts/learner.gd", "upload_lesson_customs")
    assert upload.index("remote_session_ready") < upload.index(
        'classroom_data.get_or_add("lesson_customs", {})[lesson_id] = meta'
    )


def test_local_runtime_branches_precede_remote_guards() -> None:
    inference = _function("scripts/run_manager.gd", "open_infer_channel")
    assert inference.index("if not FULLY_LOCAL_TRAINING") < inference.index(
        "require_remote_session_for_action"
    )

    training = _function("scripts/run_manager.gd", "start_train")
    assert training.index("if not FULLY_LOCAL_TRAINING") < training.index(
        "require_remote_session_for_action"
    )

    export = _function("scripts/model_export.gd", "_on_trainn_released")
    assert export.index("if nn.FULLY_LOCAL_TRAINING") < export.index(
        "require_remote_session"
    )


def test_top_panel_remote_actions_never_open_login_splash() -> None:
    save = _function("scripts/top_panel.gd", "_on__released")
    works = _function("scripts/top_panel.gd", "_on_workslist")
    assert "require_remote_session_for_action" in save
    assert "require_remote_session_for_action" in works
    assert 'splash_and_get_result("login"' not in save
    assert 'splash_and_get_result("login"' not in works


def test_remote_train_and_inference_guard_before_validation() -> None:
    training = _function("scripts/run_manager.gd", "start_train")
    assert training.index("require_remote_session_for_action") < training.index(
        "try_print"
    )

    inference = _function("scripts/run_manager.gd", "open_infer_channel")
    assert inference.index("require_remote_session_for_action") < inference.index(
        "check_valid"
    )


def test_remote_inference_never_uses_local_identity_as_readiness() -> None:
    validation = _function("scripts/run_manager.gd", "validate_infer_channel")
    assert "remote_session_ready" in validation
    assert "_logged_in" not in validation

    lua_fallback = _function("scripts/lua_process.gd", "_model_can_run_without_login")
    assert "FULLY_LOCAL_TRAINING" in lua_fallback


def test_auth_adapter_passes_protected_policy_route_to_transport() -> None:
    adapter = _function("scripts/cookie_manager.gd", "_auth_json_request")
    assert "headers,\n\t\tpath" in adapter
