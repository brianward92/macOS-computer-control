"""Intentionally partial Python wrapper over the macctl CLI.

The CLI is the contract; this only saves you writing subprocess boilerplate.
run() and action helpers return the parsed JSON line plus the exit code,
because 2 is "could not observe", which is not the same as failure. Helpers
that unwrap observation payloads raise ObservationUnknown for exit 2; an empty
list/string or None therefore still means a successfully observed empty result.
"""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from typing import Any


class Refused(RuntimeError):
    """macctl declined to act: no permission, no window, or an ambiguous target."""


@dataclass(frozen=True)
class Result:
    code: int
    data: dict[str, Any]
    stderr: str = ""

    @property
    def satisfied(self) -> bool:
        return self.code == 0

    @property
    def unknown(self) -> bool:
        """Could not observe. Deliberately distinct from unsatisfied."""
        return self.code == 2

    @property
    def reason(self) -> str | None:
        return self.data.get("outcome") or self.data.get("error") or self.stderr.strip() or None


class ObservationError(RuntimeError):
    """An observation helper could not return a successful payload.

    The complete CLI result is available as ``result``; successful empty
    observations never raise this exception.
    """

    def __init__(self, result: Result):
        self.result = result
        super().__init__(result.reason or f"macctl observation exited {result.code}")


class ObservationUnknown(ObservationError):
    """Exit 2: could not observe, or invalid usage; not evidence of absence."""


def run(*args: str, check: bool = False) -> Result:
    proc = subprocess.run(
        ["macctl", *map(str, args)], capture_output=True, text=True
    )
    line = proc.stdout.strip().splitlines()
    data = json.loads(line[-1]) if line else {}
    result = Result(proc.returncode, data, proc.stderr)
    if check and proc.returncode in (3, 4):
        raise Refused(result.reason or proc.stderr.strip())
    return result


def _observation(*args: str) -> dict[str, Any]:
    result = run(*args, check=True)
    if result.unknown:
        raise ObservationUnknown(result)
    if not result.satisfied:
        raise ObservationError(result)
    return result.data


def window(app: str) -> Result:
    return run("window", app, check=True)


def click(app: str, fx: float, fy: float, count: int = 1, button: str = "left") -> Result:
    return run("click", app, fx, fy, "--count", count, "--button", button, check=True)


def drag(app: str, fx1: float, fy1: float, fx2: float, fy2: float, steps: int = 24) -> Result:
    return run("drag", app, fx1, fy1, fx2, fy2, "--steps", steps, check=True)


def click_text(app: str, text: str, timeout: float = 0) -> Result:
    """timeout=0 is a single look; a single miss is unknown, not absent."""
    return run("click-text", app, text, "--timeout", timeout)


def verify(app: str, text: str) -> Result:
    return run("verify", app, text)


def wait_for(app: str, text: str, timeout: float = 30) -> Result:
    return run("wait-for", app, text, "--timeout", timeout)


def read(app: str) -> list[dict[str, Any]]:
    """OCR lines; raises ObservationUnknown when the screen could not be read."""
    return _observation("read", app).get("lines", [])


def text(app: str) -> str:
    """The app's text via accessibility, OCR as fallback. Prefer over read for content."""
    return _observation("text", app).get("text", "")


def navigate(app: str, url: str, timeout: float = 15) -> Result:
    """Open a URL in a browser and return once the page has loaded."""
    return run("navigate", app, url, "--timeout", timeout, check=True)


def wait_idle(app: str, timeout: float = 10) -> Result:
    """Return the instant the app's text stops changing, instead of a fixed sleep."""
    return run("wait-idle", app, "--timeout", timeout)


def controls(app: str) -> list[dict[str, Any]]:
    """Actionable controls by name, via accessibility."""
    return _observation("controls", app).get("controls", [])


def activate(app: str, control: str) -> Result:
    """Press a control by name via accessibility. Works where posted clicks are swallowed."""
    return run("activate", app, control, check=True)


def choose(app: str, popup: str, value: str) -> Result:
    """Set a popup menu to a value via accessibility; the result carries before/after."""
    return run("choose", app, popup, value, check=True)


def front() -> dict[str, Any] | None:
    """The frontmost app right now."""
    return _observation("front").get("front")


def focus(app: str) -> Result:
    """Bring an app to the front and stop."""
    return run("focus", app, check=True)


def restore(forget: bool = False) -> Result:
    """Put the person back where they were before the first focus change.

    The tool records the origin itself on the first focus-changing command;
    this brings it forward and clears the record. forget=True clears without
    moving focus, for a task whose point was to land them elsewhere.
    """
    return run("restore", *(["--forget"] if forget else []), check=True)
