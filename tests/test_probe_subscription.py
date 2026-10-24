"""Compile the app's actual subscription owner against OBS raw-activity semantics.

The pinned OBS source gates GPU readback on raw_active, incremented by the
obs_add_raw_video_callback wrapper, not by video_output_connect alone.
This fixture tests that lifecycle contract; it is not a GPU or Mac test.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parent.parent

class ProbeSubscriptionTests(unittest.TestCase):
    def test_raw_output_activation_and_balanced_unsubscribe(self):
        source=(ROOT/'app/Engine.mm').read_text()
        owner=source[source.index('struct ProbeConnection {'):source.index('void reportProbe(')]
        for name,end in [('verifyBeautyOnTestPattern','verifyFaceTrackingPipeline'),('verifyFaceTrackingPipeline','verifyStreamingComponents'),('verifyWorshipScenes','startRecordingAtPath')]:
            body=source[source.index('- (BOOL)'+name):source.index('- (BOOL)'+end)]
            self.assertIn('ProbeConnection probeConnection(probe)',body)
            self.assertNotIn('video_output_connect(',body)
            self.assertNotIn('video_output_disconnect(',body)
        fixture=r'''
#include <cassert>
#include <vector>
struct video_data {};
struct PixelProbe { int callbacks=0; };
using callback_t=void (*)(void *,video_data *);
struct Listener { callback_t callback; void *param; };
static std::vector<Listener> listeners;
static int rawActive=0,video=1;
static bool videoReady=true;
int *obs_get_video() { return videoReady ? &video : nullptr; }
void captureProbe(void *data,video_data *) { ++static_cast<PixelProbe *>(data)->callbacks; }
bool video_output_connect(int *,void *,callback_t callback,void *param) {
    listeners.push_back({callback,param}); return true;
}
void obs_add_raw_video_callback(void *,callback_t callback,void *param) {
    video_output_connect(&video,nullptr,callback,param); ++rawActive;
}
void obs_remove_raw_video_callback(callback_t callback,void *param) {
    for(auto it=listeners.begin();it!=listeners.end();++it) {
        if(it->callback==callback && it->param==param) { listeners.erase(it); --rawActive; return; }
    }
    assert(false && "duplicate/mismatched removal");
}
void render() {
    if(rawActive<=0) return;
    video_data frame;
    for(const auto &listener:listeners) listener.callback(listener.param,&frame);
}
'''
        main=r'''
int main() {
    PixelProbe old;
    assert(video_output_connect(&video,nullptr,captureProbe,&old));
    render(); assert(old.callbacks==0 && rawActive==0); listeners.clear();
    PixelProbe first,second;
    {
        ProbeConnection primary(first);
        assert(primary.connected && rawActive==1); render(); assert(first.callbacks==1);
        {
            ProbeConnection comparison(second);
            assert(rawActive==2); render(); assert(first.callbacks==2 && second.callbacks==1);
            comparison.stop(); comparison.stop(); assert(rawActive==1);
            render(); assert(first.callbacks==3 && second.callbacks==1);
        }
        assert(rawActive==1); // stopped comparison destructor must not decrement again
    }
    assert(rawActive==0 && listeners.empty());
    videoReady=false;
    { ProbeConnection absent(first); assert(!absent.connected); }
    assert(rawActive==0 && listeners.empty());
}
'''
        compiler=shutil.which('c++');self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as directory:
            cpp=Path(directory)/'probe.cpp';binary=Path(directory)/'probe';cpp.write_text(fixture+owner+main)
            built=subprocess.run([compiler,'-std=c++17','-Wall','-Wextra','-Werror',str(cpp),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr)
            subprocess.run([str(binary)],check=True)

if __name__=='__main__':unittest.main(verbosity=2)
