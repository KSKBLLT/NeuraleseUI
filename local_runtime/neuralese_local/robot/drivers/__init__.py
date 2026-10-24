"""Drivers: each one turns a robot family into a :class:`..ir.RobotIR` and
reads/writes its channels. :mod:`..virtual_device` puts any driver on the
NLR/1 link the bridge already speaks.
"""

from __future__ import annotations

from .base import RobotDriver

__all__ = ["RobotDriver"]
