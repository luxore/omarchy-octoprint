"""Small, dependency-free OctoPrint client.

The QML surface consumes a stable model from this module instead of learning
OctoPrint's wire format. Secrets are retrieved from the desktop keyring for
each short-lived helper process and are never accepted as command arguments.
"""

from __future__ import annotations

import concurrent.futures
import getpass
import json
import os
import pathlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

from . import __version__


APP_ID = "io.github.luxore.octoprint"
APP_NAME = "Omarchy OctoPrint"
USER_AGENT = f"{APP_NAME}/{__version__}"
MAX_JSON_BODY = 2 * 1024 * 1024
MAX_CAMERA_FRAME = 10 * 1024 * 1024
MAX_CAMERA_PIXELS = 16_000_000
MAX_CAMERA_DIMENSION = 8192
SENSITIVE_QUERY_KEYS = {
    "apikey",
    "api_key",
    "key",
    "password",
    "secret",
    "token",
    "access_token",
}


class ClientError(RuntimeError):
    """An error safe to show on the plugin surface."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def canonical_url(value: str) -> str:
    value = value.strip().rstrip("/")
    if "://" not in value:
        value = f"http://{value}"
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ClientError("Set a complete OctoPrint URL, including http:// or https://")
    if parsed.username is not None or parsed.password is not None:
        raise ClientError("Do not put credentials in the OctoPrint URL")
    try:
        parsed.port
    except ValueError as error:
        raise ClientError("The configured URL has an invalid port") from error
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def origin(url: str) -> tuple[str, str | None, int | None]:
    parsed = urllib.parse.urlsplit(url)
    default_port = 443 if parsed.scheme.lower() == "https" else 80
    try:
        port = parsed.port or default_port
    except ValueError as error:
        raise ClientError("The configured URL has an invalid port") from error
    return parsed.scheme.lower(), parsed.hostname, port


def validate_camera_path(value: str) -> None:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme and parsed.scheme not in {"http", "https"}:
        raise ClientError("Camera URLs must use http:// or https://")
    if parsed.netloc and not parsed.scheme:
        raise ClientError("Use a complete http:// or https:// camera URL")
    if parsed.scheme and not parsed.netloc:
        raise ClientError("Use a complete http:// or https:// camera URL")
    if parsed.username is not None or parsed.password is not None:
        raise ClientError("Do not put credentials in a camera URL")
    if parsed.fragment:
        raise ClientError("Do not put fragments in a camera URL")
    query_keys = {key.lower() for key, _ in urllib.parse.parse_qsl(parsed.query)}
    if query_keys & SENSITIVE_QUERY_KEYS:
        raise ClientError("Do not put credentials in a camera URL")


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Keep a request on its original origin across redirects."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if origin(request.full_url) != origin(new_url):
            raise ClientError("OctoPrint attempted an unsafe cross-origin redirect")
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def open_request(request: urllib.request.Request, timeout: float, *, protect_origin: bool):
    if protect_origin:
        return urllib.request.build_opener(SameOriginRedirectHandler()).open(request, timeout=timeout)
    return urllib.request.urlopen(request, timeout=timeout)


class SecretStore:
    """Store one application key per OctoPrint origin in Secret Service."""

    @staticmethod
    def lookup(server: str) -> str | None:
        try:
            result = subprocess.run(
                ["secret-tool", "lookup", "application", APP_ID, "server", server],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None
        key = result.stdout.strip()
        return key if result.returncode == 0 and key else None

    @staticmethod
    def store(server: str, key: str) -> None:
        try:
            subprocess.run(
                [
                    "secret-tool",
                    "store",
                    f"--label={APP_NAME} at {server}",
                    "application",
                    APP_ID,
                    "server",
                    server,
                ],
                input=key,
                text=True,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=10,
            )
        except FileNotFoundError as error:
            raise ClientError("secret-tool is required to store the OctoPrint key") from error
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise ClientError("Could not store the OctoPrint key in the desktop keyring") from error

    @staticmethod
    def clear(server: str) -> None:
        try:
            subprocess.run(
                ["secret-tool", "clear", "application", APP_ID, "server", server],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except FileNotFoundError as error:
            raise ClientError("Secret Service is unavailable") from error
        except subprocess.TimeoutExpired as error:
            raise ClientError("Secret Service did not respond") from error


@dataclass(frozen=True)
class Response:
    status: int
    headers: Any
    body: bytes

    def json(self) -> Any:
        if not self.body:
            return None
        try:
            return json.loads(self.body)
        except json.JSONDecodeError as error:
            raise ClientError("OctoPrint returned unreadable data", self.status) from error


class OctoPrintClient:
    def __init__(self, server: str, api_key: str | None = None, timeout: float = 4.0):
        self.server = canonical_url(server)
        self.api_key = api_key
        self.timeout = timeout

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        *,
        authenticated: bool = True,
    ) -> Response:
        url = urllib.parse.urljoin(self.server + "/", path.lstrip("/"))
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        if authenticated and self.api_key:
            headers["X-Api-Key"] = self.api_key
        body = None
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with open_request(
                request,
                self.timeout,
                protect_origin=bool(authenticated and self.api_key),
            ) as response:
                body = response.read(MAX_JSON_BODY + 1)
                if len(body) > MAX_JSON_BODY:
                    raise ClientError("OctoPrint returned an unexpectedly large response")
                return Response(response.status, response.headers, body)
        except urllib.error.HTTPError as error:
            detail = ""
            try:
                error_body = error.read(MAX_JSON_BODY + 1)
                if len(error_body) <= MAX_JSON_BODY:
                    parsed = json.loads(error_body)
                    detail = str(parsed.get("error") or parsed.get("message") or "")
            except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
                pass
            if error.code == 403:
                detail = "OctoPrint authorization is required"
            elif not detail:
                detail = f"OctoPrint returned HTTP {error.code}"
            raise ClientError(detail, error.code) from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ClientError("OctoPrint is unreachable") from error

    def get_json(self, path: str, *, authenticated: bool = True) -> Any:
        return self.request("GET", path, authenticated=authenticated).json()

    def fetch_status(self) -> dict[str, Any]:
        """Fetch independent job and printer resources in one network round."""
        results: dict[str, Any] = {}
        errors: dict[str, ClientError] = {}

        def fetch(name: str, path: str) -> None:
            try:
                results[name] = self.get_json(path)
            except ClientError as error:
                errors[name] = error

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            futures = [
                executor.submit(fetch, "job", "/api/job"),
                executor.submit(fetch, "printer", "/api/printer?exclude=sd"),
            ]
            concurrent.futures.wait(futures)

        auth_error = next((error for error in errors.values() if error.status == 403), None)
        if auth_error:
            raise auth_error
        if "job" not in results:
            raise errors.get("job", ClientError("OctoPrint job status is unavailable"))
        # /api/printer legitimately returns 409 while the printer is disconnected.
        printer_error = errors.get("printer")
        if printer_error and printer_error.status != 409:
            raise printer_error
        return normalize_status(results["job"], results.get("printer"))

    def command(self, action: str) -> None:
        if action == "pause":
            payload = {"command": "pause", "action": "pause"}
        elif action == "resume":
            payload = {"command": "pause", "action": "resume"}
        elif action == "cancel":
            payload = {"command": "cancel"}
        else:
            raise ClientError(f"Unsupported command: {action}")
        self.request("POST", "/api/job", payload)

    def _camera_request(self, path: str, accept: str) -> tuple[urllib.request.Request, bool]:
        validate_camera_path(path)
        target_url = urllib.parse.urljoin(self.server + "/", path)
        same_origin = origin(target_url) == origin(self.server)
        headers = {"Accept": accept, "User-Agent": USER_AGENT}
        if self.api_key and same_origin:
            headers["X-Api-Key"] = self.api_key
        return urllib.request.Request(target_url, headers=headers), True

    @staticmethod
    def _store_frame(body: bytes, name: str) -> pathlib.Path:
        if len(body) > MAX_CAMERA_FRAME:
            raise ClientError("The webcam frame is unexpectedly large")
        width, height = image_dimensions(body)
        if (
            width <= 0
            or height <= 0
            or width > MAX_CAMERA_DIMENSION
            or height > MAX_CAMERA_DIMENSION
            or width * height > MAX_CAMERA_PIXELS
        ):
            raise ClientError("The webcam frame dimensions are unexpectedly large")
        runtime_value = os.environ.get("XDG_RUNTIME_DIR")
        if not runtime_value:
            raise ClientError("XDG_RUNTIME_DIR is unavailable; refusing to store a camera frame")
        frame_dir = pathlib.Path(runtime_value) / APP_ID
        frame_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        frame_dir.chmod(0o700)
        target = frame_dir / name
        temporary = frame_dir / f"{name}.{os.getpid()}.tmp"
        temporary.write_bytes(body)
        temporary.chmod(0o600)
        temporary.replace(target)
        return target

    def fetch_snapshot(self, snapshot_path: str) -> pathlib.Path:
        request, protect_origin = self._camera_request(snapshot_path, "image/*")
        try:
            with open_request(
                request,
                self.timeout,
                protect_origin=protect_origin,
            ) as response:
                content_type = response.headers.get_content_type()
                if not content_type.startswith("image/"):
                    raise ClientError("The configured snapshot URL did not return an image")
                body = response.read(MAX_CAMERA_FRAME + 1)
        except urllib.error.HTTPError as error:
            if error.code == 403:
                raise ClientError("The webcam denied access", 403) from error
            raise ClientError(f"The webcam returned HTTP {error.code}", error.code) from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ClientError("The webcam is unreachable") from error
        return self._store_frame(body, "snapshot.jpg")

    def stream_frames(self, stream_path: str, frames_per_second: float = 5.0):
        """Yield private frame paths from one bounded MJPEG connection."""
        request, protect_origin = self._camera_request(stream_path, "multipart/x-mixed-replace")
        try:
            with open_request(request, self.timeout, protect_origin=protect_origin) as response:
                if response.headers.get_content_type() != "multipart/x-mixed-replace":
                    raise ClientError("The configured stream URL did not return an MJPEG stream")
                boundary = response.headers.get_boundary()
                if not boundary:
                    raise ClientError("The webcam stream did not declare a frame boundary")
                next_frame_at = 0.0
                for body in _mjpeg_frames(response, boundary.encode()):
                    now = time.monotonic()
                    if now < next_frame_at:
                        continue
                    yield self._store_frame(body, "stream.jpg")
                    next_frame_at = now + 1.0 / max(1.0, frames_per_second)
        except urllib.error.HTTPError as error:
            if error.code == 403:
                raise ClientError("The webcam denied access", 403) from error
            raise ClientError(f"The webcam returned HTTP {error.code}", error.code) from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ClientError("The webcam stream is unreachable") from error


def _mjpeg_frames(response, boundary: bytes):
    if not boundary or len(boundary) > 200:
        raise ClientError("The webcam stream returned an invalid frame boundary")
    marker = b"--" + boundary
    closing_marker = marker + b"--"
    boundary_ready = False
    while True:
        if not boundary_ready:
            for _ in range(64):
                line = response.readline(8192)
                if not line:
                    return
                if len(line) >= 8192:
                    raise ClientError("The webcam stream returned an invalid frame preamble")
                stripped = line.strip()
                if stripped == closing_marker:
                    return
                if stripped == marker:
                    break
            else:
                raise ClientError("The webcam stream returned an invalid frame preamble")
        boundary_ready = False

        headers: dict[str, str] = {}
        header_bytes = 0
        for _ in range(64):
            line = response.readline(8192)
            if not line:
                raise ClientError("The webcam stream ended inside frame headers")
            header_bytes += len(line)
            if len(line) >= 8192 or header_bytes > 65536:
                raise ClientError("The webcam stream returned oversized frame headers")
            if line in {b"\r\n", b"\n"}:
                break
            try:
                name, value = line.decode("latin-1").split(":", 1)
            except ValueError as error:
                raise ClientError("The webcam stream returned malformed frame headers") from error
            headers[name.strip().lower()] = value.strip()
        else:
            raise ClientError("The webcam stream returned too many frame headers")

        length_value = headers.get("content-length")
        if length_value:
            try:
                length = int(length_value)
            except ValueError as error:
                raise ClientError("The webcam stream returned an invalid frame length") from error
            if length < 0 or length > MAX_CAMERA_FRAME:
                raise ClientError("The webcam frame is unexpectedly large")
            body = response.read(length)
            if len(body) != length:
                raise ClientError("The webcam stream ended inside a frame")
            yield body
            continue

        chunks: list[bytes] = []
        size = 0
        while True:
            line = response.readline(MAX_CAMERA_FRAME + 1)
            if not line:
                raise ClientError("The webcam stream ended inside a frame")
            stripped = line.strip()
            if stripped in {marker, closing_marker}:
                body = b"".join(chunks).rstrip(b"\r\n")
                yield body
                if stripped == closing_marker:
                    return
                boundary_ready = True
                break
            size += len(line)
            if size > MAX_CAMERA_FRAME:
                raise ClientError("The webcam frame is unexpectedly large")
            chunks.append(line)


def image_dimensions(body: bytes) -> tuple[int, int]:
    if body.startswith(b"\x89PNG\r\n\x1a\n"):
        if len(body) < 24 or body[12:16] != b"IHDR":
            raise ClientError("The webcam returned an invalid PNG frame")
        return int.from_bytes(body[16:20], "big"), int.from_bytes(body[20:24], "big")

    if not body.startswith(b"\xff\xd8"):
        raise ClientError("The webcam must return a JPEG or PNG frame")
    offset = 2
    start_of_frame = {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
    }
    while offset < len(body):
        while offset < len(body) and body[offset] != 0xFF:
            offset += 1
        while offset < len(body) and body[offset] == 0xFF:
            offset += 1
        if offset >= len(body):
            break
        marker = body[offset]
        offset += 1
        if marker == 0x01 or 0xD0 <= marker <= 0xD9:
            continue
        if offset + 2 > len(body):
            break
        segment_length = int.from_bytes(body[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(body):
            break
        if marker in start_of_frame:
            if segment_length < 7:
                break
            height = int.from_bytes(body[offset + 3 : offset + 5], "big")
            width = int.from_bytes(body[offset + 5 : offset + 7], "big")
            return width, height
        if marker == 0xDA:
            break
        offset += segment_length
    raise ClientError("The webcam returned an invalid JPEG frame")


def classify_state(state_text: str, flags: dict[str, Any] | None = None) -> tuple[str, bool]:
    """Map OctoPrint's wire state onto the companion's small public machine.

    OctoPrint sets ``flags.printing`` for starting, printing, cancelling,
    pausing, resuming, and finishing. Cancelling and pausing must win so a
    cancelled job is not later reported as finished, and so pause is visible
    while the printer is still settling. ``Offline after error`` stays
    disconnected, but ``faulted`` marks that it is not a quiet power-off.
    """
    flags = flags or {}
    lowered = state_text.lower()
    faulted = bool(flags.get("error")) or "error" in lowered

    if flags.get("cancelling") or lowered == "cancelling":
        return "cancelling", faulted
    if flags.get("paused") or flags.get("pausing") or "paused" in lowered or lowered == "pausing":
        return "paused", faulted
    if flags.get("printing") or flags.get("resuming") or flags.get("finishing"):
        return "printing", faulted
    if lowered in {"printing", "resuming", "finishing", "starting"} or lowered.startswith(
        ("printing ", "starting")
    ):
        return "printing", faulted
    if "offline" in lowered or "disconnected" in lowered or lowered == "closed":
        return "offline", faulted
    if flags.get("error") or "error" in lowered:
        return "error", True
    if flags.get("operational") or flags.get("ready") or lowered in {"operational", "ready"}:
        return "idle", faulted
    return "offline", faulted


def _error_message(job: dict[str, Any], state_data: dict[str, Any]) -> str:
    for candidate in (job.get("error"), state_data.get("error")):
        if isinstance(candidate, str) and candidate.strip():
            return candidate.strip()
    return ""


def normalize_status(job: dict[str, Any], printer: dict[str, Any] | None) -> dict[str, Any]:
    printer = printer or {}
    state_data = printer.get("state") or {}
    flags = state_data.get("flags") or {}
    state_text = str(state_data.get("text") or job.get("state") or "Unknown")
    state, faulted = classify_state(state_text, flags)

    job_data = job.get("job") or {}
    file_data = job_data.get("file") or {}
    progress_data = job.get("progress") or {}
    completion = progress_data.get("completion")
    remaining = progress_data.get("printTimeLeft")
    fetched_at = int(time.time() * 1000)
    temperatures = printer.get("temperature") or {}

    def temperature(name: str) -> dict[str, float | None]:
        values = temperatures.get(name) or {}
        return {"actual": values.get("actual"), "target": values.get("target")}

    return {
        "configured": True,
        "connected": state != "offline",
        "state": state,
        "stateText": state_text,
        "faulted": faulted,
        "errorMessage": _error_message(job, state_data),
        "job": {
            "name": file_data.get("display") or file_data.get("name") or "",
            "path": file_data.get("path") or "",
        },
        "progress": {
            "completion": completion,
            "printTime": progress_data.get("printTime"),
            "printTimeLeft": remaining,
            "etaAt": fetched_at + int(remaining * 1000) if isinstance(remaining, (int, float)) else None,
        },
        "temperature": {
            "tool0": temperature("tool0"),
            "bed": temperature("bed"),
        },
        "fetchedAt": fetched_at,
    }


def authorize(
    server: str,
    *,
    manual: bool = False,
    api_key: str | None = None,
    timeout: int = 120,
) -> None:
    server = canonical_url(server)
    if manual or api_key is not None:
        key = api_key.strip() if api_key is not None else getpass.getpass("OctoPrint API key: ").strip()
        if not key:
            raise ClientError("No API key entered")
        OctoPrintClient(server, key).get_json("/api/version")
        SecretStore.store(server, key)
        return

    client = OctoPrintClient(server, timeout=5)
    probe = client.request("GET", "/plugin/appkeys/probe", authenticated=False)
    if probe.status != 204:
        raise ClientError("This OctoPrint server does not support application-key authorization")
    response = client.request(
        "POST",
        "/plugin/appkeys/request",
        {"app": APP_NAME},
        authenticated=False,
    )
    payload = response.json() or {}
    poll_path = response.headers.get("Location") or f"/plugin/appkeys/request/{payload.get('app_token', '')}"
    dialog = payload.get("auth_dialog")
    if not dialog or not poll_path:
        raise ClientError("OctoPrint did not start the authorization flow")
    dialog_url = urllib.parse.urljoin(server + "/", dialog)
    poll_url = urllib.parse.urljoin(server + "/", poll_path)
    if origin(dialog_url) != origin(server) or origin(poll_url) != origin(server):
        raise ClientError("OctoPrint returned an unsafe authorization URL")
    try:
        subprocess.Popen(
            ["xdg-open", dialog_url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        raise ClientError("Could not open the OctoPrint authorization page") from error

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(1)
        try:
            decision = client.request("GET", poll_url, authenticated=False)
        except ClientError as error:
            if error.status == 404:
                raise ClientError("OctoPrint authorization was denied or expired") from error
            raise
        if decision.status == 202:
            continue
        key = (decision.json() or {}).get("api_key")
        if decision.status == 200 and key:
            SecretStore.store(server, key)
            return
    raise ClientError("OctoPrint authorization timed out")


PREFERENCE_SETTINGS = {
    "cameraMode",
    "showProgress",
    "notifyFinished",
    "notifyPaused",
    "notifyError",
}
def _persist_settings(settings: dict[str, str]) -> None:
    try:
        for key, value in settings.items():
            subprocess.run(
                ["omarchy", "bar", "set", APP_ID, key, value],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
    except FileNotFoundError as error:
        raise ClientError("The Omarchy settings command is unavailable") from error
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ClientError("Could not save OctoPrint settings") from error


def set_setting(key: str, value: str) -> None:
    """Persist one validated preference for immediate UI updates."""
    if key not in PREFERENCE_SETTINGS:
        raise ClientError("Unsupported OctoPrint setting")
    if key == "cameraMode":
        if value not in {"stream", "snapshots", "off"}:
            raise ClientError("Choose Stream, Snapshots, or Off for the camera")
    elif value not in {"true", "false"}:
        raise ClientError("Choose true or false for this preference")
    _persist_settings({key: value})


def configure(
    server: str,
    snapshot_path: str | None = None,
    stream_path: str | None = None,
    values: dict[str, str] | None = None,
) -> str:
    """Persist validated, non-secret widget settings through Omarchy's CLI."""
    server = canonical_url(server)
    values = values or {}
    camera_paths = {
        "snapshotPath": snapshot_path.strip() if snapshot_path is not None else "",
        "streamPath": stream_path.strip() if stream_path is not None else "",
    }
    camera_paths = {key: value for key, value in camera_paths.items() if value}
    for camera_path in camera_paths.values():
        validate_camera_path(camera_path)
    if set(values) - PREFERENCE_SETTINGS:
        raise ClientError("Unsupported OctoPrint setting")
    for key, value in values.items():
        if key == "cameraMode" and value not in {"stream", "snapshots", "off"}:
            raise ClientError("Choose Stream, Snapshots, or Off for the camera")
        if key != "cameraMode" and value not in {"true", "false"}:
            raise ClientError("Choose true or false for this preference")

    settings = {
        **camera_paths,
        **values,
        "instanceUrl": server,
        "setupComplete": "true",
    }
    _persist_settings(settings)
    return server
