from __future__ import annotations

import io
import json
import os
import pathlib
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from octoprint_companion.client import (
    ClientError,
    MAX_JSON_BODY,
    OctoPrintClient,
    Response,
    SecretStore,
    authorize,
    canonical_url,
    classify_state,
    configure,
    image_dimensions,
    normalize_status,
    set_setting,
    _mjpeg_frames,
)


FIXTURES = pathlib.Path(__file__).parent / "fixtures"
TEST_JPEG = b"\xff\xd8\xff\xc0\x00\x11\x08\x00\x01\x00\x01" + (b"\x00" * 10) + b"\xff\xd9"


def fixture(name: str):
    return json.loads((FIXTURES / name).read_text())


class OctoPrintHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    starts: list[tuple[str, float]] = []
    api_key_headers: list[str | None] = []

    def log_message(self, *_args):
        pass

    def respond(self, status: int, body: bytes = b"", content_type: str = "application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).starts.append((self.path, time.monotonic()))
        type(self).api_key_headers.append(self.headers.get("X-Api-Key"))
        if self.path == "/api/job":
            time.sleep(0.15)
            self.respond(200, json.dumps(fixture("printing-job.json")).encode())
        elif self.path == "/api/printer?exclude=sd":
            time.sleep(0.15)
            self.respond(200, json.dumps(fixture("printing-printer.json")).encode())
        elif self.path == "/snapshot":
            self.respond(200, TEST_JPEG, "image/jpeg")
        elif self.path in {"/stream", "/stream-no-length"}:
            frames = (TEST_JPEG, TEST_JPEG)
            parts = []
            for frame in frames:
                length = b"" if self.path.endswith("no-length") else b"Content-Length: " + str(len(frame)).encode() + b"\r\n"
                parts.append(b"--frame\r\nContent-Type: image/jpeg\r\n" + length + b"\r\n" + frame + b"\r\n")
            self.respond(200, b"".join(parts) + b"--frame--\r\n", "multipart/x-mixed-replace; boundary=frame")
        elif self.path == "/redirect-cross":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/snapshot")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/forbidden":
            self.respond(403, b'{"error":"forbidden"}')
        elif self.path == "/api/version":
            self.respond(200, b'{"api":"0.1","server":"2.0.0"}')
        else:
            self.respond(404, b"{}")

    def do_POST(self):
        type(self).api_key_headers.append(self.headers.get("X-Api-Key"))
        length = int(self.headers.get("Content-Length", "0"))
        self.server.last_post = (self.path, json.loads(self.rfile.read(length) or b"{}"))
        self.respond(204)


class ServerCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), OctoPrintHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        OctoPrintHandler.starts = []
        OctoPrintHandler.api_key_headers = []

    def test_status_is_normalized_and_requests_are_concurrent(self):
        client = OctoPrintClient(self.url, "test-key", timeout=2)
        started = time.monotonic()
        result = client.fetch_status()
        elapsed = time.monotonic() - started

        self.assertEqual(result["state"], "printing")
        self.assertEqual(result["job"]["name"], "voronoi-lamp.gcode")
        self.assertEqual(result["progress"]["completion"], 63.4)
        self.assertEqual(result["temperature"]["tool0"]["actual"], 211.3)
        self.assertLess(elapsed, 0.27, "status endpoints were fetched sequentially")
        self.assertEqual(OctoPrintHandler.api_key_headers, ["test-key", "test-key"])

    def test_pause_resume_and_cancel_payloads(self):
        client = OctoPrintClient(self.url, "test-key")
        expectations = {
            "pause": {"command": "pause", "action": "pause"},
            "resume": {"command": "pause", "action": "resume"},
            "cancel": {"command": "cancel"},
        }
        for action, payload in expectations.items():
            with self.subTest(action=action):
                client.command(action)
                self.assertEqual(self.server.last_post, ("/api/job", payload))

    def test_snapshot_uses_private_runtime_file(self):
        client = OctoPrintClient(self.url, "test-key")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": directory}
        ):
            target = client.fetch_snapshot("/snapshot")
            self.assertEqual(target.read_bytes(), TEST_JPEG)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertTrue(str(target).startswith(directory))
            self.assertEqual(OctoPrintHandler.api_key_headers[-1], "test-key")

    def test_snapshot_does_not_leak_key_cross_origin(self):
        other = OctoPrintClient("http://localhost:9", "test-key", timeout=1)
        with mock.patch("octoprint_companion.client.open_request") as urlopen:
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.headers.get_content_type.return_value = "image/jpeg"
            response.read.return_value = TEST_JPEG
            urlopen.return_value = response
            with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
                os.environ, {"XDG_RUNTIME_DIR": directory}
            ):
                other.fetch_snapshot(f"{self.url}/snapshot")
            request = urlopen.call_args.args[0]
            self.assertIsNone(request.get_header("X-api-key"))
            self.assertTrue(urlopen.call_args.kwargs["protect_origin"])

    def test_stream_uses_one_connection_and_private_runtime_file(self):
        client = OctoPrintClient(self.url, "test-key")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": directory}
        ):
            paths = list(client.stream_frames("/stream", frames_per_second=1_000_000_000))
            self.assertEqual(len(paths), 2)
            self.assertEqual(paths[-1].read_bytes(), TEST_JPEG)
            self.assertEqual(paths[-1].stat().st_mode & 0o777, 0o600)
            self.assertEqual(OctoPrintHandler.api_key_headers[-1], "test-key")

    def test_stream_accepts_frames_without_content_length(self):
        client = OctoPrintClient(self.url, "test-key")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": directory}
        ):
            paths = list(client.stream_frames("/stream-no-length", frames_per_second=1_000_000_000))
            self.assertEqual(len(paths), 2)
            self.assertEqual(paths[-1].read_bytes(), TEST_JPEG)

    def test_stream_does_not_leak_key_cross_origin(self):
        other = OctoPrintClient("http://localhost:9", "test-key", timeout=1)
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": directory}
        ):
            list(other.stream_frames(f"{self.url}/stream", frames_per_second=1_000_000_000))
        self.assertIsNone(OctoPrintHandler.api_key_headers[-1])

    def test_authenticated_snapshot_refuses_cross_origin_redirect(self):
        client = OctoPrintClient(self.url, "test-key")
        with self.assertRaisesRegex(ClientError, "unsafe cross-origin redirect"):
            client.fetch_snapshot("/redirect-cross")
        self.assertEqual([path for path, _started in OctoPrintHandler.starts], ["/redirect-cross"])

    def test_camera_rejects_credentials_at_runtime(self):
        client = OctoPrintClient(self.url, "test-key")
        for path in (
            "/snapshot?token=never",
            "/snapshot#secret",
            "file:///tmp/snapshot.jpg",
            "//camera.example/snapshot",
        ):
            with self.subTest(path=path), self.assertRaises(ClientError):
                client.fetch_snapshot(path)
        self.assertEqual(OctoPrintHandler.starts, [])

    def test_api_response_size_is_bounded(self):
        client = OctoPrintClient(self.url, "test-key")
        with mock.patch("octoprint_companion.client.open_request") as urlopen:
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.read.return_value = b"x" * (MAX_JSON_BODY + 1)
            urlopen.return_value = response
            with self.assertRaisesRegex(ClientError, "unexpectedly large response"):
                client.request("GET", "/api/version")

    def test_stream_boundary_search_is_bounded_per_frame_not_per_stream(self):
        part = b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(TEST_JPEG)).encode() + b"\r\n\r\n" + TEST_JPEG + b"\r\n"
        stream = io.BytesIO(part * 70 + b"--frame--\r\n")
        self.assertEqual(len(list(_mjpeg_frames(stream, b"frame"))), 70)

    def test_camera_accepts_bounded_jpeg_and_rejects_unsafe_images(self):
        self.assertEqual(image_dimensions(TEST_JPEG), (1, 1))
        with self.assertRaisesRegex(ClientError, "JPEG or PNG"):
            image_dimensions(b"<svg/>")
        huge_png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (9000).to_bytes(4, "big") + (9000).to_bytes(4, "big")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": directory}
        ), self.assertRaisesRegex(ClientError, "dimensions"):
            OctoPrintClient._store_frame(huge_png, "snapshot.png")

    def test_api_key_authorization_validates_before_storing(self):
        with mock.patch.object(SecretStore, "store") as store:
            authorize(self.url, api_key=" dedicated-key ")
        store.assert_called_once_with(self.url, "dedicated-key")

    def test_browser_authorization_rejects_cross_origin_urls(self):
        responses = [
            Response(204, {}, b""),
            Response(
                201,
                {"Location": "/plugin/appkeys/request/opaque"},
                b'{"auth_dialog":"https://attacker.example/authorize"}',
            ),
        ]
        with mock.patch.object(OctoPrintClient, "request", side_effect=responses), mock.patch(
            "octoprint_companion.client.subprocess.Popen"
        ) as popen, self.assertRaisesRegex(ClientError, "unsafe authorization URL"):
            authorize(self.url)
        popen.assert_not_called()

    def test_forget_clears_only_the_canonical_server_key(self):
        with mock.patch("octoprint_companion.client.subprocess.run") as run:
            SecretStore.clear(self.url)

        self.assertEqual(
            run.call_args.args[0],
            [
                "secret-tool",
                "clear",
                "application",
                "io.github.luxore.octoprint",
                "server",
                self.url,
            ],
        )
        self.assertFalse(run.call_args.kwargs["check"])


class NormalizationCase(unittest.TestCase):
    def test_disconnected_printer_keeps_truthful_job_state(self):
        job = {"state": "Offline", "job": {"file": {}}, "progress": {}}
        result = normalize_status(job, None)
        self.assertEqual(result["state"], "offline")
        self.assertFalse(result["connected"])
        self.assertFalse(result["faulted"])
        self.assertEqual(result["errorMessage"], "")
        self.assertIsNone(result["progress"]["completion"])

    def test_offline_after_error_is_disconnected_and_faulted(self):
        job = {
            "state": "Offline after error",
            "job": {"file": {"display": "stale-job.gcode"}},
            "progress": {},
            "error": "Too many consecutive timeouts, printer still connected and alive?",
        }
        result = normalize_status(job, None)
        self.assertEqual(result["state"], "offline")
        self.assertEqual(result["stateText"], "Offline after error")
        self.assertFalse(result["connected"])
        self.assertTrue(result["faulted"])
        self.assertEqual(
            result["errorMessage"],
            "Too many consecutive timeouts, printer still connected and alive?",
        )

    def test_error_state_keeps_firmware_message(self):
        result = normalize_status(
            {"state": "Error", "job": {}, "progress": {}, "error": "Thermal runaway"},
            None,
        )
        self.assertEqual(result["state"], "error")
        self.assertTrue(result["faulted"])
        self.assertTrue(result["connected"])
        self.assertEqual(result["errorMessage"], "Thermal runaway")

    def test_cancelling_wins_over_printing_flag(self):
        printer = {
            "state": {
                "text": "Cancelling",
                "flags": {
                    "operational": True,
                    "printing": True,
                    "cancelling": True,
                    "paused": False,
                    "error": False,
                },
            }
        }
        result = normalize_status({"job": {}, "progress": {}}, printer)
        self.assertEqual(result["state"], "cancelling")
        self.assertFalse(result["faulted"])

    def test_pausing_is_paused_not_printing(self):
        printer = {
            "state": {
                "text": "Pausing",
                "flags": {
                    "operational": True,
                    "printing": True,
                    "pausing": True,
                    "paused": False,
                    "error": False,
                },
            }
        }
        result = normalize_status({"job": {}, "progress": {}}, printer)
        self.assertEqual(result["state"], "paused")

    def test_finishing_stays_printing_so_completion_can_notify(self):
        printer = {
            "state": {
                "text": "Finishing",
                "flags": {
                    "operational": True,
                    "printing": True,
                    "finishing": True,
                    "error": False,
                },
            }
        }
        result = normalize_status({"job": {}, "progress": {}}, printer)
        self.assertEqual(result["state"], "printing")

    def test_classify_state_covers_octoprint_wire_labels(self):
        self.assertEqual(classify_state("Offline after error"), ("offline", True))
        self.assertEqual(classify_state("Offline"), ("offline", False))
        self.assertEqual(classify_state("Error"), ("error", True))
        self.assertEqual(classify_state("Cancelling"), ("cancelling", False))
        self.assertEqual(classify_state("Printing from SD"), ("printing", False))
        self.assertEqual(classify_state("Starting print from SD"), ("printing", False))

    def test_paused_flag_wins_over_operational(self):
        printer = {
            "state": {
                "text": "Paused",
                "flags": {"operational": True, "paused": True},
            }
        }
        result = normalize_status({"job": {}, "progress": {}}, printer)
        self.assertEqual(result["state"], "paused")

    def test_invalid_url_is_rejected(self):
        with self.assertRaisesRegex(ClientError, "complete OctoPrint URL"):
            OctoPrintClient("")

    def test_bare_hostname_and_ip_get_a_helpful_http_default(self):
        self.assertEqual(canonical_url("octopi.local"), "http://octopi.local")
        self.assertEqual(canonical_url("192.0.2.42:5000"), "http://192.0.2.42:5000")

    def test_invalid_port_is_rejected_before_network_access(self):
        with self.assertRaisesRegex(ClientError, "invalid port"):
            canonical_url("http://octopi.local:not-a-port")

    def test_credentials_in_url_are_rejected(self):
        with self.assertRaisesRegex(ClientError, "Do not put credentials"):
            OctoPrintClient("http://admin:secret@octopi.local")

    def test_configure_persists_only_validated_non_secret_settings(self):
        values = {
            "cameraMode": "stream",
            "showProgress": "true",
            "notifyFinished": "true",
            "notifyPaused": "false",
            "notifyError": "true",
        }
        with mock.patch("octoprint_companion.client.subprocess.run") as run:
            result = configure("printer.local", "/snapshot", "/stream", values)

        self.assertEqual(result, "http://printer.local")
        calls = [call.args[0] for call in run.call_args_list]
        self.assertIn(
            [
                "omarchy",
                "bar",
                "set",
                "io.github.luxore.octoprint",
                "instanceUrl",
                "http://printer.local",
            ],
            calls,
        )
        self.assertEqual(calls[-1][-2:], ["setupComplete", "true"])
        self.assertNotIn("apiKey", {call[-2] for call in calls})

    def test_configure_rejects_secret_bearing_or_invalid_camera_settings(self):
        with self.assertRaisesRegex(ClientError, "Unsupported"):
            configure("printer.local", "/snapshot", "/stream", {"apiKey": "never"})
        with self.assertRaisesRegex(ClientError, "Stream, Snapshots, or Off"):
            configure("printer.local", "/snapshot", "/stream", {"cameraMode": "both"})
        with self.assertRaisesRegex(ClientError, "credentials"):
            configure("printer.local", "/snapshot?apikey=never", "/stream")

    def test_configure_can_save_only_the_server(self):
        with mock.patch("octoprint_companion.client.subprocess.run") as run:
            configure("printer.local")

        calls = [call.args[0] for call in run.call_args_list]
        self.assertEqual([call[-2] for call in calls], ["instanceUrl", "setupComplete"])

    def test_set_setting_accepts_preferences_and_rejects_tuning(self):
        with mock.patch("octoprint_companion.client.subprocess.run") as run:
            set_setting("cameraMode", "off")
            set_setting("notifyError", "false")

        self.assertEqual(run.call_count, 2)
        with self.assertRaisesRegex(ClientError, "Unsupported"):
            set_setting("refreshMode", "gentle")
        with self.assertRaisesRegex(ClientError, "true or false"):
            set_setting("notifyError", "sometimes")


if __name__ == "__main__":
    unittest.main()
