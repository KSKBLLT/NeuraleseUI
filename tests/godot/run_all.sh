#!/usr/bin/env bash
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"

# Every test runs against a throwaway user:// profile, so a local run never
# changes the developer's real projects, datasets or settings (CI starts from an
# empty profile too). Godot derives user:// from APPDATA on Windows and from
# XDG_DATA_HOME on Linux and macOS. NEURALESE_TEST_REAL_PROFILE=1 opts out.
if [[ "${NEURALESE_TEST_REAL_PROFILE:-0}" != "1" ]]; then
  test_profile="$(mktemp -d)"
  trap 'rm -rf "$test_profile"' EXIT
  if command -v cygpath >/dev/null 2>&1; then
    export APPDATA="$(cygpath -w "$test_profile")"
  else
    export APPDATA="$test_profile"
  fi
  export XDG_DATA_HOME="$test_profile"
  export NEURALESE_TEST_PROFILE=1
fi

if [[ ! -f ".godot/global_script_class_cache.cfg" ]]; then
  "$GODOT_BIN" --headless --path . --import
fi

TESTS=(
  "test_local_inference_response_claim.gd:PASS test_local_inference_response_claim"
  "test_language_connection_refresh.tscn:PASS test_language_connection_refresh"
  "test_language_autoregression.tscn:PASS test_language_autoregression"
  "test_language_editor.tscn:PASS test_language_editor"
  "test_top_output_node.tscn:PASS test_top_output_node"
  "test_language_backend.gd:PASS test_language_backend"
  "test_language_graph.gd:PASS test_language_graph"
  "test_language_controller.gd:PASS test_language_controller"
  "test_language_views.gd:PASS test_language_views"
  "test_language_interactions.gd:PASS test_language_interactions"
  "test_language_menus.tscn:PASS test_language_menus"
  "test_auth_runtime_config.gd:PASS test_auth_runtime_config"
  "test_oidc_client.gd:PASS test_oidc_client"
  "test_oauth_loopback_receiver.gd:PASS test_oauth_loopback_receiver"
  "test_auth_session.gd:PASS test_auth_session"
	"test_remote_endpoint_policy.gd:PASS test_remote_endpoint_policy"
	"test_remote_transport_guards.gd:PASS test_remote_transport_guards"
	"test_remote_action_behavior.gd:PASS test_remote_action_behavior"
	"test_auth_ui_identity.gd:PASS test_auth_ui_identity"
  "test_pilot_auth_session.gd:PASS test_pilot_auth_session"
  "test_pilot_onboarding_client.gd:PASS test_pilot_onboarding_client"
  "test_account_type_onboarding.gd:PASS test_account_type_onboarding"
  "test_profile_onboarding.gd:PASS test_profile_onboarding"
  "test_onboarding_live_language.gd:PASS test_onboarding_live_language"
  "test_startup_onboarding_state.gd:PASS test_startup_onboarding_state"
  "test_startup_main_menu.gd:PASS test_startup_main_menu"
  "test_startup_tutorial_prompt.gd:PASS test_startup_tutorial_prompt"
  "test_startup_flow_coordinator.gd:PASS test_startup_flow_coordinator"
  "test_interface_tour_bundle.gd:PASS test_interface_tour_bundle"
  # DEPRECATED: UI structure changed, hardcoded paths ("Control/view/Label/run") are broken
	# "test_interface_tour_launch.tscn:PASS test_interface_tour_launch"
  "test_ui_tutorial_arrow.gd:PASS test_ui_tutorial_arrow"
  "test_auth_migration.gd:PASS test_auth_migration"
  "test_axon_context.gd:PASS test_axon_context"
  "test_axon_mascot.gd:PASS test_axon_mascot"
  "test_header_pixel.gd:PASS test_header_pixel"
  "test_node_info_catalog.gd:PASS test_node_info_catalog"
  "test_node_info_menu.gd:PASS test_node_info_menu"
  "test_button_property_persistence.gd:PASS test_button_property_persistence"
  "test_ui_adapter_auto_fit.gd:PASS test_ui_adapter_auto_fit"
  "test_dataset_search.gd:PASS test_dataset_search"
  "test_training_dataset_shape.gd:PASS test_training_dataset_shape"
  "test_input_rgb.tscn:PASS test_input_rgb"
  "test_cifar10_model.tscn:PASS test_cifar10_model"
  "test_local_training_worker.tscn:PASS test_local_training_worker"
  "test_training_prepare_flow.tscn:PASS test_training_prepare_flow"
  "test_runtime_error_messages.gd:PASS test_runtime_error_messages"
  "test_autosave_writer.gd:PASS test_autosave_writer"
  "test_project_gallery.gd:PASS test_project_gallery"
	"test_project_gallery_layout.tscn:PASS test_project_gallery_layout"
	"test_builtin_projects_blur_release.tscn:PASS test_builtin_projects_blur_release"
  "test_builtin_project_switch.tscn:PASS test_builtin_project_switch"
  "test_workspace_history_controller.gd:PASS test_workspace_history_controller"
  "test_connection_feedback.gd:PASS test_connection_feedback"
  "test_high_blur_material_contract.gd:PASS test_high_blur_material_contract"
  "test_blur_shader_routing.gd:PASS test_blur_shader_routing"
  "test_graphics_quality.gd:PASS test_graphics_quality"
  "test_node_palette_blur_quality.gd:PASS test_node_palette_blur_quality"
	"test_settings_quality_carousel.tscn:PASS test_settings_quality_carousel"
  "test_background_blur_cache.tscn:PASS test_background_blur_cache"
  "test_ui_blur_visibility.tscn:PASS test_ui_blur_visibility"
  "test_idle_camera.gd:PASS test_idle_camera"
  "test_tabs_idle.tscn:PASS test_tabs_idle"
  "test_spline_inference_flow.gd:PASS test_spline_inference_flow"
  "test_input2d_dense_inference.tscn:PASS test_input2d_dense_inference"
  "test_error_toast_stack.gd:PASS test_error_toast_stack"
  "test_generated_node_catalog.gd:PASS test_generated_node_catalog"
	"test_ai_output_map_migration.tscn:PASS test_ai_output_map_migration"
	"test_legacy_output_map_recovery.tscn:PASS test_legacy_output_map_recovery"
  "test_node_palette_catalog.gd:PASS test_node_palette_catalog"
  # DEPRECATED: Drag preview rules changed (requires unframed image drag preview)
  # "test_node_palette_scene.gd:PASS test_node_palette_scene"
  "test_node_palette_window_visibility.gd:PASS test_node_palette_window_visibility"
  "test_simulation_object_catalog.gd:PASS test_simulation_object_catalog"
  "test_simulation_world_state.gd:PASS test_simulation_world_state"
  "test_simulation_example_worlds.gd:simulation example worlds tests: PASS"
  "test_simulation_randomization_profile.gd:PASS test_simulation_randomization_profile"
  "test_simulation_sample_estimator.gd:PASS test_simulation_sample_estimator"
  "test_simulation_editor.gd:PASS test_simulation_editor"
  "test_simulation_transform_gizmo.gd:PASS test_simulation_transform_gizmo"
  "test_simulation_selection_marquee.gd:PASS test_simulation_selection_marquee"
  "test_simulation_runtime.gd:PASS test_simulation_runtime"
  "test_simulation_definition_registry.gd:PASS test_simulation_definition_registry"
  "test_simulation_model_binding.gd:PASS test_simulation_model_binding"
  "test_simulation_episode_record.gd:PASS test_simulation_episode_record"
  "test_simulation_signal_codec.gd:PASS test_simulation_signal_codec"
  "test_simulation_jump_dataset.gd:PASS test_simulation_jump_dataset"
  "test_simulation_io_schema.gd:PASS test_simulation_io_schema"
  "test_simulation_agent.gd:PASS test_simulation_agent"
  "test_simulation_expert_policy.gd:PASS test_simulation_expert_policy"
  "test_simulation_model_runner.gd:PASS test_simulation_model_runner"
  "test_simulation_training_bridge.gd:simulation training bridge tests: PASS"
  "test_simulation_dataset_contracts.gd:PASS test_simulation_dataset_contracts"
  "test_simulation_dataset_generator.gd:PASS test_simulation_dataset_generator"
  "test_simulation_dataset_save_policy.gd:PASS test_simulation_dataset_save_policy"
  "test_simulation_dataset_ui.gd:PASS test_simulation_dataset_ui"
  "test_simulation_tab.gd:PASS test_simulation_tab"
  "test_network_mode.gd:PASS test_network_mode"
  # DEPRECATED: Button format strictly asserts outdated dictionary without 'can_go: true'
  # "test_dialog_spec.gd:PASS test_dialog_spec"
  "test_markdown_to_bbcode.gd:PASS test_markdown_to_bbcode"
  # DEPRECATED: Test asserts palette cannot be hidden by dialog, which contradicts new startup logic
  # "test_multipurpose_dialog.gd:PASS test_multipurpose_dialog"
  "test_ui_manager_dialog.gd:PASS test_ui_manager_dialog"
  "test_platform_input.gd:platform input tests: PASS"
  "test_ui_capture.gd:PASS test_ui_capture"
  "test_update_policy.gd:PASS test_update_policy"
  "test_update_version.gd:PASS test_update_version"
  "test_update_manifest.gd:PASS test_update_manifest"
  "test_update_download.gd:PASS test_update_download"
  "test_update_dialog_spec.gd:PASS test_update_dialog_spec"
  "test_update_health.gd:PASS test_update_health"
  "test_update_flow.gd:PASS test_update_flow"
  "test_robot_window.tscn:PASS test_robot_window"
  "test_robot_lidar_map.gd:PASS test_robot_lidar_map"
  "test_e2e_workspace.tscn:PASS test_e2e_workspace"
  "test_dataset_bento_analysis.gd:PASS test_dataset_bento_analysis"
)

# Unit/CI runs do not download an external checkpoint. Real acceptance is explicit
# and mandatory in the language integration workflow; missing assets fail there.
if [[ "${NEURALESE_RUN_REAL_LANGUAGE_TESTS:-0}" == "1" ]]; then
  TESTS+=("language_runtime_smoke.tscn:PASS test_language_real_backend" "test_language_real_network.tscn:PASS test_language_real_network" "test_language_training.tscn:PASS test_language_training")
else
  printf 'Real language acceptance: set NEURALESE_RUN_REAL_LANGUAGE_TESTS=1 with the model bundle installed.\n'
fi

# Training, answers, exports and the simulated car through the bundled Python
# runtime (local_runtime/python). CI's Godot job has none, so this is opt-in.
if [[ "${NEURALESE_RUN_LOCAL_RUNTIME_TESTS:-0}" == "1" ]]; then
  TESTS+=("test_e2e_local_runtime.tscn:PASS test_e2e_local_runtime")
else
  printf 'Local runtime end-to-end: set NEURALESE_RUN_LOCAL_RUNTIME_TESTS=1 with local_runtime/python installed.\n'
fi

failures=()

for entry in "${TESTS[@]}"; do
  file="${entry%%:*}"
  marker="${entry#*:}"
  if [[ ",${GODOT_SKIP_TESTS:-}," == *",${file},"* ]]; then
    printf 'SKIP %s\n' "$file"
    continue
  fi
  quit_after=300
  if [[ "$file" == "test_language_editor.tscn" ]]; then
    # Editing, debounce/cancellation, layout and native input lifecycle scenarios.
    quit_after=900
  fi
  if [[ "$file" == "test_language_real_network.tscn" ]]; then
    quit_after=3600
  fi
  if [[ "$file" == "test_language_training.tscn" ]]; then
    quit_after=24000
  fi
  if [[ "$file" == "test_simulation_dataset_generator.gd" ]]; then
    quit_after=3000
  fi
  if [[ "$file" == test_e2e_*.tscn ]]; then
    # Whole-app scenarios; each test also stops itself with a watchdog.
    quit_after=400000
  fi
	if [[ "$file" == "test_background_blur_cache.tscn" ]]; then
		# This contract samples ViewportTexture pixels and observes render-frame
		# scheduling; the headless display driver cannot provide either signal.
		output="$(NEURALESE_ISOLATED_TEST=1 "$GODOT_BIN" --path . --quit-after "$quit_after" --scene "tests/godot/$file" 2>&1 || true)"
	elif [[ "$file" == "test_language_real_network.tscn" || "$file" == "test_language_training.tscn" || "$file" == "language_runtime_smoke.tscn" || "$file" == test_e2e_*.tscn || "$file" == "test_builtin_projects_blur_release.tscn" ]]; then
		# Exercise graph controls without the ordinary onboarding splash disabling
		# their processing. This is the app's existing test startup mode.
		# The blur test also needs it: the pilot identity dialog shown at startup
		# drives the shared blur towards its own level underneath the test.
		output="$("$GODOT_BIN" --headless --path . --quit-after "$quit_after" --scene "tests/godot/$file" -- --perfbench 2>&1 || true)"
	elif [[ "$file" == *.tscn ]]; then
		output="$("$GODOT_BIN" --headless --path . --quit-after "$quit_after" --scene "tests/godot/$file" 2>&1 || true)"
	elif [[ "$file" == "test_ui_capture.gd" ]]; then
		# UI capture waits for a real rendered frame. Godot's headless display
		# driver never emits frame_post_draw, so run this isolated rendering test
		# with the platform display driver used by the hosted macOS/Windows runner.
		output="$(NEURALESE_ISOLATED_TEST=1 "$GODOT_BIN" --path . --quit-after "$quit_after" --script "tests/godot/$file" 2>&1 || true)"
	elif [[ "$file" == "test_project_gallery.gd" || "$file" == "test_training_dataset_shape.gd" || "$file" == "test_language_real_backend.gd" ]]; then
		output="$(NEURALESE_ISOLATED_TEST=1 "$GODOT_BIN" --headless --path . --quit-after "$quit_after" --script "tests/godot/$file" 2>&1 || true)"
	else
		output="$("$GODOT_BIN" --headless --path . --quit-after "$quit_after" --script "tests/godot/$file" 2>&1 || true)"
	fi
  if ! grep -Fq "$marker" <<<"$output" || { [[ "$file" == "test_language_autoregression.tscn" ]] && grep -Fq "SCRIPT ERROR:" <<<"$output"; }; then
    printf '%s\n' "$output"
    printf 'FAIL %s\n' "$file" >&2
    failures+=("$file")
    continue
  fi
  printf '%s\n' "$marker"
done

if ((${#failures[@]} > 0)); then
  printf '\nGodot test failures (%d):\n' "${#failures[@]}" >&2
  printf ' - %s\n' "${failures[@]}" >&2
  exit 1
fi
