"""Typed errors for the robot export path.

Every failure the UI can surface carries a stable ``code`` so the Godot side can
translate it, plus a ``field`` when the failure points at one row of the mapping
config (so the UI can highlight that row instead of showing a wall of text).
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

# Stable error codes. Godot/UI matches on these; never renumber, only append.
ERR_UNKNOWN_PLATFORM = "unknown_platform"
ERR_UNSUPPORTED_TRANSPORT = "unsupported_transport"
ERR_BAD_CONFIG = "bad_config"
ERR_UNKNOWN_CHANNEL = "unknown_channel"
ERR_ARITY_MISMATCH = "arity_mismatch"
ERR_MISSING_DEPENDENCY = "missing_dependency"
ERR_MODEL_NOT_FOUND = "model_not_found"
ERR_MODEL_UNREADABLE = "model_unreadable"
ERR_LINK_FAILED = "link_failed"
ERR_HANDSHAKE_FAILED = "handshake_failed"
ERR_PROTOCOL_MISMATCH = "protocol_mismatch"
ERR_LINK_TIMEOUT = "link_timeout"
ERR_BAD_FRAME = "bad_frame"
ERR_EXPORT_FAILED = "export_failed"


class RobotError(Exception):
    """Base error carrying a UI-stable code."""

    code = ERR_EXPORT_FAILED

    def __init__(self, message: str, *, code: Optional[str] = None, field: str = "", details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.message = message
        if code:
            self.code = code
        self.field = field
        self.details = details or {}

    def to_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"code": self.code, "message": self.message}
        if self.field:
            payload["field"] = self.field
        if self.details:
            payload["details"] = self.details
        return payload


class ConfigError(RobotError):
    code = ERR_BAD_CONFIG


class MissingDependencyError(RobotError):
    """A transport backend needs a package the shipped runtime may not have."""

    code = ERR_MISSING_DEPENDENCY


class LinkError(RobotError):
    code = ERR_LINK_FAILED


class ProtocolError(RobotError):
    code = ERR_BAD_FRAME


class ValidationReport:
    """Collects config problems so the UI can show all of them at once.

    Validation deliberately does not stop at the first problem: a child fixing
    one dropdown at a time, with a round trip through the UI for each, is the
    exact cognitive load this feature is supposed to remove.
    """

    def __init__(self) -> None:
        self.errors: List[Dict[str, Any]] = []
        self.warnings: List[Dict[str, Any]] = []

    def error(self, code: str, message: str, field: str = "", **details: Any) -> None:
        entry: Dict[str, Any] = {"code": code, "message": message}
        if field:
            entry["field"] = field
        if details:
            entry["details"] = details
        self.errors.append(entry)

    def warn(self, code: str, message: str, field: str = "", **details: Any) -> None:
        entry: Dict[str, Any] = {"code": code, "message": message}
        if field:
            entry["field"] = field
        if details:
            entry["details"] = details
        self.warnings.append(entry)

    @property
    def ok(self) -> bool:
        return not self.errors

    def raise_if_failed(self) -> None:
        if self.ok:
            return
        first = self.errors[0]
        raise ConfigError(
            first["message"],
            code=first.get("code", ERR_BAD_CONFIG),
            field=first.get("field", ""),
            details={"errors": self.errors, "warnings": self.warnings},
        )

    def to_dict(self) -> Dict[str, Any]:
        return {"ok": self.ok, "errors": self.errors, "warnings": self.warnings}
