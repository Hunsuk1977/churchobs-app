"""Exercise the real source-update functions with a deferred OBS-instance contract.

Foundation bitmap/base64 work is substituted; the actual dispatch, validation,
callback and frame replacement bodies are compiled. This is not a Mac run.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parent.parent

class StageCardUpdateTests(unittest.TestCase):
    def test_update_reaches_instance_with_no_registration_type_data(self):
        compiler=shutil.which('c++')
        self.assertIsNotNone(compiler,'C++ compiler required')
        source=(ROOT/'app/StageCard.mm').read_text()
        callback=source[source.index('void updateCard('):source.index('void destroyCard(')]
        callback=callback.replace('@autoreleasepool','')
        callback=re.sub(r'NSString \*encoded=.*?;\s*NSData \*data=.*?;',
                        'FakeData data{settings->pixels.size(),settings->pixels.data()};',callback,flags=re.S)
        update=source[source.index('bool ws_update_stage_card('):source.index('obs_source_t *ws_create_stage_card(')]
        update=update.replace('NSInteger','long').replace('NSString *','const char *').replace('NSData *pixels','FakeFrame *pixels')
        update=update.replace('[pixels base64EncodedStringWithOptions:0].UTF8String','pixels->encoded.c_str()')
        fixture=r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
constexpr size_t frameBytes=1280*720*4;
struct obs_data_t { std::string pixels; };
struct obs_source_t { const char *id="churchobs_stage_card"; void *type_data=nullptr; std::string pending; bool queued=false; };
struct Card { obs_source_t *source=nullptr; uint8_t *pixels=nullptr; std::mutex mutex; };
struct FakeData { size_t length; const void *bytes; };
struct FakeFrame { std::string encoded; };
void *bmemdup(const void *data,size_t size) { void *copy=malloc(size); memcpy(copy,data,size); return copy; }
void bfree(void *data) { free(data); }
const char *obs_source_get_unversioned_id(obs_source_t *source) { return source->id; }
void *obs_source_get_type_data(obs_source_t *source) { return source->type_data; }
obs_data_t *obs_data_create() { return new obs_data_t; }
void obs_data_release(obs_data_t *data) { delete data; }
void obs_data_set_string(obs_data_t *data,const char *,const char *value) { data->pixels=value; }
void obs_source_update(obs_source_t *source,obs_data_t *data) { source->pending=data->pixels; source->queued=true; }
FakeFrame *renderCardPixels(long,const char *text,const char *path) {
    if(strcmp(path,"missing")==0) return nullptr;
    static FakeFrame frame;
    frame.encoded.assign(frameBytes,text[0]); return &frame;
}
'''
        main=r'''
int main() {
    obs_source_t source;
    Card card; card.source=&source;
    std::string initial(frameBytes,'a'); card.pixels=static_cast<uint8_t *>(bmemdup(initial.data(),initial.size()));
    assert(obs_source_get_type_data(&source)==nullptr); // normal registration has no type_data
    assert(!ws_update_stage_card(nullptr,0,"b",""));
    assert(!ws_update_stage_card(&source,0,"b","missing"));
    for(const char *text : {"b","c","d","e","f","g"}) {
        unsigned char previous=card.pixels[0];
        assert(ws_update_stage_card(&source,0,text,""));
        assert(source.queued && card.pixels[0]==previous); // OBS defers video updates
        obs_data_t settings; settings.pixels=source.pending;
        updateCard(&card,&settings); source.queued=false;
        assert(card.pixels[0]==text[0] && card.pixels[frameBytes-1]==text[0]);
    }
    obs_data_t invalid; invalid.pixels="short";
    updateCard(&card,&invalid); assert(card.pixels[0]=='g'); // malformed update keeps last good frame
    bfree(card.pixels);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'card.cpp';binary=Path(directory)/'card'
            path.write_text(fixture+callback+update+main)
            built=subprocess.run([compiler,'-std=c++17','-Wall','-Wextra','-Werror','-pthread',str(path),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr)
            subprocess.run([str(binary)],check=True)

if __name__=='__main__':unittest.main(verbosity=2)
