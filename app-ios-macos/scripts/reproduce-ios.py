#!/usr/bin/env python3
"""Build and exercise Homecast in a disposable iOS simulator, keeping evidence."""

import argparse
import functools
import http.server
import json
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import threading
from urllib.parse import urlsplit
import uuid


ROOT = Path(__file__).resolve().parents[1]


class AppHandler(http.server.SimpleHTTPRequestHandler):
    """Support the shell's /login entry and client-side routes in a built SPA."""

    def do_GET(self):
        route = urlsplit(self.path).path
        if not Path(self.translate_path(route)).exists() and not Path(route).suffix:
            self.path = "/index.html"
        super().do_GET()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def capture(*args):
    return run(*args, stdout=subprocess.PIPE).stdout.strip()


def choose_device(inventory, requested_os):
    runtimes = [r for r in inventory["runtimes"]
                if r.get("isAvailable") and ".iOS-" in r["identifier"]
                and (not requested_os or r["version"] == requested_os)]
    runtimes.sort(key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True)
    for runtime in runtimes:
        phones = [d for d in runtime.get("supportedDeviceTypes", [])
                  if d["name"].startswith("iPhone")]
        if phones:
            return runtime, phones[0]
    raise RuntimeError(f"No available iPhone simulator runtime for iOS {requested_os or '(any)'}. "
                       "Install the required runtime in Xcode; do not silently test a different OS.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory (must not exist)")
    parser.add_argument("--os", help="Exact installed iOS version; otherwise use the newest installed")
    parser.add_argument("--web-root", type=Path, default=ROOT / "UITests/Fixtures",
                        help="Local page or built web app served on an ephemeral localhost port")
    parser.add_argument("--only-testing", help="XCTest identifier, e.g. HomecastUITests/ReproductionTests/testIssue257")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("iOS execution needs macOS + Xcode. Push an ios-repro/* branch to use the hosted runner.")
    web_root = args.web_root.resolve()
    if not (web_root / "index.html").is_file():
        parser.error("--web-root must contain index.html")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    inventory = json.loads(capture("xcrun", "simctl", "list", "--json"))
    runtime, device = choose_device(inventory, args.os)
    handler = functools.partial(AppHandler, directory=str(web_root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    origin = f"http://localhost:{server.server_port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    simulator = None
    video = None
    bundle_dir = ROOT / "Resources/web-dist"
    created_bundle = not bundle_dir.exists()
    result = output / "results.xcresult"
    status = 1
    metadata = {
        "native_sha": capture("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "native_dirty": bool(capture("git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no")),
        "xcode": capture("xcodebuild", "-version"),
        "runtime": runtime["identifier"], "os": runtime["version"],
        "device": device["name"], "web_root": str(web_root), "web_origin": origin,
        "only_testing": args.only_testing,
        "scope": "Native app + local page; no real HomeKit/account verification",
    }
    try:
        simulator = capture("xcrun", "simctl", "create", f"Homecast Reproduction {uuid.uuid4().hex[:8]}",
                            device["identifier"], runtime["identifier"])
        metadata["simulator"] = simulator
        (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"Testing {device['name']} / iOS {runtime['version']}; evidence: {output}", flush=True)
        run("xcrun", "simctl", "boot", simulator)
        run("xcrun", "simctl", "bootstatus", simulator, "-b")
        run("xcrun", "simctl", "status_bar", simulator, "override", "--time", "9:41",
            "--batteryState", "charged", "--batteryLevel", "100")
        # The cloud-mode test loads localhost. A clean checkout still needs the
        # resource folder referenced by the app project; never replace an
        # existing Community bundle, and never bundle the test fixture itself.
        if created_bundle:
            bundle_dir.mkdir(parents=True)
        with (output / "recording.log").open("w") as video_log, (output / "xcodebuild.log").open("w") as build_log:
            command = ["xcodebuild", "build-for-testing", "-project", str(ROOT / "Homecast.xcodeproj"),
                       "-scheme", "Homecast-Reproduction", "-configuration", "Debug",
                       "-destination", f"platform=iOS Simulator,id={simulator}",
                       "-derivedDataPath", str(output / "DerivedData"),
                       "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]
            print("Building and running UI tests (see xcodebuild.log)…", flush=True)
            status = subprocess.run(command, stdout=build_log, stderr=subprocess.STDOUT).returncode
            if status == 0:
                test_runs = list((output / "DerivedData/Build/Products").glob("*.xctestrun"))
                if len(test_runs) != 1:
                    raise RuntimeError(f"Expected one test run file, found {len(test_runs)}")
                test_run = test_runs[0]
                settings = plistlib.loads(test_run.read_bytes())

                def set_environment(value):
                    if isinstance(value, dict):
                        if "TestBundlePath" in value:
                            value.setdefault("EnvironmentVariables", {})["HOMECAST_TEST_WEB_ORIGIN"] = origin
                        for child in value.values():
                            set_environment(child)
                    elif isinstance(value, list):
                        for child in value:
                            set_environment(child)

                set_environment(settings)
                test_run.write_bytes(plistlib.dumps(settings))
                video = subprocess.Popen(["xcrun", "simctl", "io", simulator, "recordVideo",
                                          str(output / "screen.mp4")], stdout=video_log, stderr=video_log)
                command = ["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
                           "-destination", f"platform=iOS Simulator,id={simulator}",
                           "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO"]
                if args.only_testing:
                    command.append(f"-only-testing:{args.only_testing}")
                status = 1
                status = subprocess.run(command, stdout=build_log, stderr=subprocess.STDOUT).returncode
        if result.exists():
            run("xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                "--output-path", str(output / "attachments"))
            summary = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)))
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            # xcodebuild can return success when an -only-testing filter matches
            # nothing. Zero executed tests must never count as verification.
            if summary.get("passedTests", 0) + summary.get("failedTests", 0) == 0:
                print("ERROR: no tests executed", file=sys.stderr)
                status = 1
        elif status == 0:
            status = 1
    except BaseException:
        status = 1
        raise
    finally:
        if video and video.poll() is None:
            video.send_signal(signal.SIGINT)
            try:
                video.wait(timeout=20)
            except subprocess.TimeoutExpired:
                video.kill()
                video.wait()
        if simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True)
        server.shutdown()
        server.server_close()
        if created_bundle and bundle_dir.exists():
            bundle_dir.rmdir()
        metadata["exit_code"] = status
        (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"UI test exit code: {status}; screenshots, video and results: {output}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
