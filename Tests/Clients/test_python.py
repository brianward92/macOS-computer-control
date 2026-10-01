"""Client boundary tests using a real subprocess and an isolated fake CLI."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "clients" / "python"))
import macctl


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="macctl-python-client-")
        self.addCleanup(self.directory.cleanup)
        self.fake = Path(self.directory.name) / "macctl"
        shutil.copyfile(Path(__file__).parent / "fixtures" / "macctl", self.fake)
        self.fake.chmod(0o755)
        self.environment = patch.dict(os.environ, {
            "PATH": self.directory.name + os.pathsep + os.environ.get("PATH", ""),
            "MACCTL_TEST_RESPONSE": json.dumps({"code": 0, "data": {}}),
            "MACCTL_TEST_ARGV_FILE": str(Path(self.directory.name) / "argv.json"),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.helpers = {
            "read": lambda: macctl.read("Example App"),
            "text": lambda: macctl.text("Example App"),
            "controls": lambda: macctl.controls("Example App"),
            "front": macctl.front,
        }

    def respond(self, code, data=None, **extra):
        response = {"code": code, **extra}
        if data is not None:
            response["data"] = data
        os.environ["MACCTL_TEST_RESPONSE"] = json.dumps(response)

    def test_successful_empty_observations_keep_their_return_types(self):
        self.respond(0, {"lines": [], "text": "", "controls": [], "front": None})
        for name, expected in [("read", []), ("text", ""), ("controls", []), ("front", None)]:
            with self.subTest(helper=name):
                self.assertEqual(self.helpers[name](), expected)

    def test_successful_nonempty_observations_preserve_payload(self):
        payload = {"lines": [{"text": "Hello", "at": [0.2, 0.3]}], "text": "Hello\nWorld",
                   "controls": [{"role": "AXButton", "label": "Open", "at": [0.1, 0.2]}],
                   "front": {"name": "Example App", "pid": 123}}
        self.respond(0, payload)
        for name, field in [("read", "lines"), ("text", "text"), ("controls", "controls"), ("front", "front")]:
            with self.subTest(helper=name):
                self.assertEqual(self.helpers[name](), payload[field])

    def test_unknown_is_not_an_empty_or_partial_observation(self):
        for payload in [
            {"outcome": "unknown: capture failed"},
            {"outcome": "unknown: capture failed", "lines": [], "text": "", "controls": [], "front": None},
            {"outcome": "unknown: incomplete capture", "lines": [{"text": "Partial"}], "text": "Partial",
             "controls": [{"label": "Partial"}], "front": {"name": "Partial"}},
        ]:
            self.respond(2, payload)
            for name, call in self.helpers.items():
                with self.subTest(helper=name, payload=payload):
                    with self.assertRaises(macctl.ObservationUnknown) as caught:
                        call()
                    self.assertEqual(caught.exception.result.code, 2)
                    self.assertTrue(caught.exception.result.unknown)
                    self.assertEqual(caught.exception.result.data, payload)
                    self.assertEqual(str(caught.exception), payload["outcome"])
                    self.assertNotIsInstance(caught.exception, macctl.Refused)

    def test_unknown_without_json_preserves_stderr_reason(self):
        self.respond(2, stdout="", stderr="capture watchdog expired\n")
        for name, call in self.helpers.items():
            with self.subTest(helper=name):
                with self.assertRaises(macctl.ObservationUnknown) as caught:
                    call()
                self.assertEqual(caught.exception.result.data, {})
                self.assertEqual(caught.exception.result.reason, "capture watchdog expired")

    def test_refusals_remain_distinct_for_every_observation_helper(self):
        for code in (3, 4):
            for response in ({"data": {"outcome": "refused: unavailable"}}, {"stdout": "", "stderr": "permission missing"}):
                self.respond(code, **response)
                for name, call in self.helpers.items():
                    with self.subTest(helper=name, code=code, response=response):
                        with self.assertRaises(macctl.Refused):
                            call()

    def test_unsatisfied_payload_is_not_unwrapped_as_an_observation(self):
        self.respond(1, {"outcome": "unsatisfied", "text": "", "lines": []})
        for name, call in self.helpers.items():
            with self.subTest(helper=name):
                with self.assertRaises(macctl.ObservationError) as caught:
                    call()
                self.assertNotIsInstance(caught.exception, macctl.ObservationUnknown)
                self.assertEqual(caught.exception.result.code, 1)

    def test_result_returning_helpers_preserve_unknown_without_throwing(self):
        self.respond(2, {"outcome": "unknown: not observable", "verified": False})
        calls = [lambda: macctl.run("read", "Example App"), lambda: macctl.window("Example App"),
                 lambda: macctl.click("Example App", .2, .3), lambda: macctl.drag("Example App", .1, .2, .3, .4),
                 lambda: macctl.click_text("Example App", "Open"), lambda: macctl.verify("Example App", "Saved"),
                 lambda: macctl.wait_for("Example App", "Saved"), lambda: macctl.navigate("Example App", "about:blank"),
                 lambda: macctl.wait_idle("Example App"), lambda: macctl.activate("Example App", "Open"),
                 lambda: macctl.choose("Example App", "Off", "On"), lambda: macctl.focus("Example App"), macctl.restore]
        for call in calls:
            result = call()
            self.assertTrue(result.unknown)
            self.assertFalse(result.satisfied)
            self.assertEqual(result.code, 2)
        self.respond(1, {"outcome": "unsatisfied"})
        self.assertFalse(macctl.verify("Example App", "Saved").unknown)
        self.respond(3, {"outcome": "refused: permission missing"})
        self.assertEqual(macctl.run("doctor").code, 3)

    def test_subprocess_arguments_remain_literal(self):
        self.respond(0, {"text": "literal"})
        app = "Example App ; $(not-a-command)"
        self.assertEqual(macctl.text(app), "literal")
        self.assertEqual(json.loads(Path(os.environ["MACCTL_TEST_ARGV_FILE"]).read_text()), ["text", app])


if __name__ == "__main__":
    unittest.main()
