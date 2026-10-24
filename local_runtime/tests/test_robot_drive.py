"""Drive controller: steer + throttle -> power for the left and right motor.

The expected values are produced by the robotics prototype's own controller,
the one that drove the EV3 "KIRISIMA" correctly (see
``fixtures/robot_drive/build_fixtures.py``). Three things are checked
separately, because they fail for different reasons:

* the port equals the prototype, bit for bit, on recorded and random inputs;
* the port reproduces what the robot logged, within a tolerance whose cause is
  measured (the logs do not record the controller's own time step);
* individual behaviours, so a failure names the step that broke.
"""

from __future__ import annotations

import gzip
import json
import unittest
from pathlib import Path

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot.drive import (
    STATUS_FORWARD,
    STATUS_SPIN_LEFT,
    STATUS_SPIN_RIGHT,
    STATUS_STEER_RIGHT,
    DriveController,
    DriveParams,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "robot_drive"

#: The prototype always ran with its wall-bypass branch active.
PROTOTYPE_PARAMS = DriveParams(wall_bypass=True)


def _load(name: str) -> dict:
    with gzip.open(FIXTURES / name, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def _replay(params: DriveParams, inputs: list, init_time: float) -> list:
    ctrl = DriveController(params, now=init_time)
    out = []
    for t, steer, throttle_pct, left, center, right in inputs:
        cmd = ctrl.compute(steer, throttle_pct, now=t, front=center, left=left, right=right)
        i = cmd.info
        out.append([cmd.left, cmd.right, i["turn_lock_dir"], i["target_left"], i["target_right"],
                    i["v_forward"], i["v_turn"], i["throttle_governor"], i["status"]])
    return out


def _run_inputs(run: dict) -> list:
    # frame: step, timestamp_s, dt_ms, steer, throttle_pct, left, center, right, ...
    return [[f[1], f[3], f[4], f[5], f[6], f[7]] for f in run["frames"]]


class PrototypeEquivalenceTests(unittest.TestCase):
    """The port must compute exactly what the prototype computes."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.runs = _load("kirisima_runs.json.gz")
        cls.random = _load("random_sequences.json.gz")

    def test_recorded_runs_match_the_prototype_exactly(self) -> None:
        for run in self.runs["runs"]:
            with self.subTest(run=run["name"]):
                got = _replay(PROTOTYPE_PARAMS, _run_inputs(run), self.runs["init_time"])
                self.assertEqual(len(got), len(run["prototype"]))
                for index, (mine, theirs) in enumerate(zip(got, run["prototype"])):
                    if mine != theirs:
                        self.fail("frame %d: port %s, prototype %s" % (index, mine, theirs))

    def test_random_sequences_match_the_prototype_exactly(self) -> None:
        for sequence in self.random["sequences"]:
            with self.subTest(seed=sequence["seed"]):
                got = _replay(PROTOTYPE_PARAMS, sequence["inputs"], sequence["init_time"])
                for index, (mine, theirs) in enumerate(zip(got, sequence["prototype"])):
                    if mine != theirs:
                        self.fail("seed %d frame %d: port %s, prototype %s"
                                  % (sequence["seed"], index, mine, theirs))

    def test_random_sequences_cross_every_threshold(self) -> None:
        # Guards the fixture itself: equality on inputs that never reach a
        # branch would prove nothing about that branch.
        inputs = [i for s in self.random["sequences"] for i in s["inputs"]]
        outputs = [o for s in self.random["sequences"] for o in s["prototype"]]
        self.assertTrue(any(i[4] < 0.5 and abs(i[1]) < 0.25 for i in inputs), "wall-bypass condition")
        self.assertTrue(any(o[2] == 1 for o in outputs) and any(o[2] == -1 for o in outputs), "turn lock")
        self.assertTrue(any(abs(o[3]) >= 99.95 or abs(o[4]) >= 99.95 for o in outputs), "power limit")
        times = [i[0] for s in self.random["sequences"] for i in s["inputs"]]
        steps = [b - a for a, b in zip(times, times[1:])]
        self.assertTrue(any(0 <= d < 0.01 for d in steps) and any(d > 0.1 for d in steps), "dt clamps")


class HardwareFidelityTests(unittest.TestCase):
    """The port, run on the logged inputs and clock, reproduces the robot.

    The decisions (turn lock, target power) match frame for frame. Motor power
    goes through the slew limiter, whose time step the logs do not record; the
    record timestamp is taken after the motors were commanded, so it jitters
    against the controller's own clock. Measured residual: motors exact on
    95.9 % and 96.0 % of frames; the rest are frames where the slew limiter was
    active, or where a target sits on a .5 rounding edge of the logged inputs.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.runs = _load("kirisima_runs.json.gz")

    def _compare(self, run: dict) -> dict:
        got = _replay(PROTOTYPE_PARAMS, _run_inputs(run), self.runs["init_time"])
        stats = {"frames": len(got), "decision_mismatch": 0, "motor_exact": 0, "max_motor_error": 0}
        for mine, frame in zip(got, run["frames"]):
            logged_lock, logged_tl, logged_tr, logged_ml, logged_mr = frame[8], frame[9], frame[10], frame[11], frame[12]
            # Logged inputs are rounded (steer 4 dp, throttle 1 dp) and so are
            # the logged targets (1 dp): 0.11 covers both.
            same_decision = (mine[2] == logged_lock and abs(mine[3] - logged_tl) < 0.11
                             and abs(mine[4] - logged_tr) < 0.11)
            stats["decision_mismatch"] += not same_decision
            error = max(abs(mine[0] - logged_ml), abs(mine[1] - logged_mr))
            stats["motor_exact"] += error == 0
            stats["max_motor_error"] = max(stats["max_motor_error"], error)
        return stats

    def test_decisions_match_the_robot(self) -> None:
        # The one mismatch in the long run is a turn lock expiring on the
        # boundary frame, inside the clock jitter described above.
        allowed = {"datalog_20261007_222935.jsonl": 0, "datalog_20261007_223501.jsonl": 1}
        for run in self.runs["runs"]:
            with self.subTest(run=run["name"]):
                self.assertLessEqual(self._compare(run)["decision_mismatch"], allowed[run["name"]])

    def test_motor_power_matches_the_robot_within_the_measured_jitter(self) -> None:
        for run in self.runs["runs"]:
            with self.subTest(run=run["name"]):
                stats = self._compare(run)
                self.assertGreaterEqual(stats["motor_exact"] / stats["frames"], 0.955)
                self.assertLessEqual(stats["max_motor_error"], 17)

    def test_the_robot_ran_with_the_wall_bypass_active(self) -> None:
        # Documents the measurement behind DriveParams.wall_bypass: the branch
        # condition held on real frames, so the logged motors include it.
        counts = {run["name"]: sum(1 for f in run["frames"] if f[6] < 0.5 and abs(f[3]) < 0.25)
                  for run in self.runs["runs"]}
        self.assertEqual(counts, {"datalog_20261007_222935.jsonl": 5, "datalog_20261007_223501.jsonl": 98})


class BehaviourTests(unittest.TestCase):
    def test_defaults_are_the_values_the_robot_ran_with(self) -> None:
        p = DriveParams()
        self.assertEqual(
            (p.turn_power, p.governor_exponent, p.slew_pct_per_s, p.turn_lock_threshold, p.turn_lock_s,
             p.min_dt_s, p.max_dt_s, p.max_power),
            (80.0, 1.8, 260.0, 0.55, 0.35, 0.01, 0.1, 100.0),
        )
        self.assertFalse(p.wall_bypass)

    def test_first_command_after_start_moves_at_most_26_percent(self) -> None:
        ctrl = DriveController(now=10.0)
        cmd = ctrl.compute(0.0, 100.0, now=20.0)
        self.assertEqual(cmd.as_tuple(), (26, 26))
        self.assertEqual(cmd.info["target_left"], 100.0)

    def test_positive_steer_turns_right(self) -> None:
        ctrl = DriveController(now=0.0)
        for step in range(1, 20):
            cmd = ctrl.compute(0.3, 60.0, now=step * 0.05)
        self.assertGreater(cmd.left, cmd.right)
        self.assertEqual(cmd.info["status"], STATUS_FORWARD)
        self.assertEqual(cmd.info["v_turn"], 24.0)

    def test_sharp_turn_spins_in_place_and_holds_direction(self) -> None:
        ctrl = DriveController(now=0.0)
        cmd = ctrl.compute(0.6, 80.0, now=0.05)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["v_forward"], cmd.info["status"]), (1, 0.0, STATUS_SPIN_RIGHT))
        # Inside the 350 ms hold, steering the other way is ignored.
        cmd = ctrl.compute(-0.3, 80.0, now=0.30)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["v_turn"], cmd.info["v_forward"]), (1, 0.0, 0.0))
        # After it, the controller follows the model again.
        cmd = ctrl.compute(-0.3, 80.0, now=0.45)
        self.assertEqual(cmd.info["turn_lock_dir"], 0)
        self.assertEqual(cmd.info["v_turn"], -24.0)
        cmd = ctrl.compute(-0.6, 80.0, now=0.50)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["status"]), (-1, STATUS_SPIN_LEFT))

    def test_power_limit_keeps_the_difference_between_sides(self) -> None:
        ctrl = DriveController(now=0.0)
        cmd = ctrl.compute(0.1, 120.0, now=1.0)
        left, right = cmd.info["target_left"], cmd.info["target_right"]
        self.assertEqual(left, 100.0)
        self.assertAlmostEqual(left - right, 16.0, places=1)

    def test_slew_limit_caps_change_per_second(self) -> None:
        ctrl = DriveController(now=0.0)
        ctrl.compute(0.0, 0.0, now=0.05)
        cmd = ctrl.compute(0.0, 100.0, now=0.10)
        self.assertEqual(cmd.as_tuple(), (13, 13))  # 260 %/s * 50 ms
        cmd = ctrl.compute(0.0, 100.0, now=0.10)
        self.assertEqual(cmd.as_tuple(), (16, 16))  # dt clamped up to 10 ms: +2.6

    def test_reset_ramps_up_from_zero_again(self) -> None:
        ctrl = DriveController(now=0.0)
        for step in range(1, 30):
            ctrl.compute(0.0, 100.0, now=step * 0.05)
        ctrl.reset(now=5.0)
        cmd = ctrl.compute(0.0, 100.0, now=5.05)
        self.assertEqual(cmd.as_tuple(), (13, 13))

    def test_wall_bypass_off_leaves_the_model_in_control(self) -> None:
        ctrl = DriveController(now=0.0)
        cmd = ctrl.compute(0.1, 60.0, now=0.05, front=0.2, left=0.9, right=0.1)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["v_turn"]), (0, 8.0))

    def test_wall_bypass_on_turns_towards_the_clearer_side(self) -> None:
        ctrl = DriveController(DriveParams(wall_bypass=True), now=0.0)
        cmd = ctrl.compute(0.1, 60.0, now=0.05, front=0.2, left=0.9, right=0.1)
        # Forced steer -0.85 trips the turn lock, whose status replaces the
        # wall-bypass one -- the reason that branch is invisible in the logs.
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["v_turn"], cmd.info["status"]), (-1, -68.0, STATUS_SPIN_LEFT))
        ctrl = DriveController(DriveParams(wall_bypass=True), now=0.0)
        cmd = ctrl.compute(0.1, 60.0, now=0.05, front=0.2, left=0.1, right=0.9)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["v_turn"]), (1, 68.0))

    def test_steering_status_outside_a_lock(self) -> None:
        ctrl = DriveController(now=0.0)
        cmd = ctrl.compute(0.5, 50.0, now=0.05)
        self.assertEqual((cmd.info["turn_lock_dir"], cmd.info["status"]), (0, STATUS_STEER_RIGHT))


if __name__ == "__main__":
    unittest.main()
