from __future__ import annotations

from typing import Any, Dict, Mapping


class UserFacingRuntimeError(ValueError):
    def __init__(self, code: str, technical_message: str, details: Mapping[str, Any] | None = None) -> None:
        super().__init__(technical_message)
        self.code = code
        self.details = dict(details or {})


def error_payload(exc: Exception, operation: str) -> Dict[str, Any]:
    if isinstance(exc, UserFacingRuntimeError):
        code = exc.code
        details = exc.details
    else:
        code = "inference_failed" if operation == "inference" else "training_failed"
        details = {}
    return {
        "type": type(exc).__name__,
        "code": code,
        "details": details,
        "technical_message": f"{type(exc).__name__}: {exc}",
    }
