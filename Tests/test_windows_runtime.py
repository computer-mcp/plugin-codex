import importlib.util
import os
from pathlib import Path
import tempfile
import struct
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "windows_runtime", Path(__file__).resolve().parents[1] / "Scripts/windows_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class WindowsRuntimeTests(unittest.TestCase):
    def test_recursive_shared_and_cyclic_imports_preserve_all_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            libraries, system = root / "runtime", root / "system"
            libraries.mkdir()
            system.mkdir()
            executable = root / "adapter.exe"
            executable.write_bytes(b"adapter")
            for name in ("swiftCore.dll", "Foundation.dll"):
                (libraries / name).write_bytes(name.encode())
            (system / "KERNEL32.dll").write_bytes(b"os")
            (system / "VCRUNTIME140.dll").write_bytes(b"msvc")
            graph = {
                "adapter.exe": ["Foundation.dll", "swiftCore.dll"],
                "Foundation.dll": ["swiftCore.dll", "VCRUNTIME140.dll"],
                "swiftCore.dll": ["Foundation.dll", "KERNEL32.dll"],
                "VCRUNTIME140.dll": ["api-ms-win-crt-runtime-l1-1-0.dll"],
            }
            with patch.object(runtime, "imports", side_effect=lambda path, _: ("x86_64", graph[path.name])), \
                    patch.object(runtime, "file_version", return_value="14.44.35211.0"):
                report = runtime.audit(executable, [libraries], system, Path("inspector"))
            rows = {row["name"]: row for row in report["libraries"]}
            self.assertEqual(len(rows), 5)
            self.assertEqual(set(rows["swiftCore.dll"]["imported_by"]), {"adapter.exe", "Foundation.dll"})
            self.assertEqual(rows["VCRUNTIME140.dll"]["role"], "external-msvc-runtime")
            self.assertEqual(rows["KERNEL32.dll"]["role"], "windows-system")
            self.assertFalse(report["relocation_verified"])

    def test_microsoft_runtime_remains_external_when_found_in_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "VCRUNTIME140.dll"
            source.write_bytes(b"toolchain")
            self.assertEqual(runtime.resolve(source.name, [{source.name.lower(): source}], {}),
                             ("external-msvc-runtime", source))

    def test_prerequisites_reject_missing_old_wrong_architecture_and_bundled_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package, system = root / "package", root / "system"
            package.mkdir()
            system.mkdir()
            def pe(path, machine):
                header = bytearray(64)
                header[:2] = b"MZ"
                struct.pack_into("<I", header, 60, 64)
                path.write_bytes(header + b"PE\0\0" + struct.pack("<H", machine))
            executable = package / "adapter.exe"
            pe(executable, 0x8664)
            requirement = [{"name": "VCRUNTIME140.dll", "minimum_version": "14.44.35211.0"}]
            with self.assertRaisesRegex(ValueError, "missing vcruntime"):
                runtime.verify_prerequisites(executable, system, requirement)
            dll = system / "VCRUNTIME140.dll"
            pe(dll, 0xAA64)
            with self.assertRaisesRegex(ValueError, "architecture mismatch"):
                runtime.verify_prerequisites(executable, system, requirement)
            pe(dll, 0x8664)
            with patch.object(runtime, "file_version", return_value="14.43.35211.0"):
                with self.assertRaisesRegex(ValueError, "Update the official"):
                    runtime.verify_prerequisites(executable, system, requirement)
            with patch.object(runtime, "file_version", return_value="14.44.35211.1"):
                rows = runtime.verify_prerequisites(executable, system, requirement)
            self.assertEqual(rows[0]["sha256"], runtime.digest(dll))
            swift = package / "swiftCore.dll"
            swift.write_bytes(b"swift")
            observed = runtime.verify_app_local_modules([executable, swift, dll], executable, system, rows)
            self.assertEqual(observed[-1]["role"], "external-msvc-runtime")
            with self.assertRaisesRegex(ValueError, "unverified Microsoft"):
                runtime.verify_app_local_modules([swift, dll], executable, system)
            (package / dll.name).write_bytes(dll.read_bytes())
            with self.assertRaisesRegex(ValueError, "not bundled"):
                runtime.verify_prerequisites(executable, system, requirement)
            with self.assertRaisesRegex(ValueError, "not bundled"):
                runtime.verify_app_local_modules([swift, dll], executable, system, rows)

    @unittest.skipUnless(os.name == "nt", "Native version resource requires Windows")
    def test_native_version_resource_and_pe_architecture(self):
        path = Path(os.environ["SystemRoot"]) / "System32/kernel32.dll"
        self.assertIn(runtime.pe_architecture(path), {"x86_64", "aarch64"})
        self.assertEqual(len(runtime.version_tuple(runtime.file_version(path))), 4)

    def test_conflicting_runtime_versions_and_missing_imports_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = root / "first", root / "second"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            with self.assertRaisesRegex(ValueError, "Conflicting"):
                runtime.resolve("swiftCore.dll", [{"swiftcore.dll": first}, {"swiftcore.dll": second}], {})
            with self.assertRaisesRegex(ValueError, "Unresolved"):
                runtime.resolve("missing.dll", [], {})

    def test_case_collisions_and_linked_library_sources_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "outside"
            target.write_bytes(b"outside")
            link = root / "library.dll"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "link or special"):
                runtime.resolve("library.dll", [{"library.dll": link}], {})
            with patch.object(Path, "iterdir", return_value=iter([root / "A.dll", root / "a.dll"])):
                with self.assertRaisesRegex(ValueError, "Case-colliding"):
                    runtime.directory_files(root)

    def test_runtime_architecture_must_match_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            system = root / "system"
            system.mkdir()
            executable, library = root / "adapter.exe", root / "swiftCore.dll"
            executable.write_bytes(b"adapter")
            library.write_bytes(b"library")
            with patch.object(runtime, "imports", side_effect=[("x86_64", [library.name]), ("aarch64", [])]):
                with self.assertRaisesRegex(ValueError, "architecture mismatch"):
                    runtime.audit(executable, [root], system, Path("inspector"))

    def test_live_modules_must_use_packaged_libraries_and_only_system_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            local, toolchain, system = [root / name for name in ("package", "toolchain", "system")]
            for path in (local, toolchain, system):
                path.mkdir()
            executable, library = local / "adapter.exe", local / "swiftCore.dll"
            external, native = toolchain / "swiftCore.dll", system / "KERNEL32.dll"
            for path in (executable, library, external, native):
                path.write_bytes(path.name.encode())
            rows = runtime.verify_app_local_modules([executable, library, native], executable, system)
            self.assertEqual([row["role"] for row in rows], ["adapter", "app-local-runtime", "windows-system"])
            with self.assertRaisesRegex(ValueError, "outside the package"):
                runtime.verify_app_local_modules([executable, external], executable, system)
            unowned = toolchain / "unowned.dll"
            unowned.write_bytes(b"unowned")
            with self.assertRaisesRegex(ValueError, "undeclared external"):
                runtime.verify_app_local_modules([library, unowned], executable, system)
            with self.assertRaisesRegex(ValueError, "No app-local"):
                runtime.verify_app_local_modules([executable, native], executable, system)
