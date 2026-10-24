extends RefCounted
class_name NetworkModeConfig

enum Mode {Localhost, Remote, LAN}

const LOCAL_HTTP_ROOT := "http://127.0.0.1:8081/"
const LOCAL_WS_ROOT := "ws://127.0.0.1:8081/"
const REMOTE_HTTP_ROOT := "https://neuralese.asia"
const REMOTE_WS_ROOT := "wss://neuralese.asia/"


static func resolve(user_args: PackedStringArray) -> int:
	if user_args.has("--local-api"):
		return Mode.Localhost
	if user_args.has("--lan-api"):
		return Mode.LAN
	return Mode.Remote


static func http_root(mode: int, lan_ip: String = "") -> String:
	match mode:
		Mode.Localhost:
			return LOCAL_HTTP_ROOT
		Mode.LAN:
			return "http://%s:8081/" % lan_ip
		_:
			return REMOTE_HTTP_ROOT


static func ws_root(mode: int, lan_ip: String = "") -> String:
	match mode:
		Mode.Localhost:
			return LOCAL_WS_ROOT
		Mode.LAN:
			return "ws://%s:8081/" % lan_ip
		_:
			return REMOTE_WS_ROOT
