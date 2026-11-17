"""Synthetic fixtures only; no Xcode, simulator, device, or network access."""

import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch

from check_ci import CheckError, check_embedded_app, check_toolchain, preflight, run_metadata


class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ci toolchain ")
        self.addCleanup(self.temp.cleanup)
        self.developer = Path(self.temp.name) / "Xcode_27.2.app/Contents/Developer"
        self.swift = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        self.swift.parent.mkdir(parents=True)
        self.swift.write_bytes(b"fixture executable")
        self.runtimes = {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                 "version": "27.2", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-2",
                 "version": "27.2", "isAvailable": True},
            ]
        }
        self.metadata = {
            "developer_dir": self.developer,
            "xcode_version": "Xcode 27.2\nBuild version 18C100\n",
            "swift_path": str(self.swift),
            "sdks": ("iOS Simulator SDKs:\n\tiOS 27.2 -sdk iphonesimulator27.2\n"
                     "watchOS Simulator SDKs:\n\twatchOS 27.2 -sdk watchsimulator27.2\n"),
            "runtimes_json": json.dumps(self.runtimes),
        }

    def check(self, **changes):
        return check_toolchain(**(self.metadata | changes))

    def test_valid_toolchain_with_spaces(self):
        self.check()

    def test_xcode_version_must_be_exact(self):
        for version in ("27.1", "27.20", "27.2.1", "27.2 beta", "26.6"):
            with self.subTest(version=version), self.assertRaisesRegex(CheckError, "Xcode"):
                self.check(xcode_version=f"Xcode {version}\nBuild version 18C100\n")

    def test_missing_developer_directory(self):
        with self.assertRaisesRegex(CheckError, "DEVELOPER_DIR"):
            self.check(developer_dir=self.developer / "missing")

    def test_swift_must_exist_inside_selected_xcode(self):
        outside = Path(self.temp.name) / "other swift"
        outside.write_bytes(b"other")
        for path in (outside, self.swift.with_name("missing"), self.swift.parent):
            with self.subTest(path=path), self.assertRaisesRegex(CheckError, "swift"):
                self.check(swift_path=str(path))

    def test_swift_symlink_outside_xcode(self):
        outside = Path(self.temp.name) / "other swift"
        outside.write_bytes(b"other")
        self.swift.unlink()
        self.swift.symlink_to(outside)
        with self.assertRaisesRegex(CheckError, "swift"):
            self.check()

    def test_each_simulator_sdk_required_exactly(self):
        for sdk in ("iphonesimulator", "watchsimulator"):
            for replacement in ("27.1", "27.20", "27.2.1"):
                with self.subTest(sdk=sdk, replacement=replacement):
                    with self.assertRaisesRegex(CheckError, "SDK"):
                        self.check(sdks=self.metadata["sdks"].replace(
                            f"-sdk {sdk}27.2", f"-sdk {sdk}{replacement}"))

    def test_device_sdks_cannot_replace_simulator_sdks(self):
        with self.assertRaisesRegex(CheckError, "SDK"):
            self.check(sdks="iOS 27.2 -sdk iphoneos27.2\nwatchOS 27.2 -sdk watchos27.2\n")

    def test_each_runtime_required(self):
        for index in (0, 1):
            runtimes = copy.deepcopy(self.runtimes)
            del runtimes["runtimes"][index]
            with self.subTest(index=index), self.assertRaisesRegex(CheckError, "runtime"):
                self.check(runtimes_json=json.dumps(runtimes))

    def test_runtime_version_identifier_and_availability(self):
        for index in (0, 1):
            for key, value in (("version", "27.20"), ("version", "27.1"),
                               ("identifier", "com.apple.CoreSimulator.SimRuntime.tvOS-27-2"),
                               ("isAvailable", False), ("isAvailable", "true"),
                               ("isAvailable", 1), ("isAvailable", None)):
                runtimes = copy.deepcopy(self.runtimes)
                runtimes["runtimes"][index][key] = value
                with self.subTest(index=index, key=key, value=value):
                    with self.assertRaisesRegex(CheckError, "runtime"):
                        self.check(runtimes_json=json.dumps(runtimes))

    def test_malformed_runtime_metadata(self):
        for data in ("not json", "[]", "{}", '{"runtimes": null}',
                     '{"runtimes": [null]}'):
            with self.subTest(data=data), self.assertRaisesRegex(CheckError, "runtime"):
                self.check(runtimes_json=data)

    def test_preflight_uses_verified_swift_and_exact_commands(self):
        output = [self.metadata["xcode_version"], str(self.swift), self.metadata["sdks"],
                  self.metadata["runtimes_json"], "Apple Swift version (fixture only)"]
        with (patch("check_ci.DEVELOPER_DIR", self.developer),
              patch("check_ci.os.environ.get", return_value=str(self.developer)),
              patch("check_ci.run_metadata", side_effect=output) as run,
              redirect_stdout(io.StringIO())):
            preflight()
        self.assertEqual(run.call_args_list, [
            call(["xcodebuild", "-version"]),
            call(["xcrun", "--find", "swift"]),
            call(["xcodebuild", "-showsdks"]),
            call(["xcrun", "simctl", "list", "runtimes", "--json"]),
            call([str(self.swift), "--version"]),
        ])

    def test_preflight_rejects_wrong_selector_before_any_commands(self):
        with (patch("check_ci.os.environ.get", return_value="/wrong/Xcode"),
              patch("check_ci.run_metadata") as run):
            with self.assertRaisesRegex(CheckError, "DEVELOPER_DIR"):
                preflight()
            run.assert_not_called()

    def test_metadata_command_failure_and_timeout_fail_closed(self):
        for error in (subprocess.CalledProcessError(9, ["fixture-tool"]),
                      subprocess.TimeoutExpired(["fixture-tool"], 60), FileNotFoundError()):
            with self.subTest(error=type(error).__name__):
                with (patch("check_ci.subprocess.run", side_effect=error),
                      redirect_stdout(io.StringIO()), self.assertRaises(CheckError)):
                    run_metadata(["fixture-tool"])


class EmbeddedAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ci products ")
        self.addCleanup(self.temp.cleanup)
        self.derived = Path(self.temp.name) / "Derived Data"
        self.products = self.derived / "Build/Products/Debug-iphonesimulator"
        self.host = self.products / "GrokBotWatch.app"
        self.watch = self.host / "Watch/GrokBotWatch Watch.app"
        # A different prefix proves the companion relationship is not hardcoded.
        self.host_info = {
            "CFBundleIdentifier": "org.example.fixture.grokbotwatch",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "GrokBotWatch",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            "MinimumOSVersion": "26.0",
        }
        self.watch_info = {
            "CFBundleIdentifier": self.host_info["CFBundleIdentifier"] + ".watchkitapp",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "GrokBotWatch Watch",
            "CFBundleSupportedPlatforms": ["WatchSimulator"],
            "MinimumOSVersion": "26.0",
            "WKCompanionAppBundleIdentifier": self.host_info["CFBundleIdentifier"],
            "WKRunsIndependentlyOfCompanionApp": False,
            "WKApplication": True,
        }
        self.write_info(self.host, self.host_info)
        self.write_info(self.watch, self.watch_info)
        (self.host / self.host_info["CFBundleExecutable"]).write_bytes(b"host fixture")
        (self.watch / self.watch_info["CFBundleExecutable"]).write_bytes(b"watch fixture")

    def write_info(self, app, info, fmt=plistlib.FMT_XML):
        app.mkdir(parents=True, exist_ok=True)
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, fmt=fmt)

    def test_valid_xml_and_binary_products_with_spaces(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                self.write_info(self.host, self.host_info, fmt)
                self.write_info(self.watch, self.watch_info, fmt)
                check_embedded_app(self.derived)

    def test_missing_host(self):
        shutil.rmtree(self.host)
        with self.assertRaisesRegex(CheckError, "host"):
            check_embedded_app(self.derived)

    def test_multiple_host_apps(self):
        (self.products / "Extra.app").mkdir()
        with self.assertRaisesRegex(CheckError, "host"):
            check_embedded_app(self.derived)

    def test_missing_watch_directory(self):
        shutil.rmtree(self.host / "Watch")
        with self.assertRaisesRegex(CheckError, "Watch"):
            check_embedded_app(self.derived)

    def test_empty_watch_directory(self):
        shutil.rmtree(self.watch)
        with self.assertRaisesRegex(CheckError, "Watch"):
            check_embedded_app(self.derived)

    def test_multiple_watch_apps(self):
        (self.watch.parent / "Extra Watch.app").mkdir()
        with self.assertRaisesRegex(CheckError, "Watch"):
            check_embedded_app(self.derived)

    def test_file_is_not_watch_app(self):
        shutil.rmtree(self.watch)
        self.watch.write_bytes(b"not an app directory")
        with self.assertRaisesRegex(CheckError, "Watch"):
            check_embedded_app(self.derived)

    def test_companion_id_missing_mismatched_or_wrong_type(self):
        for value in (None, "org.example.wrong", False, 123):
            info = self.watch_info.copy()
            info.pop("WKCompanionAppBundleIdentifier")
            if value is not None:
                info["WKCompanionAppBundleIdentifier"] = value
            self.write_info(self.watch, info)
            with self.subTest(value=value), self.assertRaisesRegex(CheckError, "WKCompanion"):
                check_embedded_app(self.derived)

    def test_independent_requires_present_boolean_false(self):
        for value in (None, True, "false", "true", 0, 1):
            info = self.watch_info.copy()
            info.pop("WKRunsIndependentlyOfCompanionApp")
            if value is not None:
                info["WKRunsIndependentlyOfCompanionApp"] = value
            self.write_info(self.watch, info)
            with self.subTest(value=value), self.assertRaisesRegex(CheckError, "WKRunsIndependently"):
                check_embedded_app(self.derived)

    def test_wkapplication_requires_present_boolean_true(self):
        for value in (None, False, "true", 1, 0):
            info = self.watch_info.copy()
            info.pop("WKApplication")
            if value is not None:
                info["WKApplication"] = value
            self.write_info(self.watch, info)
            with self.subTest(value=value), self.assertRaisesRegex(CheckError, "WKApplication"):
                check_embedded_app(self.derived)

    def test_each_minimum_version_requires_exact_string(self):
        for app, original in ((self.host, self.host_info), (self.watch, self.watch_info)):
            for value in (None, "25.0", "26.0.0", 26.0):
                info = original.copy()
                info.pop("MinimumOSVersion")
                if value is not None:
                    info["MinimumOSVersion"] = value
                self.write_info(app, info)
                with self.subTest(app=app.name, value=value):
                    with self.assertRaisesRegex(CheckError, "MinimumOSVersion"):
                        check_embedded_app(self.derived)
            self.write_info(app, original)

    def test_bundle_identifiers_must_be_present_resolved_strings(self):
        for app, original in ((self.host, self.host_info), (self.watch, self.watch_info)):
            for value in (None, "", 123, "$(BUNDLE_ID_PREFIX).grokbotwatch"):
                info = original.copy()
                info.pop("CFBundleIdentifier")
                if value is not None:
                    info["CFBundleIdentifier"] = value
                self.write_info(app, info)
                with self.subTest(app=app.name, value=value):
                    with self.assertRaisesRegex(CheckError, "CFBundleIdentifier"):
                        check_embedded_app(self.derived)
            self.write_info(app, original)

    def test_watch_identifier_matches_project_relationship(self):
        info = self.watch_info | {"CFBundleIdentifier": "org.example.unrelated"}
        self.write_info(self.watch, info)
        with self.assertRaisesRegex(CheckError, "CFBundleIdentifier"):
            check_embedded_app(self.derived)

    def test_plists_required_and_parseable(self):
        for app, original in ((self.host, self.host_info), (self.watch, self.watch_info)):
            for contents in (None, b"not a plist", plistlib.dumps(["not a dictionary"])):
                (app / "Info.plist").unlink()
                if contents is not None:
                    (app / "Info.plist").write_bytes(contents)
                with self.subTest(app=app.name, contents=contents):
                    with self.assertRaisesRegex(CheckError, "Info.plist"):
                        check_embedded_app(self.derived)
                self.write_info(app, original)

    def test_package_type_and_simulator_platform(self):
        for app, original in ((self.host, self.host_info), (self.watch, self.watch_info)):
            for key, value in (("CFBundlePackageType", "BNDL"),
                               ("CFBundleSupportedPlatforms", ["iPhoneOS"]),
                               ("CFBundleSupportedPlatforms", "WatchSimulator")):
                self.write_info(app, original | {key: value})
                with self.subTest(app=app.name, key=key):
                    with self.assertRaisesRegex(CheckError, key):
                        check_embedded_app(self.derived)
            self.write_info(app, original)

    def test_app_executable_required(self):
        for app, original in ((self.host, self.host_info), (self.watch, self.watch_info)):
            executable = app / original["CFBundleExecutable"]
            executable.unlink()
            with self.subTest(app=app.name), self.assertRaisesRegex(CheckError, "CFBundleExecutable"):
                check_embedded_app(self.derived)
            executable.write_bytes(b"fixture")

    def test_symlinks_cannot_replace_embedded_content(self):
        for label in ("host", "Watch directory", "Watch app"):
            with self.subTest(label=label):
                path = {"host": self.host, "Watch directory": self.watch.parent,
                        "Watch app": self.watch}[label]
                outside = Path(self.temp.name) / "outside content"
                path.rename(outside)
                path.symlink_to(outside, target_is_directory=True)
                try:
                    with self.assertRaises(CheckError):
                        check_embedded_app(self.derived)
                finally:
                    path.unlink()
                    outside.rename(path)

    def test_executable_cannot_resolve_outside_app(self):
        executable = self.watch / self.watch_info["CFBundleExecutable"]
        outside = Path(self.temp.name) / "outside executable"
        executable.rename(outside)
        executable.symlink_to(outside)
        with self.assertRaisesRegex(CheckError, "CFBundleExecutable"):
            check_embedded_app(self.derived)

    def test_cli_exit_codes_and_space_in_path(self):
        script = Path(__file__).with_name("check_ci.py")
        command = [sys.executable, "-B", str(script), "embedded-app", "--derived-data", str(self.derived)]
        valid = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn("PASS", valid.stdout)
        shutil.rmtree(self.watch)
        invalid = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(invalid.returncode, 1, invalid.stderr)
        self.assertIn("FAIL", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
