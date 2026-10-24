extends SceneTree

const NetworkModeConfig = preload("res://scripts/network_mode.gd")

var failures := 0


func _init() -> void:
	_expect_equal(
		NetworkModeConfig.resolve(PackedStringArray()),
		NetworkModeConfig.Mode.Remote,
		"remote API is the safe default"
	)
	_expect_equal(
		NetworkModeConfig.resolve(PackedStringArray(["--local-api"])),
		NetworkModeConfig.Mode.Localhost,
		"local API requires an explicit flag"
	)
	_expect_equal(
		NetworkModeConfig.resolve(PackedStringArray(["--lan-api"])),
		NetworkModeConfig.Mode.LAN,
		"LAN API requires an explicit flag"
	)
	_expect_equal(
		NetworkModeConfig.http_root(NetworkModeConfig.Mode.Remote),
		"https://neuralese.asia",
		"remote HTTP root"
	)
	_expect_equal(
		NetworkModeConfig.ws_root(NetworkModeConfig.Mode.Remote),
		"wss://neuralese.asia/",
		"remote websocket root"
	)
	_expect_equal(
		NetworkModeConfig.http_root(NetworkModeConfig.Mode.Localhost),
		"http://127.0.0.1:8081/",
		"local HTTP root"
	)
	_expect_equal(
		NetworkModeConfig.ws_root(NetworkModeConfig.Mode.Localhost),
		"ws://127.0.0.1:8081/",
		"local websocket root"
	)
	_expect_equal(
		NetworkModeConfig.http_root(NetworkModeConfig.Mode.LAN, "192.168.1.20"),
		"http://192.168.1.20:8081/",
		"LAN HTTP root"
	)

	if failures == 0:
		print("PASS test_network_mode")
	quit(failures)


func _expect_equal(actual, expected, message: String) -> void:
	if actual == expected:
		return
	push_error("%s: expected %s, got %s" % [message, expected, actual])
	failures += 1
