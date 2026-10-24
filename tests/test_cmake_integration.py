"""Regression for CMake's prohibition on add_subdirectory during DEFER."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('prepare_obs', ROOT / 'scripts/prepare_obs.py')
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

class FrontendIntegrationTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        obs = root / 'vendor/obs-studio'
        obs.mkdir(parents=True)
        (root / 'app').mkdir()
        original = b'cmake_minimum_required(VERSION 3.28)\nproject(obs-studio NONE)\nadd_library(upstream-core INTERFACE)\n'
        (obs / 'CMakeLists.txt').write_bytes(original)
        (root / 'source-manifest.json').write_text(json.dumps({'sha256': {'CMakeLists.txt': hashlib.sha256(original).hexdigest()}}))
        (root / 'app/CMakeLists.txt').write_text('if(NOT TARGET upstream-core)\n message(FATAL_ERROR "core not ready")\nendif()\nadd_custom_target(churchobs)\n')
        return root, obs, original

    def test_new_hook_configures_after_core(self):
        with tempfile.TemporaryDirectory() as directory:
            root, obs, original = self.fixture(directory)
            self.assertTrue(patch.prepare(root))
            self.assertFalse(patch.prepare(root))
            self.assertEqual(patch.original_source((obs/'CMakeLists.txt').read_bytes()), original)
            result = subprocess.run(['cmake','-S',str(obs),'-B',str(root/'build'),'-DWORSHIP_SOURCE_DIR='+str(root),'-DCMAKE_PROJECT_obs-studio_INCLUDE='+str(ROOT/'cmake/InjectFrontend.cmake')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            built = subprocess.run(['cmake','--build',str(root/'build'),'--target','churchobs'],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stdout+built.stderr)

    def test_old_deferred_hook_reproduces_reported_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root, obs, _ = self.fixture(directory)
            old = root/'old.cmake'
            old.write_text('function(worship_add_frontend)\n add_subdirectory("${WORSHIP_SOURCE_DIR}/app" "${CMAKE_BINARY_DIR}/worship")\nendfunction()\ncmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL worship_add_frontend)\n')
            result = subprocess.run(['cmake','-S',str(obs),'-B',str(root/'build'),'-DWORSHIP_SOURCE_DIR='+str(root),'-DCMAKE_PROJECT_obs-studio_INCLUDE='+str(old)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Subdirectories may not be created during deferred execution', result.stdout+result.stderr)

    def test_preserves_local_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root, obs, _ = self.fixture(directory)
            path = obs/'CMakeLists.txt'
            path.write_bytes(path.read_bytes()+b'\n# user change\n')
            before=path.read_bytes()
            with self.assertRaises(ValueError): patch.prepare(root)
            self.assertEqual(path.read_bytes(),before)

    def test_rejects_unknown_integration_block(self):
        with tempfile.TemporaryDirectory() as directory:
            root, obs, _ = self.fixture(directory)
            path=obs/'CMakeLists.txt'
            path.write_bytes(path.read_bytes()+b'\n# WORSHIP_FRONTEND_BEGIN\n# unknown\n')
            with self.assertRaises(ValueError): patch.prepare(root)

class CaptureCompatibilityTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        hashes = {}
        for name in patch.CAPTURE_PATCHES:
            original = patch.upstream_source(name, (ROOT/'vendor/obs-studio'/name).read_bytes())
            path = root/'vendor/obs-studio'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(original)
            hashes[name] = hashlib.sha256(original).hexdigest()
        (root/'source-manifest.json').write_text(json.dumps({'sha256': hashes}))
        return root

    def test_actual_capture_sources_are_patched_once_and_reversible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.fixture(tmp)
            before = {n: (root/'vendor/obs-studio'/n).read_bytes() for n in patch.CAPTURE_PATCHES}
            self.assertTrue(patch.prepare_capture(root))
            self.assertFalse(patch.prepare_capture(root))
            for name, (_, new, count) in patch.CAPTURE_PATCHES.items():
                data = (root/'vendor/obs-studio'/name).read_bytes()
                self.assertEqual(data.count(new), count)
                self.assertEqual(patch.upstream_source(name, data), before[name])
                if 'mac-avcapture' in name:
                    self.assertNotIn(patch.EXTERNAL_OLD, data)

    def test_local_edit_aborts_before_any_capture_file_is_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.fixture(tmp)
            last = list(patch.CAPTURE_PATCHES)[-1]
            path = root/'vendor/obs-studio'/last
            path.write_bytes(path.read_bytes()+b'\n// local edit\n')
            before = {n: (root/'vendor/obs-studio'/n).read_bytes() for n in patch.CAPTURE_PATCHES}
            with self.assertRaises(ValueError): patch.prepare_capture(root)
            for name, data in before.items():
                self.assertEqual((root/'vendor/obs-studio'/name).read_bytes(), data)

    def test_wrong_api_count_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.fixture(tmp)
            name = list(patch.CAPTURE_PATCHES)[0]
            path = root/'vendor/obs-studio'/name
            path.write_bytes(path.read_bytes().replace(patch.EXTERNAL_OLD, b'UnexpectedAPI', 1))
            manifest = json.loads((root/'source-manifest.json').read_text())
            manifest['sha256'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
            (root/'source-manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'occurrence count'): patch.prepare_capture(root)

if __name__ == '__main__':
    if not shutil.which('cmake'): raise SystemExit('CMake 3.28+ is required')
    unittest.main(verbosity=2)
