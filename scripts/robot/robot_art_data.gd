class_name RobotArtData
extends RefCounted
## The drawings of the robots and their parts (game_assets/robots/art), and the
## measurements that come with them (robots_art.json): how many pixels make a
## centimetre, how long the robot is, where its wheels are drawn.
##
## The drawings are white and grey; the window tints them one colour, the
## rover's colour in the simulation catalog.

const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ART_DIR := "res://game_assets/robots/art/"

static var _meta: Dictionary = {}
static var _textures: Dictionary = {}


static func meta() -> Dictionary:
	if _meta.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ART_DIR + "robots_art.json"))
		_meta = parsed if parsed is Dictionary else {"px_per_cm": 50.0, "bases": {}}
	return _meta


static func texture(file_name: String) -> Texture2D:
	if not _textures.has(file_name):
		_textures[file_name] = load(ART_DIR + file_name) as Texture2D
	return _textures[file_name]


## The drawing a robot of this platform is shown with.
static func base_id(platform: String) -> String:
	match platform:
		"spike", "spike_prime":
			return "spike"
		"microbit":
			return "microbit"
	return "ev3"   # the EV3, and the virtual robot (it is KIRISIMA, an EV3)


static func base(platform: String) -> Dictionary:
	return meta().get("bases", {}).get(base_id(platform), {})


static func px_per_cm() -> float:
	return float(meta().get("px_per_cm", 50.0))


## A distance sensor of this platform, from above (its size on the floor) or from
## the front (in the parts palette).
static func sensor_texture(platform: String, from_front: bool) -> Texture2D:
	return texture(_sensor_name(platform) + ("_front.png" if from_front else "_top.png"))


static func _sensor_name(platform: String) -> String:
	return "spike_distance" if base_id(platform) == "spike" else "ev3_ultrasonic"


## How far the camera is tipped towards the robot's right side on the build
## screen and the cards, in degrees; 0 for a robot drawn only from above (the
## hand-drawn micro:bit).
static func tilt_deg(platform: String) -> float:
	return float(meta().get("tilt_deg", 0.0)) if base(platform).has("image_tilt") else 0.0


## The robot as the build screen and its card show it, and the pixel where its
## centre on the floor is on that picture.
static func view_texture(platform: String) -> Texture2D:
	var info := base(platform)
	return texture(str(info.get("image_tilt", info.get("image", "ev3_base_top.png"))))


static func view_origin_px(platform: String) -> Vector2:
	var info := base(platform)
	var origin: Array = info.get("tilt_origin_px", info.get("center_px", [0.0, 0.0])) if info.has("image_tilt") else info.get("center_px", [0.0, 0.0])
	return Vector2(float(origin[0]), float(origin[1]))


## A sensor turned to face angle_deg (to the left of ahead), seen by the build
## screen's camera: {"texture", "anchor"} with the pixel of the sensor's centre,
## or {} where the robot is drawn from above.
static func sensor_view(platform: String, angle_deg: float) -> Dictionary:
	if is_zero_approx(tilt_deg(platform)):
		return {}
	var views: Dictionary = meta().get("sensors", {}).get(_sensor_name(platform), {}).get("tilt", {})
	var key := str(int(posmod(roundi(angle_deg / 45.0) * 45, 360)))
	var view: Dictionary = views.get(key, {})
	if view.is_empty():
		return {}
	var anchor: Array = view.get("anchor_px", [0.0, 0.0])
	return {"texture": texture(str(view["image"])), "anchor": Vector2(float(anchor[0]), float(anchor[1]))}


static func motor_texture(platform: String) -> Texture2D:
	return texture("spike_motor_side.png" if base_id(platform) == "spike" else "ev3_large_motor_side.png")


static func tint() -> Color:
	return ObjectCatalog.definition(&"rover").get("color", Color("65c7bd"))
