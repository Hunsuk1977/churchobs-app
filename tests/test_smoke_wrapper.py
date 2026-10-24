"""A successful recording stage must not hide a crashing process."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parent.parent

class SmokeWrapperTests(unittest.TestCase):
    def run_wrapper(self,exit_code,ui_exit_code=None):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copy2(ROOT/'Run-Engine-Test.command',root/'Run-Engine-Test.command')
            (root/'scripts').mkdir()
            (root/'scripts/Check-Bundle.command').write_text('#!/bin/bash\nexit 0\n')
            binary=root/'dist/ChurchOBS.app/Contents/MacOS/ChurchOBS'
            binary.parent.mkdir(parents=True)
            binary.write_text(f'#!/bin/bash\nif [[ "$1" == --ui-smoke-test ]]; then exit {exit_code if ui_exit_code is None else ui_exit_code}; fi\necho "Recording stage: stopped=1 nonempty=1"\nexit {exit_code}\n')
            binary.chmod(0o755)
            return subprocess.run(['bash',str(root/'Run-Engine-Test.command')],text=True,capture_output=True)

    def test_nonzero_process_exit_is_not_pass(self):
        result=self.run_wrapper(139)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Recording stage:',result.stdout)
        self.assertNotIn('PASS engine smoke test',result.stdout)

    def test_ui_crash_after_engine_pass_is_not_success(self):
        result=self.run_wrapper(0,139)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('PASS engine smoke test:',result.stdout)
        self.assertNotIn('PASS native UI smoke test:',result.stdout)

    def test_pass_only_after_zero_exit(self):
        result=self.run_wrapper(0)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PASS engine smoke test: process exited normally',result.stdout)
        self.assertLess(result.stdout.index('Recording stage:'),result.stdout.index('PASS engine smoke test'))

if __name__=='__main__': unittest.main(verbosity=2)
