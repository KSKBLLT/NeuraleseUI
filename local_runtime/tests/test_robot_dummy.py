"""Dummy robot: the simulated EV3 every host-side feature is tested on.

Each test sets up a world simple enough that the right answer is arithmetic
(a wall at a known distance, full power for a known time), then checks the
Dummy against it. The numbers it is calibrated to come from the prototype's
fit to the real robot; see the module docstring of ``drivers/dummy.py``.
"""

from __future__ import annotations

import math
import unittest

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot.drivers.dummy import NO_ECHO_MM, DummyDriver, DummyHardware, DummyWorld

#: Large motor at full power: 35 cm/s, the prototype's measured figure.
FULL_SPEED_CM_S = 35.0


def wall_world(x_cm: float, angle_deg: float = 90.0) -> DummyWorld:
    """One long wall through (x_cm, 0); 90 deg is square across the robot's path."""
    a = math.radians(angle_deg)
    dx, dy = 1000.0 * math.cos(a), 1000.0 * math.sin(a)
    return DummyWorld(walls=[(x_cm - dx, -dy, x_cm + dx, dy)], start=(0.0, 0.0, 0.0))


def driver(world: DummyWorld = None, seed: int = 0, **hardware) -> DummyDriver:
    d = DummyDriver(world=world or DummyWorld(start=(0.0, 0.0, 0.0)), seed=seed,
                    hardware=DummyHardware.from_dict(hardware) if hardware else None)
    d.open(0.0)
    return d


def hold(d: DummyDriver, left: int, right: int, seconds: float, start: float = 0.0, every: float = 0.05) -> float:
    """Keep re-sending a power command, as the bridge does at 20 Hz."""
    t = start
    while t < start + seconds - 1e-9:
        d.write({"outD.power": left, "outB.power": right}, t)
        t += every
        d.tick(t)
    return t


class MotionTests(unittest.TestCase):
    def test_full_power_drives_straight_at_the_calibrated_speed(self) -> None:
        d = driver()
        hold(d, 100, 100, 2.0)
        pose = d.pose()
        # Two seconds at full speed, minus the motor's 80 ms spin-up.
        expected = FULL_SPEED_CM_S * (2.0 - d.hardware.motor_time_constant_s)
        self.assertAlmostEqual(pose["x_cm"], expected, delta=1.0)
        self.assertAlmostEqual(pose["y_cm"], 0.0, places=6)
        self.assertAlmostEqual(pose["heading_deg"], 0.0, places=6)

    def test_left_faster_than_right_turns_clockwise(self) -> None:
        d = driver(ports={"in1": "gyro", "outB": "large_motor", "outD": "large_motor"})
        hold(d, 50, -50, 1.0)
        pose = d.pose()
        self.assertLess(pose["heading_deg"], -30.0)
        self.assertAlmostEqual(pose["x_cm"], 0.0, places=6)  # spinning in place
        # The EV3 gyro counts clockwise as positive.
        angle, rate = d.read(["in1.angle_deg", "in1.rate_dps"], 1.0)
        self.assertAlmostEqual(angle, -pose["heading_deg"], delta=1.0)
        self.assertGreater(rate, 0)

    def test_spin_rate_matches_the_effective_track(self) -> None:
        d = driver()
        hold(d, 100, -100, 2.0)
        # Wheels at +35 and -35 cm/s: omega = 70 / track rad/s, after the spin-up.
        rate_deg_s = math.degrees(2.0 * FULL_SPEED_CM_S / d.hardware.effective_track_cm)
        expected_deg = rate_deg_s * (2.0 - d.hardware.motor_time_constant_s)
        self.assertAlmostEqual(-d.pose()["heading_deg"], expected_deg, delta=3.0)

    def test_a_command_lasts_300_ms_then_the_motor_stops(self) -> None:
        # The EV3 stock firmware semantics the prototype relied on: a host that
        # goes quiet stops the robot.
        d = driver()
        d.write({"outD.power": 100, "outB.power": 100}, 0.0)
        d.tick(2.0)
        travelled = d.pose()["x_cm"]
        self.assertGreater(travelled, FULL_SPEED_CM_S * 0.2)
        self.assertLess(travelled, FULL_SPEED_CM_S * 0.45)
        self.assertEqual(d.read(["outD.speed_dps", "outB.speed_dps"], 2.0), [0, 0])

    def test_stop_cancels_the_lease(self) -> None:
        d = driver()
        d.write({"outD.power": 100, "outB.power": 100}, 0.0)
        d.tick(0.1)
        d.stop(0.1)
        d.tick(1.0)
        self.assertLess(d.pose()["x_cm"], FULL_SPEED_CM_S * 0.15)

    def test_encoders_count_degrees(self) -> None:
        d = driver()
        hold(d, 100, 100, 1.0)
        d.tick(2.0)
        position = d.read(["outD.position_deg"], 2.0)[0]
        # 1050 deg/s for ~1 s plus the spin-down; the same distance the wheel rolled.
        rolled_deg = d.pose()["x_cm"] / (math.pi * d.hardware.wheel_diameter_cm) * 360.0
        self.assertAlmostEqual(position, rolled_deg, delta=2.0)

    def test_a_reversed_motor_drives_backwards(self) -> None:
        d = driver(left_polarity=-1)
        hold(d, 100, 100, 1.0)
        self.assertAlmostEqual(d.pose()["x_cm"], 0.0, places=6)  # wheels cancel: spin
        self.assertGreater(d.pose()["heading_deg"], 30.0)

    def test_only_motor_power_can_be_written(self) -> None:
        d = driver()
        for channel in ("in2.distance_mm", "outD.position_deg", "outA.power"):
            with self.subTest(channel=channel):
                with self.assertRaises(KeyError):
                    d.write({channel: 1}, 0.0)
        with self.assertRaises(KeyError):
            d.read(["in1.distance_mm"], 0.0)

    def test_power_is_limited_to_the_motor_range(self) -> None:
        d = driver()
        d.write({"outD.power": 250, "outB.power": -250}, 0.0)
        self.assertEqual(d.read(["outD.power", "outB.power"], 0.0), [100, -100])


class CollisionTests(unittest.TestCase):
    def test_the_body_never_enters_a_wall(self) -> None:
        d = driver(world=wall_world(50.0), ports={"in1": "touch", "outB": "large_motor", "outD": "large_motor"})
        hold(d, 100, 100, 3.0)
        self.assertLessEqual(d.pose()["x_cm"], 50.0 - d.hardware.body_radius_cm + 1e-6)
        self.assertGreater(d.pose()["x_cm"], 50.0 - d.hardware.body_radius_cm - 1.0)
        self.assertTrue(d.bumped)
        self.assertEqual(d.read(["in1.pressed"], 3.0), [1])

    def test_backing_away_frees_the_robot(self) -> None:
        d = driver(world=wall_world(50.0))
        t = hold(d, 100, 100, 3.0)
        hold(d, -100, -100, 0.5, start=t)
        self.assertFalse(d.bumped)
        self.assertLess(d.pose()["x_cm"], 30.0)


class SonarTests(unittest.TestCase):
    def test_reads_the_distance_from_the_sensor_in_millimetres(self) -> None:
        d = driver(world=wall_world(100.0))
        readings = [d.read(["in3.distance_mm"], 0.0)[0] for _ in range(200)]
        mean = sum(readings) / len(readings)
        # The centre sonar sits 9 cm ahead of the robot's centre.
        self.assertAlmostEqual(mean, 910.0, delta=2.0)
        self.assertLess(max(readings) - min(readings), 50)  # noise, not dropouts
        self.assertGreater(max(readings) - min(readings), 0)

    def test_nothing_in_range_reads_as_no_echo(self) -> None:
        d = driver()
        self.assertEqual(d.read(["in2.distance_mm", "in3.distance_mm", "in4.distance_mm"], 0.0), [NO_ECHO_MM] * 3)
        far = driver(world=wall_world(400.0))
        self.assertEqual(far.read(["in3.distance_mm"], 0.0), [NO_ECHO_MM])

    def test_side_sonars_look_sideways(self) -> None:
        # A wall along the robot's left side, 50 cm away: only the left sonar
        # (port 4, +45 deg) sees it.
        world = DummyWorld(walls=[(-500.0, 50.0, 500.0, 50.0)], start=(0.0, 0.0, 0.0))
        d = driver(world=world)
        left, centre, right = d.read(["in4.distance_mm", "in3.distance_mm", "in2.distance_mm"], 0.0)
        self.assertLess(left, 700)
        self.assertEqual(centre, NO_ECHO_MM)
        self.assertEqual(right, NO_ECHO_MM)

    def test_the_beam_is_a_cone(self) -> None:
        # A post 8..11 deg off the centre sonar's axis is still seen. The cone
        # is sampled by a few rays (every 5 deg by default), so a post thinner
        # than the gap between two of them can slip through, as a chair leg
        # sometimes does for a real sonar.
        low, high = (math.tan(math.radians(a)) * 60.0 for a in (8.0, 11.0))
        world = DummyWorld(walls=[(69.0, low, 69.0, high)], start=(0.0, 0.0, 0.0))
        self.assertLess(driver(world=world).read(["in3.distance_mm"], 0.0)[0], 700)
        narrow = driver(world=world, ultrasonic_cone_deg=0.0, ultrasonic_cone_rays=1)
        self.assertEqual(narrow.read(["in3.distance_mm"], 0.0)[0], NO_ECHO_MM)

    def test_glancing_walls_lose_their_echo_some_of_the_time(self) -> None:
        # Hit 70 deg from square-on: past the 60 deg ricochet angle.
        d = driver(world=wall_world(100.0, angle_deg=20.0), seed=3, ultrasonic_cone_deg=0.0, ultrasonic_cone_rays=1)
        readings = [d.read(["in3.distance_mm"], 0.0)[0] for _ in range(400)]
        lost = sum(1 for r in readings if r == NO_ECHO_MM) / len(readings)
        self.assertGreater(lost, 0.35)
        self.assertLess(lost, 0.65)
        square = driver(world=wall_world(100.0), seed=3)
        self.assertNotIn(NO_ECHO_MM, [square.read(["in3.distance_mm"], 0.0)[0] for _ in range(400)])

    def test_never_reads_closer_than_the_sensor_minimum(self) -> None:
        d = driver(world=wall_world(10.0))
        self.assertTrue(all(r >= d.hardware.ultrasonic_min_mm for r in d.read(["in3.distance_mm"] * 50, 0.0)))


class DeterminismTests(unittest.TestCase):
    def _trace(self, seed: int) -> list:
        d = DummyDriver(seed=seed)
        d.open(0.0)
        out = []
        t = 0.0
        for k in range(100):
            d.write({"outD.power": 60, "outB.power": 40 if k % 20 < 10 else 70}, t)
            t += 0.05
            out.append(tuple(d.read(["in2.distance_mm", "in3.distance_mm", "in4.distance_mm"], t)) + (round(d.x, 9),))
        return out

    def test_same_seed_same_run(self) -> None:
        self.assertEqual(self._trace(7), self._trace(7))

    def test_the_seed_only_changes_the_noise(self) -> None:
        a, b = self._trace(7), self._trace(8)
        self.assertNotEqual(a, b)
        self.assertEqual([r[-1] for r in a], [r[-1] for r in b])  # same path


class WorldTests(unittest.TestCase):
    def test_presets(self) -> None:
        self.assertEqual(len(DummyWorld.from_dict(None).walls), 8)
        self.assertEqual(len(DummyWorld.from_dict({"preset": "default"}).walls), 8)
        self.assertEqual(len(DummyWorld.from_dict({"preset": "narrow_gap"}).walls), 12)
        with self.assertRaises(ValueError):
            DummyWorld.from_dict({"preset": "moon"})

    def test_custom_world(self) -> None:
        world = DummyWorld.from_dict({"walls": [[0, 0, 10, 0]], "boxes": [[50, 50, 10, 10]], "start": [1, 2, 90]})
        self.assertEqual(len(world.walls), 5)
        self.assertEqual(world.start, (1.0, 2.0, 90.0))

    def test_the_default_room_starts_clear_of_every_wall(self) -> None:
        d = DummyDriver()
        from neuralese_local.robot.drivers.dummy import _distance_to_segment

        nearest = min(_distance_to_segment(d.x, d.y, w) for w in d.world.walls)
        self.assertGreater(nearest, 2 * d.hardware.body_radius_cm)


if __name__ == "__main__":
    unittest.main()
