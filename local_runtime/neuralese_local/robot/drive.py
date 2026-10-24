"""Steer + throttle from the model -> power for a left and a right motor.

This is the conversion that drove the physical EV3 "KIRISIMA" correctly. It is a
line-for-line port of ``AdaptiveRobotController.compute`` from the robotics
prototype (``neuralese-robotics-prototype/run_real_model_drive.py`` at commit
``be2a4a5``). Do not "simplify" it: every step below changes how the robot moves,
and ``tests/test_robot_drive.py`` pins this module to the prototype's own
outputs, bit for bit, on two recorded runs and on randomised input sequences.

The only differences from the prototype are mechanical:

* The clock is passed in (``now``) instead of read from ``time.monotonic()``.
  The slew limiter and the turn lock depend on elapsed time, so this is what
  makes the behaviour testable at all.
* The constants are fields of :class:`DriveParams`, with the prototype's values
  as defaults.
* Status labels are stable codes instead of Russian UI strings; the UI
  localises them.
* The prototype's "wall bypass" branch (force a hard turn when something is
  close straight ahead and the model is not turning) is behind
  ``DriveParams.wall_bypass``. It overrides the child's model, so it is off by
  default. The prototype always ran with it on: on the two recorded runs its
  condition held in 5 of 1035 and 98 of 4220 frames. Its status label never
  shows, because the forced steer (0.85) always trips the turn lock, whose
  status replaces it. With ``wall_bypass=True`` the port equals the prototype
  exactly.

What the conversion does, in order:

1. Turn lock. When the model asks for a sharp turn (``|steer| > 0.55``) the
   direction is held for 350 ms: steering the other way is ignored and forward
   speed is zero, so the robot spins in place instead of wobbling.
2. Outside a lock, forward speed is ``throttle * (1 - |steer|) ** 1.8``: the
   harder the turn, the slower the robot goes forward.
3. Turning power is ``steer * 80``, added to the left side and subtracted from
   the right. ``steer > 0`` turns right.
4. If either side would exceed 100 %, both are pulled in by the excess, which
   keeps the difference between the sides (the turn) intact.
5. Each side may change by at most 260 % per second (slew limit), so commands
   ramp instead of jumping. ``dt`` is clamped to 10..100 ms; the first command
   after construction or :meth:`DriveController.reset` therefore moves at most
   26 % from zero.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional

STATUS_FORWARD = "forward"
STATUS_STEER_LEFT = "steer_left"
STATUS_STEER_RIGHT = "steer_right"
STATUS_SPIN_LEFT = "spin_left"
STATUS_SPIN_RIGHT = "spin_right"
STATUS_WALL_BYPASS_LEFT = "wall_bypass_left"
STATUS_WALL_BYPASS_RIGHT = "wall_bypass_right"


@dataclass(frozen=True)
class DriveParams:
    """Tuning of the conversion. Defaults are the values the real robot ran with."""

    #: Motor power per unit of steer: ``v_turn = steer * turn_power``.
    turn_power: float = 80.0
    #: Exponent of the forward-speed governor ``(1 - |steer|) ** exponent``.
    governor_exponent: float = 1.8
    #: Largest change of one side's power, in percent per second.
    slew_pct_per_s: float = 260.0
    #: ``|steer|`` above which the turn direction is locked.
    turn_lock_threshold: float = 0.55
    #: How long a turn lock lasts after the last sharp-turn request.
    turn_lock_s: float = 0.35
    #: ``|steer|`` above which the status reads as steering (status only).
    steer_status_threshold: float = 0.4
    #: Bounds of the time step fed to the slew limiter.
    min_dt_s: float = 0.01
    max_dt_s: float = 0.1
    #: Power limit of one side, in percent.
    max_power: float = 100.0
    #: The prototype's wall-bypass override. Off by default; see module docs.
    wall_bypass: bool = False
    wall_front_below: float = 0.50
    wall_steer_below: float = 0.25
    wall_escape_steer: float = 0.85
    wall_throttle_cap_pct: float = 25.0


class DriveCommand:
    """One computed command: integer power for each side, plus what produced it."""

    __slots__ = ("left", "right", "info")

    def __init__(self, left: int, right: int, info: Dict[str, Any]) -> None:
        self.left = left
        self.right = right
        self.info = info

    def as_tuple(self) -> tuple:
        return (self.left, self.right)


class DriveController:
    """Stateful conversion. One instance per running robot link.

    State is the previous (unrounded) power of each side, the time of the last
    call, and the turn lock. Call :meth:`reset` whenever the motors were stopped
    by something else (link stall, stop button), so the next command ramps up
    from zero instead of jumping back to where the robot was.
    """

    def __init__(self, params: Optional[DriveParams] = None, *, now: float) -> None:
        self.params = params or DriveParams()
        self.reset(now)

    def reset(self, now: float) -> None:
        self.prev_left = 0.0
        self.prev_right = 0.0
        self.last_time = float(now)
        self.turn_lock_dir = 0
        # The prototype starts with 0.0 on a monotonic clock that is far above
        # zero, i.e. "no lock". -inf keeps that meaning for any injected clock.
        self.turn_lock_until = float("-inf")

    def compute(
        self,
        steer: float,
        throttle_pct: float,
        *,
        now: float,
        front: float = 1.0,
        left: float = 1.0,
        right: float = 1.0,
    ) -> DriveCommand:
        """Convert one model output.

        ``steer`` is the model's steering output (-1 left .. +1 right).
        ``throttle_pct`` is its throttle output in percent (0..100).
        ``front``, ``left`` and ``right`` are normalised distances (0 touching,
        1 clear) and are only read by the wall-bypass override.
        """
        p = self.params
        dt = max(p.min_dt_s, min(p.max_dt_s, now - self.last_time))
        self.last_time = now

        steer = float(steer)
        throttle = float(throttle_pct)
        status = STATUS_FORWARD

        # --- 1. Wall bypass (prototype override, off by default) ---
        if p.wall_bypass and front < p.wall_front_below and abs(steer) < p.wall_steer_below:
            if left > right:
                steer = -p.wall_escape_steer
                status = STATUS_WALL_BYPASS_LEFT
            else:
                steer = p.wall_escape_steer
                status = STATUS_WALL_BYPASS_RIGHT
            throttle = min(throttle, p.wall_throttle_cap_pct)

        # --- 2. Turn lock ---
        if abs(steer) > p.turn_lock_threshold:
            self.turn_lock_dir = 1 if steer > 0 else -1
            self.turn_lock_until = now + p.turn_lock_s
        elif now > self.turn_lock_until:
            self.turn_lock_dir = 0

        if self.turn_lock_dir != 0:
            # While locked, steering the other way is ignored.
            if (steer * self.turn_lock_dir) < 0:
                steer = 0.0
            v_forward = 0.0
            throttle_governor = 0.0
            status = STATUS_SPIN_RIGHT if self.turn_lock_dir > 0 else STATUS_SPIN_LEFT
        else:
            throttle_governor = max(0.0, 1.0 - abs(steer)) ** p.governor_exponent
            v_forward = throttle * throttle_governor
            if abs(steer) > p.steer_status_threshold:
                status = STATUS_STEER_RIGHT if steer > 0 else STATUS_STEER_LEFT

        # --- 3. Turning power, opposite on the two sides ---
        v_turn = steer * p.turn_power

        target_left = v_forward + v_turn
        target_right = v_forward - v_turn

        # --- 4. Keep the turn when a side would exceed the power limit ---
        peak = max(abs(target_left), abs(target_right))
        if peak > p.max_power:
            excess = peak - p.max_power
            target_left = target_left - excess if target_left > 0 else target_left + excess
            target_right = target_right - excess if target_right > 0 else target_right + excess

        # --- 5. Slew limit ---
        max_delta = p.slew_pct_per_s * dt
        left_power = self.prev_left + max(-max_delta, min(max_delta, target_left - self.prev_left))
        right_power = self.prev_right + max(-max_delta, min(max_delta, target_right - self.prev_right))

        self.prev_left = left_power
        self.prev_right = right_power

        info = {
            "status": status,
            "turn_lock_dir": self.turn_lock_dir,
            "throttle_governor": round(float(throttle_governor), 3),
            "v_forward": round(float(v_forward), 1),
            "v_turn": round(float(v_turn), 1),
            "target_left": round(float(target_left), 1),
            "target_right": round(float(target_right), 1),
        }
        return DriveCommand(int(round(left_power)), int(round(right_power)), info)
