"""Dependency graph tests with simulated Mach-O metadata, not a Mac dyld test."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('runtime_deps', ROOT/'scripts/fix_runtime_deps.py')
module=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=module
spec.loader.exec_module(module)

def image(path):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(bytes.fromhex('cffaedfe')+b'fake-MachO-for-graph-test')
    return path

class DependencyTests(unittest.TestCase):
    def test_parse_ignores_dylib_id_and_handles_spaces_and_weak(self):
        info=module.parse_load_commands('''Load command 0
 cmd LC_ID_DYLIB
 name @rpath/libSelf.dylib (offset 24)
Load command 1
 cmd LC_LOAD_DYLIB
 name @rpath/a folder/libb.dylib (offset 24)
Load command 2
 cmd LC_LOAD_WEAK_DYLIB
 name /usr/lib/libSystem.B.dylib (offset 24)
Load command 3
 cmd LC_RPATH
 path @executable_path/../Frameworks (offset 12)
''')
        self.assertEqual([d.name for d in info.dependencies],['@rpath/a folder/libb.dylib','/usr/lib/libSystem.B.dylib'])
        self.assertTrue(info.dependencies[1].weak)
        self.assertEqual(info.rpaths,['@executable_path/../Frameworks'])

    def test_repairs_transitive_avformat_crypto_chain(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'ChurchOBS.app'; libs=Path(temp)/'obs-deps/lib'
            image(app/'Contents/MacOS/ChurchOBS')
            image(app/'Contents/Frameworks/libavformat.dylib')
            image(libs/'libmbedcrypto.dylib'); image(libs/'libnested.dylib')
            deps={'ChurchOBS':['@rpath/libavformat.dylib'],'libavformat.dylib':['@rpath/libmbedcrypto.dylib'],'libmbedcrypto.dylib':['@rpath/libnested.dylib'],'libnested.dylib':['/usr/lib/libSystem.B.dylib']}
            def metadata(path): return module.ImageInfo([module.Dependency(d) for d in deps[path.name]],['@executable_path/../Frameworks'])
            with patch.object(module,'read_image',side_effect=metadata),patch.object(module,'run_tool',return_value=''):
                with self.assertRaisesRegex(RuntimeError,'libmbedcrypto'):
                    module.DependencyClosure(app,libs).close()
                fixed=module.DependencyClosure(app,libs,True)
                self.assertEqual(fixed.close(),4)
                self.assertEqual(fixed.copied,['libmbedcrypto.dylib','libnested.dylib'])
                self.assertEqual(module.DependencyClosure(app,libs).close(),4)
                self.assertEqual(module.DependencyClosure(app,libs,True).close(),4)

    def test_missing_strong_dependency_fails_without_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'app'; libs=Path(temp)/'deps'
            image(app/'Contents/MacOS/main')
            with patch.object(module,'read_image',return_value=module.ImageInfo([module.Dependency('@rpath/libmissing.dylib')],['@executable_path/../Frameworks'])):
                with self.assertRaisesRegex(RuntimeError,'not found'):
                    module.DependencyClosure(app,libs,True).close()

    def test_weak_dependency_can_be_absent(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'app'; image(app/'Contents/MacOS/main')
            with patch.object(module,'read_image',return_value=module.ImageInfo([module.Dependency('@rpath/liboptional.dylib',True)],['@executable_path/../Frameworks'])):
                self.assertEqual(module.DependencyClosure(app,Path(temp)/'deps').close(),1)

    def test_dependency_symlink_must_stay_in_pinned_root(self):
        with tempfile.TemporaryDirectory() as temp:
            libs=Path(temp)/'deps'; libs.mkdir()
            external=image(Path(temp)/'outside.dylib')
            (libs/'libbad.dylib').symlink_to(external)
            with self.assertRaisesRegex(RuntimeError,'escapes'):
                module.DependencyClosure(Path(temp)/'app',libs,True).source_for('@rpath/libbad.dylib')

    def test_loader_relative_dependency_is_resolved(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'app'
            loader=image(app/'Contents/MacOS/main'); target=image(app/'Contents/Frameworks/liba.dylib')
            closure=module.DependencyClosure(app,Path(temp)/'deps')
            self.assertEqual(closure.existing('@loader_path/../Frameworks/liba.dylib',loader,module.ImageInfo([],[])),target.resolve())

    def test_absolute_reference_to_embedded_library_is_rewritten(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'app'; image(app/'Contents/MacOS/main'); image(app/'Contents/Frameworks/liba.dylib')
            metadata={ 'main':module.ImageInfo([module.Dependency('/builder/lib/liba.dylib')],[]), 'liba.dylib':module.ImageInfo([],[]) }
            with patch.object(module,'read_image',side_effect=lambda p:metadata[p.name]),patch.object(module,'run_tool',return_value=''):
                with self.assertRaisesRegex(RuntimeError,'nonportable'):
                    module.DependencyClosure(app,Path(temp)/'deps').close()
                fixed=module.DependencyClosure(app,Path(temp)/'deps',True)
                self.assertEqual(fixed.close(),2)
                self.assertEqual(fixed.rewrites[0][2],'@rpath/liba.dylib')

    def test_helper_executable_requires_bundle_rpath(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'app'; image(app/'Contents/MacOS/obs-ffmpeg-mux')
            with patch.object(module,'read_image',return_value=module.ImageInfo([],[])),patch.object(module,'run_tool',return_value='') as tool:
                with self.assertRaisesRegex(RuntimeError,'LC_RPATH'):
                    module.DependencyClosure(app,Path(temp)/'deps').close()
                module.DependencyClosure(app,Path(temp)/'deps',True).close()
                self.assertEqual(tool.call_args.args[0][1],'-add_rpath')

if __name__=='__main__': unittest.main(verbosity=2)
