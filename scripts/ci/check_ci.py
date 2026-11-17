"""CI checks shared by offline fixtures and the macOS runner (stdlib only)."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.parsers.expat import ExpatError


DEVELOPER_DIR = Path("/Applications/Xcode_27.2.app/Contents/Developer")


class CheckError(ValueError):
    """A CI requirement was not met."""


def check_toolchain(developer_dir, xcode_version, swift_path, sdks, runtimes_json):
    """Validate captured metadata without invoking Apple tools (fixture friendly)."""
    developer_dir = Path(developer_dir)
    if not developer_dir.is_dir():
        raise CheckError("DEVELOPER_DIR must be an existing Xcode Developer directory")
    lines = xcode_version.strip().splitlines()
    if not lines or lines[0] != "Xcode 27.2":
        raise CheckError("Xcode version must be exactly 27.2")

    swift = Path(swift_path.strip())
    if not swift.is_absolute() or not swift.is_file():
        raise CheckError("swift must resolve to a file inside the selected Xcode")
    try:
        swift.resolve().relative_to(developer_dir.resolve())
    except ValueError as error:
        raise CheckError("swift must resolve inside the selected Xcode") from error

    sdk_names = set(re.findall(r"-sdk\s+(\S+)", sdks))
    for sdk in ("iphonesimulator27.2", "watchsimulator27.2"):
        if sdk not in sdk_names:
            raise CheckError(f"required simulator SDK missing: {sdk}")

    try:
        metadata = json.loads(runtimes_json)
    except (ValueError, TypeError) as error:
        raise CheckError("runtime metadata must be valid JSON") from error
    runtimes = metadata.get("runtimes") if isinstance(metadata, dict) else None
    if not isinstance(runtimes, list) or not all(isinstance(r, dict) for r in runtimes):
        raise CheckError("runtime metadata must contain a runtimes array of objects")
    for platform in ("iOS", "watchOS"):
        identifier = f"com.apple.CoreSimulator.SimRuntime.{platform}-27-2"
        matches = [runtime for runtime in runtimes if runtime.get("identifier") == identifier]
        if (len(matches) != 1 or matches[0].get("version") != "27.2"
                or matches[0].get("isAvailable") is not True):
            raise CheckError(f"required available runtime missing or invalid: {platform} 27.2")
    return [
        f"PASS DEVELOPER_DIR={developer_dir}",
        "PASS Xcode=27.2",
        f"PASS swift={swift}",
        "PASS simulator SDKs=iphonesimulator27.2, watchsimulator27.2",
        "PASS available runtimes=iOS 27.2, watchOS 27.2",
    ]


def read_info(app):
    path = app / "Info.plist"
    try:
        with path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, ExpatError, plistlib.InvalidFileException) as error:
        raise CheckError(f"{app.name}/Info.plist must exist and be a valid plist") from error
    if not isinstance(info, dict):
        raise CheckError(f"{app.name}/Info.plist must contain a dictionary")
    return info


def require_value(info, key, expected, label):
    # bool is a subclass of int: equality alone would accept 0/1 as false/true.
    if key not in info or type(info[key]) is not type(expected) or info[key] != expected:
        raise CheckError(f"{label}: {key} must be {expected!r} ({type(expected).__name__})")
    return f"PASS {label} {key}={info[key]!r}"


def bundle_identifier(info, label):
    identifier = info.get("CFBundleIdentifier")
    if (not isinstance(identifier, str)
            or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier)):
        raise CheckError(f"{label}: CFBundleIdentifier must be a resolved bundle identifier")
    return identifier


def check_app(app, info, platform, label):
    identifier = bundle_identifier(info, label)
    results = [f"PASS {label} CFBundleIdentifier={identifier!r}"]
    for key, expected in (("CFBundlePackageType", "APPL"),
                          ("CFBundleSupportedPlatforms", [platform]),
                          ("MinimumOSVersion", "26.0")):
        results.append(require_value(info, key, expected, label))
    name = info.get("CFBundleExecutable")
    if (not isinstance(name, str) or not name or name in (".", "..")
            or Path(name).name != name):
        raise CheckError(f"{label}: CFBundleExecutable must name an executable inside the app")
    executable = app / name
    if not executable.is_file() or executable.stat().st_size == 0:
        raise CheckError(f"{label}: CFBundleExecutable must exist and be nonempty")
    try:
        executable.resolve().relative_to(app.resolve())
    except ValueError as error:
        raise CheckError(f"{label}: CFBundleExecutable must resolve inside the app") from error
    results.append(f"PASS {label} CFBundleExecutable={name!r} (file present, nonempty)")
    return identifier, results


def check_embedded_app(derived_data):
    """Inspect only the iOS build's exact Debug product, never the watch-only build."""
    products = Path(derived_data) / "Build/Products/Debug-iphonesimulator"
    host = products / "GrokBotWatch.app"
    hosts = list(products.glob("*.app"))
    if len(hosts) != 1 or hosts[0] != host or not host.is_dir() or host.is_symlink():
        raise CheckError("expected exactly one host app: Debug-iphonesimulator/GrokBotWatch.app")
    watch_directory = host / "Watch"
    watches = list(watch_directory.glob("*.app"))
    if (not watch_directory.is_dir() or watch_directory.is_symlink() or len(watches) != 1
            or not watches[0].is_dir() or watches[0].is_symlink()):
        raise CheckError("host Watch/ must contain exactly one embedded Watch *.app directory")
    watch = watches[0]
    host_info = read_info(host)
    watch_info = read_info(watch)
    host_id, host_checks = check_app(host, host_info, "iPhoneSimulator", "host")
    watch_id, watch_checks = check_app(watch, watch_info, "WatchSimulator", "Watch")
    if watch_id != f"{host_id}.watchkitapp":
        raise CheckError("Watch: CFBundleIdentifier must equal host CFBundleIdentifier + .watchkitapp")
    results = [f"PASS host product={host}", f"PASS embedded Watch product={watch}"]
    results.extend(host_checks + watch_checks)
    for key, expected in (("WKCompanionAppBundleIdentifier", host_id),
                          ("WKRunsIndependentlyOfCompanionApp", False),
                          ("WKApplication", True)):
        results.append(require_value(watch_info, key, expected, "Watch"))
    return results


def run_metadata(command):
    """Capture only explicitly requested tool metadata, with a bounded wait."""
    print("$ " + " ".join(command), flush=True)
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=60)
    except subprocess.CalledProcessError as error:
        raise CheckError(f"metadata command {command[0]} exited {error.returncode}") from error
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CheckError(f"metadata command {command[0]} unavailable or timed out") from error
    print(result.stdout.rstrip(), flush=True)
    return result.stdout


def preflight():
    # Read only this public toolchain selector, never dump the environment.
    if os.environ.get("DEVELOPER_DIR") != str(DEVELOPER_DIR):
        raise CheckError(f"DEVELOPER_DIR must be explicitly set to {DEVELOPER_DIR}")
    if not DEVELOPER_DIR.is_dir():
        raise CheckError(f"DEVELOPER_DIR missing: {DEVELOPER_DIR}")
    print(f"Python {sys.version.split()[0]}: {sys.executable}", flush=True)
    version = run_metadata(["xcodebuild", "-version"])
    swift = run_metadata(["xcrun", "--find", "swift"]).strip()
    sdks = run_metadata(["xcodebuild", "-showsdks"])
    runtimes = run_metadata(["xcrun", "simctl", "list", "runtimes", "--json"])
    results = check_toolchain(DEVELOPER_DIR, version, swift, sdks, runtimes)
    # Run the verified executable; do not pick up a different Swift from PATH.
    run_metadata([swift, "--version"])
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight", help="require Xcode 27.2, simulator SDKs and available runtimes")
    embedded = commands.add_parser("embedded-app", help="validate the iOS build's embedded Watch app")
    embedded.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    try:
        results = preflight() if args.command == "preflight" else check_embedded_app(args.derived_data)
    except (CheckError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("\n".join(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
