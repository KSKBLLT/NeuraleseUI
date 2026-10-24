"""Final robot drawings for the game, plus where things are on them.

Writes into <out>: <base>_top.png (robot facing right, straight from above: the
field's map), <base>_tilt.png (the same robot with the camera tipped TILT_DEG
towards its right side: the build screen and the robot cards), sensor pictures
(top, front, and tilted in eight directions), wheel pictures (seen from the
side), and robots_art.json with, per base, the image's scale (pixels per
centimetre), the robot's centre, length, wheel track, wheel size, where each
wheel is drawn, and where the robot's centre on the floor lands on the tilted
picture. Bases already in robots_art.json that are not rendered here (the
hand-drawn micro:bit) are kept. 1 LDU = 0.4 mm.
"""
import json, math, sys
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
import ldraw_render as R

R.LIB = Path(sys.argv[1]); out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
PX_PER_LDU = 2.0
PX_PER_CM = PX_PER_LDU / 0.04
#: How far the camera is tipped from straight above towards the robot's right
#: side: enough to read as a solid object, little enough that the brick does not
#: hide the left wheel.
TILT_DEG = 12.0
#: Sensors are drawn on the tilted picture at this height above the floor (cm).
SENSOR_HEIGHT_CM = 5.6
SENSOR_ANGLES = [0, 45, 90, 135, 180, 225, 270, 315]
WHITE = (255, 255, 255)
I = np.eye(3); Z = np.zeros(3)
def P(x, y, z): return np.array([x, y, z], float)

def to_px(point, frame=None):
    f = frame or R.LAST_FRAME
    u = float(np.dot(point, f["axes"][0])); v = float(np.dot(point, f["axes"][1]))
    return [(u - f["lo_u"]) * f["px_per_ldu"] + f["margin"], (v - f["lo_v"]) * f["px_per_ldu"] + f["margin"]]


def from_top_px(px, frame):
    """The LDraw x and z of a point of the top picture (LDraw y is lost)."""
    u = (px[0] - frame["margin"]) / frame["px_per_ldu"] + frame["lo_u"]
    v = (px[1] - frame["margin"]) / frame["px_per_ldu"] + frame["lo_v"]
    return u, -v                       # top view: screen x = LDraw x, screen y = -LDraw z


# The tilted view: the top view's screen-down and depth axes turned about the
# screen's x axis, so higher points move up the picture and the robot's right
# side (screen down) comes into sight.
_a = math.radians(TILT_DEG)
_sx, _sy, _sd = R.VIEWS["top"]
R.VIEWS["tilt"] = (_sx, math.cos(_a) * _sy - math.sin(_a) * _sd, math.sin(_a) * _sy + math.cos(_a) * _sd)

EV3_MOTOR = R.rot("y", 90)
SPIKE_LEFT = np.array([[0, 0, -1], [-1, 0, 0], [0, 1, 0]], float)
SPIKE_RIGHT = np.array([[0, 0, -1], [1, 0, 0], [0, -1, 0]], float)
bases = {
    "ev3": {
        "parts": [
            (R.load("95646c01.dat"), R.rot("y", -90), P(-30, -217, 0)),
            (R.load("95658.dat"), EV3_MOTOR, P(0, 0, 60)),
            (R.load("95658.dat"), EV3_MOTOR, P(0, 0, -60)),
            (R.load("56145c03.dat"), I, P(0, 0, 150)),
            (R.load("56145c03.dat"), I, P(0, 0, -150)),
        ],
        "wheels": {"left": (P(0, 0, 150), 140, 64), "right": (P(0, 0, -150), 140, 64)},
        "wheel_diameter_cm": 5.6,
    },
    "spike": {
        "parts": [
            (R.load("45601c01.dat"), R.rot("y", 90), P(-20, -10, 0)),
            (R.load("54696p01.dat"), SPIKE_LEFT, P(30, 40, 95)),
            (R.load("54696p01.dat"), SPIKE_RIGHT, P(30, 40, -95)),
            (R.load("39367p01.dat"), I, P(30, 40, 150)),
            (R.load("39367p01.dat"), I, P(30, 40, -150)),
        ],
        "wheels": {"left": (P(30, 40, 150), 140, 35), "right": (P(30, 40, -150), 140, 35)},
        "wheel_diameter_cm": 5.6,
    },
}
old_meta = {}
if (out / "robots_art.json").exists():
    old_meta = json.loads((out / "robots_art.json").read_text(encoding="utf-8"))
meta = {"px_per_cm": PX_PER_CM, "tilt_deg": TILT_DEG, "bases": {}, "sensors": {},
        "source": "LDraw parts library (CC BY 4.0), rendered by tools/build_robot_art.py"}
for name, base in bases.items():
    img = R.render(base["parts"], "top", PX_PER_LDU, WHITE)
    img.save(out / f"{name}_base_top.png")
    top_frame = dict(R.LAST_FRAME)
    wheels = {}
    for side, (centre, length_ldu, width_ldu) in base["wheels"].items():
        c = to_px(centre)
        wheels[side] = {"center_px": c, "size_px": [length_ldu * PX_PER_LDU, width_ldu * PX_PER_LDU]}
    left_c, right_c = wheels["left"]["center_px"], wheels["right"]["center_px"]
    track_px = abs(right_c[1] - left_c[1])
    alpha = np.asarray(img)[..., 3]
    cols = np.where(alpha.max(0) > 0)[0]; rows = np.where(alpha.max(1) > 0)[0]
    meta["bases"][name] = {
        "image": f"{name}_base_top.png",
        "image_size": list(img.size),
        "center_px": [(cols[0] + cols[-1]) / 2.0, (rows[0] + rows[-1]) / 2.0],
        "length_cm": round((cols[-1] - cols[0]) / PX_PER_CM, 2),
        "width_cm": round((rows[-1] - rows[0]) / PX_PER_CM, 2),
        "track_cm": round(track_px / PX_PER_CM, 2),
        "wheel_diameter_cm": base["wheel_diameter_cm"],
        "wheels": wheels,
    }
    # The tilted picture, and where the robot's centre on the floor lands on it.
    centre = meta["bases"][name]["center_px"]
    cx, cz = from_top_px(centre, top_frame)
    floor_y = max(float(R.bounds(m.transformed(mat, off))[1][1]) for m, mat, off in base["parts"])
    tilted = R.render(base["parts"], "tilt", PX_PER_LDU, WHITE)
    tilted.save(out / f"{name}_base_tilt.png")
    meta["bases"][name].update({
        "image_tilt": f"{name}_base_tilt.png",
        "tilt_origin_px": [round(v, 2) for v in to_px(P(cx, floor_y, cz))],
        "sensor_height_cm": SENSOR_HEIGHT_CM,
    })
    print(name, meta["bases"][name]["length_cm"], meta["bases"][name]["track_cm"])
for name, entry in old_meta.get("bases", {}).items():
    meta["bases"].setdefault(name, entry)
# Sensors: from above (on the drawing, facing right) and from the front (in the palette).
for name, dat in (("ev3_ultrasonic", "95652.dat"), ("spike_distance", "37316.dat")):
    R.render([(R.load(dat), R.rot("y", -90), Z)], "top", PX_PER_LDU, WHITE).save(out / f"{name}_top.png")
    R.render([(R.load(dat), I, Z)], "front", PX_PER_LDU, WHITE).save(out / f"{name}_front.png")
    # On the tilted picture, one per direction a spot faces (degrees to the left
    # of ahead), each with the pixel its centre lands on.
    lo, hi = R.bounds(R.load(dat).transformed(R.rot("y", -90), Z))
    middle = (lo + hi) * 0.5
    tilt = {}
    for angle in SENSOR_ANGLES:
        turn = R.rot("y", -angle) @ R.rot("y", -90)
        file_name = f"{name}_tilt_{angle}.png"
        R.render([(R.load(dat), turn, Z)], "tilt", PX_PER_LDU, WHITE).save(out / file_name)
        tilt[str(angle)] = {"image": file_name, "anchor_px": [round(v, 2) for v in to_px(R.rot("y", -angle) @ middle)]}
    meta["sensors"][name] = {"tilt": tilt}
# Motors in the palette (their side, with the round hub), wheels for the wheel picker.
R.render([(R.load("95658.dat"), I, Z)], "side", PX_PER_LDU, WHITE).save(out / "ev3_large_motor_side.png")
R.render([(R.load("54696p01.dat"), I, Z)], "side", PX_PER_LDU, WHITE).save(out / "spike_motor_side.png")
R.render([(R.load("56145c03.dat"), I, Z)], "front", PX_PER_LDU, WHITE).save(out / "wheel_ev3_56.png")
R.render([(R.load("39367p01.dat"), I, Z)], "front", PX_PER_LDU, WHITE).save(out / "wheel_spike_56.png")
(out / "robots_art.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
print("done")
