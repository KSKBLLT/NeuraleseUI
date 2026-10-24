"""The interface every robot driver implements.

Times are passed in (``now``, seconds on a monotonic clock) rather than read
inside the driver, so a simulated robot advances exactly as far as the test or
the link says, and a real one can be tested against a fake clock.
"""

from __future__ import annotations

from typing import Dict, List, Sequence

from ..ir import RobotIR


class RobotDriver:
    """One connected (or simulated) robot."""

    def inventory(self) -> RobotIR:
        """What is plugged into the robot right now."""
        raise NotImplementedError

    def open(self, now: float) -> None:
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError

    def tick(self, now: float) -> None:
        """Advance to ``now``. Simulated robots move; real ones refresh leases."""

    def read(self, channels: Sequence[str], now: float) -> List[int]:
        """Current native values of these channels, in this order."""
        raise NotImplementedError

    def write(self, values: Dict[str, int], now: float) -> None:
        """Command these actuator channels."""
        raise NotImplementedError

    def stop(self, now: float) -> None:
        """Every actuator to its inert value. Must never raise."""
        raise NotImplementedError
