"""Runs a generated device script against stubbed device modules."""

from __future__ import annotations

import sys
import threading
import time
from typing import Any, Dict, Optional

from .device_stubs import BytePipe, DeviceWorld, Halt, PipeTransport


class StubDeviceRunner:
    """Executes a generated device script on a thread, as the device would.

    The script is an infinite loop, so it is unwound by making the stubbed
    ``sleep``/``wait`` raise once the test is finished with it -- the same trick
    the device's own power switch performs.
    """

    def __init__(self, script_source: str, modules: Dict[str, Any], world: DeviceWorld, pipe: BytePipe) -> None:
        self.script_source = script_source
        self.modules = modules
        self.world = world
        self.pipe = pipe
        self.thread: Optional[threading.Thread] = None
        self.error: Optional[BaseException] = None
        self._saved: Dict[str, Any] = {}

    def install_modules(self) -> None:
        for name, module in self.modules.items():
            self._saved[name] = sys.modules.get(name)
            sys.modules[name] = module

    def restore_modules(self) -> None:
        for name, previous in self._saved.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous
        self._saved.clear()

    def start(self) -> None:
        self.install_modules()
        namespace = {"__name__": "neuralese_generated_device"}
        compiled = compile(self.script_source, "<generated device script>", "exec")

        def run() -> None:
            try:
                exec(compiled, namespace)
            except Halt:
                pass
            except BaseException as exc:  # noqa: BLE001 - surfaced to the test
                self.error = exc

        self.thread = threading.Thread(target=run, name="stub-device", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.world.halted = True
        if self.thread is not None:
            self.thread.join(timeout=3.0)
        self.restore_modules()

    def transport(self) -> PipeTransport:
        return PipeTransport(self.pipe)

    def wait_until(self, predicate, timeout: float = 5.0, pump=None) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            if pump is not None:
                pump()
            if self.error is not None:
                raise AssertionError("The device script crashed: %r" % (self.error,))
            time.sleep(0.002)
        return bool(predicate())
