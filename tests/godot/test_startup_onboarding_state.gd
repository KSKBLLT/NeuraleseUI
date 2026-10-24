extends SceneTree

const StartupOnboardingState = preload("res://scripts/startup/startup_onboarding_state.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "user://startup_onboarding_state_test_%s.json" % Time.get_ticks_usec()
	var state = StartupOnboardingState.new(path)
	state.select_account("account-a")
	_expect_equal(state.get_value("startup_onboarding_version"), 0, "new account onboarding version")
	_expect_equal(state.needs_interface_tour(1), true, "new account needs tour")
	state.set_value("startup_onboarding_version", 1)
	state.mark_interface_tour("completed", 1)

	state.select_account("account-b")
	_expect_equal(state.get_value("startup_onboarding_version"), 0, "second account is isolated")
	_expect_equal(state.needs_interface_tour(1), true, "second account does not inherit tour")

	var reopened = StartupOnboardingState.new(path)
	reopened.select_account("account-a")
	_expect_equal(reopened.get_value("startup_onboarding_version"), 1, "account state persists")
	_expect_equal(reopened.get_value("interface_tour_status"), "completed", "tour status persists")
	_expect_equal(reopened.needs_interface_tour(1), false, "completed current tour is not repeated")
	_expect_equal(reopened.needs_interface_tour(2), true, "new tour version is shown")
	_expect_equal(
		reopened.needs_interface_tour(3),
		true,
		"an installation that recorded the pre-release tour is offered the shipped tour"
	)

	var invalid_status := reopened.mark_interface_tour("unknown", 2)
	_expect_equal(invalid_status, false, "unknown tour status rejected")
	_expect_equal(reopened.get_value("interface_tour_status"), "completed", "invalid status does not overwrite")

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if failures.is_empty():
		print("PASS test_startup_onboarding_state")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
