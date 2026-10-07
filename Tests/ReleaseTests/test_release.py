import importlib.util
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("collect_notices", ROOT / "scripts/collect-notices.py")
NOTICES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTICES)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        for name in ["bundle-ghostty-resources.sh", "collect-notices.py", "package-release.sh", "setup-ghostty.sh", "ghostty-version.env"]:
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.env = dict(os.environ)
        for name in ["GHOSTTYKIT", "GHOSTTY_SRC", "GHOSTTY_RESOURCES", "GHOSTTY_NOTICES", "ZIG", "BUILD_NUMBER"]:
            self.env.pop(name, None)

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_script(self, name, *args):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / name), *args],
            env=self.env, text=True, capture_output=True,
        )

    def fake_tool(self, name, content):
        path = self.write(f"tools/{name}", "#!/bin/bash\n" + content + "\n")
        path.chmod(0o755)
        self.env["PATH"] = str(path.parent) + os.pathsep + self.env["PATH"]

    def bundle_fixture(self):
        for relative in [
            "terminfo/78/xterm-ghostty",
            "ghostty/themes/Example",
            "ghostty/shell-integration/zsh/ghostty-integration",
            "ghostty/shell-integration/zsh/.zshenv",
        ]:
            self.write(f"vendor/ghostty/resources/{relative}", "resource\n")
        self.write("vendor/ghostty/notices/Ghostty.txt", "Ghostty license\n")
        self.write("build/SourcePackages/checkouts/Yams/LICENSE", "Yams license\n")
        self.env["TARGET_BUILD_DIR"] = str(self.root / "products")
        self.env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = "Muxify.app/Contents/Resources"

    def package_fixture(self):
        pins = dict(
            line.split("=", 1) for line in (ROOT / "scripts/ghostty-version.env").read_text().splitlines()
            if line and not line.startswith("#")
        )
        self.write("vendor/ghostty/build-info.json", json.dumps({
            "commit": pins["GHOSTTY_COMMIT"], "zig": pins["GHOSTTY_ZIG_VERSION"], "arch": "arm64", "dirty": False,
        }))
        self.write("vendor/ghostty/notices/Ghostty.txt", "Upstream notices\n")
        app = "build/Build/Products/Release/Muxify.app"
        executable = self.write(f"{app}/Contents/MacOS/Muxify", "fixture\n")
        executable.chmod(0o755)
        for name in ["Ghostty", "Yams", "libyaml"]:
            self.write(f"{app}/Contents/Resources/ThirdPartyNotices/{name}.txt", "License\n")
        link = self.root / app / "Contents/Resources/notice-link"
        link.symlink_to("ThirdPartyNotices/Ghostty.txt")
        self.fake_tool("uname", "echo arm64")
        self.fake_tool("make", "exit 0")
        self.fake_tool("git", "echo abcdef123456")
        self.fake_tool("xcodebuild", 'if [ "$1" = -version ]; then echo "Xcode fixture"; else printf "%s\\n" "$@" > xcode-args.txt; fi')
        self.fake_tool("codesign", 'if [ "$1" = -dv ]; then echo "Signature=adhoc" >&2; fi')
        self.fake_tool("lipo", "echo arm64")

    def test_package_archives_app_and_checksum_without_installing(self):
        self.package_fixture()
        self.env["BUILD_NUMBER"] = "42"
        tag = "v1.2.3-beta.4"
        result = self.run_script("package-release.sh", tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        dist = self.root / "build/releases" / tag
        archive = dist / "Muxify-1.2.3-beta.4-arm64.zip"
        self.assertTrue(archive.is_file())
        subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=dist, check=True, capture_output=True)
        with zipfile.ZipFile(archive) as zipped:
            executable = zipped.getinfo("Muxify.app/Contents/MacOS/Muxify")
            self.assertTrue((executable.external_attr >> 16) & 0o111)
            link = zipped.getinfo("Muxify.app/Contents/Resources/notice-link")
            self.assertEqual((link.external_attr >> 16) & 0o170000, 0o120000)
        metadata = json.loads((dist / "build-info.json").read_text())
        self.assertEqual(metadata["tag"], tag)
        self.assertEqual(metadata["build"], "42")
        self.assertFalse(metadata["notarized"])
        args = (self.root / "xcode-args.txt").read_text()
        self.assertIn("MARKETING_VERSION=1.2.3\n", args)
        self.assertIn("CURRENT_PROJECT_VERSION=42\n", args)
        self.assertIn("not Developer ID signed or notarized", (dist / "RELEASE-NOTES.md").read_text())

    def test_package_stops_when_signature_verification_fails(self):
        self.package_fixture()
        self.fake_tool("codesign", "exit 1")
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any((self.root / "build/releases").rglob("*.zip")))

    def test_signature_check_consumes_all_codesign_output(self):
        self.package_fixture()
        self.fake_tool("codesign", 'if [ "$1" = -dv ]; then echo "Signature=adhoc" >&2; printf "%262144s\\n" diagnostics >&2; fi')
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_collects_notices_and_font_mapping_in_stable_order(self):
        self.write("source/LICENSE", "MIT license\n")
        self.write("source/nested/COPYING.txt", "BSD license\n")
        self.write("source/src/font/res/README.md", "Font attribution\n")
        self.write("source/src/font/res/BSD-2-Clause.txt", "Font license\n")
        self.write("source/.git/LICENSE", "Should not appear\n")
        self.write("source/.zig-cache/LICENSE", "Should not appear\n")
        self.write("source/README.md", "Not a license\n")
        text = NOTICES.collect([("Upstream", self.root / "source")])
        self.assertEqual(text, NOTICES.collect([("Upstream", self.root / "source")]))
        for expected in ["MIT license", "BSD license", "Font attribution", "Font license", "Upstream/nested/COPYING.txt"]:
            self.assertIn(expected, text)
        self.assertNotIn("Should not appear", text)
        self.assertNotIn("Not a license", text)
        self.assertNotIn(str(self.root), text)

    def test_notice_collector_rejects_missing_or_empty_sources(self):
        with self.assertRaises(ValueError):
            NOTICES.collect([("Upstream", self.root / "missing")])
        (self.root / "empty").mkdir()
        with self.assertRaises(ValueError):
            NOTICES.collect([("Upstream", self.root / "empty")])

    def test_collects_licenses_from_zig_016_package_archives(self):
        packages = self.root / "packages"
        packages.mkdir()
        with tarfile.open(packages / "package-hash.tar.gz", "w:gz") as archive:
            for name, text in [("LICENSE", "Archive license"), ("README.md", "Not a license"), ("../LICENSE", "Unsafe path")]:
                member = tarfile.TarInfo(name)
                content = text.encode()
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        text = NOTICES.collect([("Dependencies", packages)])
        self.assertIn("Dependencies/package-hash.tar.gz/LICENSE", text)
        self.assertIn("Archive license", text)
        self.assertNotIn("Not a license", text)
        self.assertNotIn("Unsafe path", text)
        self.assertFalse((packages / "LICENSE").exists())

    def test_bundle_requires_resources_instead_of_ghostty_app(self):
        self.env["TARGET_BUILD_DIR"] = str(self.root / "products")
        self.env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = "Muxify.app/Contents/Resources"
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ghostty resources missing", result.stderr)

    def test_bundle_copies_matching_resources_and_notices(self):
        self.bundle_fixture()
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = self.root / "products/Muxify.app/Contents/Resources"
        self.assertTrue((resources / "ghostty/shell-integration/zsh/.zshenv").is_file())
        self.assertEqual((resources / "ThirdPartyNotices/Ghostty.txt").read_text(), "Ghostty license\n")
        self.assertIn("Yams license", (resources / "ThirdPartyNotices/Yams.txt").read_text())

    def test_simulator_bundle_preserves_incorporated_code_and_dependency_licenses(self):
        shutil.copy(ROOT / "scripts/bundle-simulator-notices.sh", self.root / "scripts")
        notice = (ROOT / "Resources/ThirdPartyNotices/Simulator.txt").read_text()
        self.write("Resources/ThirdPartyNotices/Simulator.txt", notice)
        for package in ["swift-nio", "swift-atomics", "swift-collections", "swift-system"]:
            self.write(f".build/checkouts/{package}/LICENSE.txt", f"{package} license\n")
        self.write(".build/checkouts/swift-nio/NOTICE.txt", "NIO notice\n")
        self.write(".build/checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE", "llhttp license\n")
        destination = self.root / "products/ThirdPartyNotices"
        result = subprocess.run(
            ["/bin/sh", str(self.root / "scripts/bundle-simulator-notices.sh"), str(destination)],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "Simulator.txt").read_text(), notice)
        self.assertIn("Copyright (c) 2026 Samuel Abada", notice)
        self.assertIn("The above copyright notice and this permission notice shall be included", notice)
        self.assertEqual((destination / "swift-nio-LICENSE.txt").read_text(), "swift-nio license\n")
        self.assertEqual((destination / "llhttp-LICENSE.txt").read_text(), "llhttp license\n")

    def test_bundle_rejects_missing_themes_or_shell_integration(self):
        self.bundle_fixture()
        path = self.root / "vendor/ghostty/resources/ghostty/shell-integration/zsh/ghostty-integration"
        path.unlink()
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertNotEqual(result.returncode, 0)

    def test_package_rejects_invalid_or_stable_tags_before_building(self):
        for tag in ["", "v0.1.0", "v0.1.0-beta.0", "v01.1.0-beta.1", "v0.1.0-beta.1/other", "v0.1.0-beta.1;echo bad"]:
            with self.subTest(tag=tag):
                result = self.run_script("package-release.sh", tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Usage:", result.stderr)

    def test_package_rejects_invalid_build_number(self):
        self.env["BUILD_NUMBER"] = "0"
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BUILD_NUMBER", result.stderr)

    def test_package_rejects_non_arm64_host(self):
        self.fake_tool("uname", "echo x86_64")
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apple-silicon", result.stderr)

    def test_package_rejects_unpinned_development_build(self):
        self.fake_tool("uname", "echo arm64")
        self.fake_tool("make", "exit 0")
        self.write("vendor/ghostty/build-info.json", json.dumps({"commit": "unknown", "zig": "unknown", "arch": "arm64"}))
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Ghostty build", result.stderr)

    def test_package_rejects_modified_ghostty_source(self):
        self.package_fixture()
        metadata_path = self.root / "vendor/ghostty/build-info.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["dirty"] = True
        metadata_path.write_text(json.dumps(metadata))
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Ghostty build", result.stderr)

    def test_prebuilt_override_requires_matching_resources(self):
        self.env["GHOSTTYKIT"] = str(self.root / "GhosttyKit.xcframework")
        result = self.run_script("setup-ghostty.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GHOSTTY_RESOURCES", result.stderr)

    def test_setup_verifies_library_with_xcode_26_lipo_argument_order(self):
        framework = "GhosttyKit.xcframework/macos-arm64"
        self.write(f"{framework}/libghostty-internal.a", "Library fixture\n")
        self.write(f"{framework}/Headers/ghostty.h", "Header fixture\n")
        for relative in [
            "terminfo/78/xterm-ghostty",
            "ghostty/themes/Example",
            "ghostty/shell-integration/zsh/ghostty-integration",
        ]:
            self.write(f"resources/{relative}", "Resource fixture\n")
        self.write("upstream-notices.txt", "License fixture\n")
        self.env["GHOSTTYKIT"] = str(self.root / "GhosttyKit.xcframework")
        self.env["GHOSTTY_RESOURCES"] = str(self.root / "resources")
        self.env["GHOSTTY_NOTICES"] = str(self.root / "upstream-notices.txt")
        self.env["ARCH"] = "arm64"
        self.fake_tool("lipo", '''
if [ "$1" = -info ]; then
  echo "Non-fat file: $2 is architecture: arm64"
elif [ "$#" = 3 ] && [ "$2" = -verify_arch ] && [ "$3" = arm64 ]; then
  test -f "$1"
else
  echo "Input file must precede -verify_arch and its architecture arguments" >&2
  exit 1
fi
''')
        result = self.run_script("setup-ghostty.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "vendor/ghostty/include/ghostty.h").is_file())
        self.assertTrue((self.root / "vendor/ghostty/resources/terminfo/78/xterm-ghostty").is_file())
        self.assertTrue((self.root / "vendor/ghostty/build-info.json").is_file())

    def test_failed_ghostty_build_cannot_be_masked_by_command_substitution(self):
        source = self.root / "source"
        self.write("source/build.zig.zon", '.{ .minimum_zig_version = "0.16.0", }\n')
        self.fake_tool("zig", 'if [ "$1" = version ]; then echo 0.16.0; else exit 17; fi')
        self.fake_tool("xcrun", "exit 0")
        self.env["GHOSTTY_SRC"] = str(source)
        self.env["ZIG"] = str(self.root / "tools/zig")
        result = self.run_script("setup-ghostty.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "vendor/ghostty/build-info.json").exists())


if __name__ == "__main__":
    unittest.main()
