"""Exercise the real FFmpeg converter using the app's selected OBS enum.

No Vision or fake face detector is substituted. These tests cover conversion
only; Run-Engine-Test.command covers Vision on macOS.
"""
import ctypes as C
import ctypes.util
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
CONSTANTS = {'SWS_FAST_BILINEAR':1,'SWS_BILINEAR':2,'SWS_BICUBIC':4,'SWS_POINT':16,'SWS_AREA':32}

class FaceScalerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sw=ctypes.util.find_library('swscale'); av=ctypes.util.find_library('avutil')
        if not sw or not av: raise unittest.SkipTest('system FFmpeg libraries unavailable; run native Mac integration check')
        cls.sw=C.CDLL(sw); cls.av=C.CDLL(av)
        cls.av.av_get_pix_fmt.argtypes=[C.c_char_p]; cls.av.av_get_pix_fmt.restype=C.c_int
        cls.sw.sws_getContext.argtypes=[C.c_int]*7+[C.c_void_p]*3; cls.sw.sws_getContext.restype=C.c_void_p
        cls.sw.sws_freeContext.argtypes=[C.c_void_p]
        cls.sw.sws_scale.argtypes=[C.c_void_p,C.POINTER(C.POINTER(C.c_uint8)),C.POINTER(C.c_int),C.c_int,C.c_int,C.POINTER(C.POINTER(C.c_uint8)),C.POINTER(C.c_int)]
        cls.sw.sws_scale.restype=C.c_int
        source=(ROOT/'app/FaceTracker.mm').read_text()
        cls.enum=re.search(r'video_scaler_create\(&t->scaler,&dst,&src,(VIDEO_SCALE_\w+)\)',source).group(1)
        upstream=(ROOT/'vendor/obs-studio/libobs/media-io/video-scaler-ffmpeg.c').read_text()
        expression=re.search(r'case '+cls.enum+r':\s*return ([^;]+);',upstream).group(1)
        cls.flags=0
        for item in expression.split('|'): cls.flags|=CONSTANTS[item.strip()]

    def context(self, fmt, flags):
        return self.sw.sws_getContext(1280,720,self.av.av_get_pix_fmt(fmt.encode()),480,270,self.av.av_get_pix_fmt(b'bgra'),flags,None,None,None)

    def test_app_selects_one_algorithm(self):
        self.assertGreater(self.flags,0)
        self.assertEqual(self.flags & (self.flags-1),0)

    def test_original_bilinear_area_combination_is_rejected(self):
        context=self.context('nv12',2|32)
        try: self.assertFalse(context)
        finally: self.sw.sws_freeContext(context)

    def test_actual_camera_pixel_conversion(self):
        P=C.POINTER(C.c_uint8)
        for fmt in ['nv12','bgra','uyvy422','yuyv422']:
            with self.subTest(format=fmt):
                w,h=1280,720
                plane0=(C.c_uint8*(w*h*4+64))(); plane1=(C.c_uint8*(w*h+64))()
                if fmt=='nv12':
                    C.memset(plane0,81,w*h); C.memset(plane1,128,w*h)
                    strides=(C.c_int*4)(w,w,0,0)
                else:
                    pattern=bytes([32,96,160,255] if fmt=='bgra' else [128,81,128,81] if fmt=='uyvy422' else [81,128,81,128])
                    content=pattern*(w*h if fmt=='bgra' else w*h//2)
                    C.memmove(plane0,content,len(content))
                    strides=(C.c_int*4)(w*(4 if fmt=='bgra' else 2),0,0,0)
                pixels=(P*4)(C.cast(plane0,P),C.cast(plane1,P),None,None)
                output=(C.c_uint8*(480*270*4+64))()
                destinations=(P*4)(C.cast(output,P),None,None,None)
                out_stride=(C.c_int*4)(480*4,0,0,0)
                context=self.context(fmt,self.flags)
                self.assertTrue(context)
                try:
                    self.assertEqual(self.sw.sws_scale(context,pixels,strides,0,h,destinations,out_stride),270)
                    self.assertEqual(output[3],255)
                    self.assertEqual(output[4*(480*270-1)+3],255)
                    if fmt=='bgra':
                        for actual, expected in zip(output[:3],[32,96,160]): self.assertLessEqual(abs(actual-expected),2)
                    else:
                        self.assertLessEqual(max(output[:3])-min(output[:3]),1)
                        self.assertTrue(65<=output[0]<=85)
                finally: self.sw.sws_freeContext(context)

if __name__=='__main__': unittest.main(verbosity=2)
