"""Integration checks using real FFmpeg, plus optional local Insta360 footage."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import cv2
import numpy as np
from core import Project, probe, export, tool, CREATE_FLAGS
from pano import PanoRenderer, primary, secondary, view_at


class WindowsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='elite-windows-test-')
        cls.folder=Path(cls.temp.name)
        cls.red=cls.folder/'red video Ã .mp4'; cls.blue=cls.folder/'blue.mp4'
        for color,path in [('red',cls.red),('blue',cls.blue)]:
            subprocess.run([tool('ffmpeg'),'-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'color=c={color}:s=320x180:r=24:d=2',
                '-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-c:a','aac','-shortest',str(path)],check=True,creationflags=CREATE_FLAGS)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def basic(self):
        p=Project(); p.settings.update(width=320,height=180,fps=24)
        m=p.add_media(self.red); c=p.add_clip(m['id']); c['duration']=1
        p.settings.update(width=320,height=180,fps=24)
        return p
    def test_minimal_project_resolves_duration_before_sequencing(self):
        path=self.folder/'minimal.elitestudio'
        path.write_text(json.dumps({'clips':[{'media':self.red.name,'in':.5,'out':1.5,'speed':2},{'media':self.red.name}]}),encoding='utf-8')
        p=Project.load(path)
        self.assertAlmostEqual(p.clips[0]['duration'],.5)
        self.assertAlmostEqual(p.clips[1]['start'],.5)
        self.assertAlmostEqual(p.clips[1]['duration'],2,places=1)
    def test_save_roundtrip_and_preserve_metadata(self):
        p=self.basic(); p.clips[0]['customExtension']={'keep':True}
        path=self.folder/'saved.elitestudio'; p.save(path)
        raw=json.loads(path.read_text(encoding='utf-8'))
        self.assertEqual(raw['media'][0]['path'],self.red.name)
        self.assertEqual(Project.load(path).clips[0]['customExtension'],{'keep':True})
    def test_split_preserves_source_time_at_speed(self):
        p=self.basic(); c=p.clips[0]; c.update(speed=2,**{'in':.2})
        self.assertTrue(p.split(c['id'],.4)); right=max(p.clips,key=lambda c:c['start'])
        self.assertAlmostEqual(right['in'],1); self.assertAlmostEqual(right['duration'],.6)
    def test_export_video_layers_gaps_speed_and_audio(self):
        p=self.basic(); blue=p.add_media(self.blue); overlay=p.add_clip(blue['id'],1,.25)
        overlay.update(duration=.5,volume=0,opacity=.5,scale=.5)
        second=p.add_clip(p.media[0]['id'],0,1.5); second.update(duration=.5,speed=2)
        out=self.folder/'rendered.mp4'; values=[]; export(p,out,values.append)
        self.assertEqual(values[-1],1)
        self.assertAlmostEqual(probe(out)['duration'],2,places=1)
        cap=cv2.VideoCapture(str(out))
        def pixel(t):
            cap.set(cv2.CAP_PROP_POS_MSEC,t*1000); ok,frame=cap.read(); self.assertTrue(ok); return frame[90,160].astype(int)
        red=pixel(.1); mix=pixel(.5); gap=pixel(1.25); after=pixel(1.75); cap.release()
        self.assertGreater(red[2],200); self.assertLess(red[0],20)
        self.assertGreater(mix[0],80); self.assertGreater(mix[2],80)
        self.assertLess(max(gap),10); self.assertGreater(after[2],200)
        pcm=subprocess.run([tool('ffmpeg'),'-v','error','-i',str(out),'-vn','-ac','1','-ar','48000','-f','f32le','pipe:1'],capture_output=True,check=True,creationflags=CREATE_FLAGS).stdout
        sound=np.frombuffer(pcm,dtype='<f4')
        self.assertGreater(np.std(sound[6000:18000]),.02)
        self.assertLess(np.std(sound[56000:64000]),.003)
    def test_title_only_and_logo_export(self):
        p=Project(); p.settings.update(width=320,height=180,fps=12,showLogo=True,logoY=10)
        p.clips.append(dict(id='title',track=2,start=0,duration=.5,**{'in':0},title=dict(names=['Andrea','Test'],fade=0)))
        out=self.folder/'titles.mp4'; export(p,out)
        cap=cv2.VideoCapture(str(out)); ok,frame=cap.read(); cap.release()
        self.assertTrue(ok); self.assertGreater(np.count_nonzero(frame>50),500)
    def test_failure_preserves_existing_output(self):
        p=self.basic(); p.media[0]['path']=str(self.folder/'missing.mp4')
        out=self.folder/'keep.mp4'; out.write_bytes(b'previous output')
        with self.assertRaises(FileNotFoundError): export(p,out)
        self.assertEqual(out.read_bytes(),b'previous output')
    def test_single_file_dual_fisheye(self):
        import struct
        from pano import MAGIC
        path=self.folder/'side-by-side.insv'
        subprocess.run([tool('ffmpeg'),'-hide_banner','-loglevel','error','-y',
            '-f','lavfi','-i','color=c=red:s=64x64:r=1:d=1',
            '-f','lavfi','-i','color=c=blue:s=64x64:r=1:d=1',
            '-filter_complex','[0:v][1:v]hstack[v]','-map','[v]','-c:v','libx264','-f','mp4',str(path)],check=True,creationflags=CREATE_FLAGS)
        info=b'\x12\x04Test'; rec=info+struct.pack('<HI',0x101,len(info))
        trailer=rec+b'\0'*32+struct.pack('<II',len(rec)+72,1)+MAGIC
        with path.open('ab') as out: out.write(trailer)
        renderer=PanoRenderer(path)
        try:
            self.assertFalse(renderer.data.pair)
            front=renderer.render(0,64,36,{'yaw':0,'stabilize':False})[18,32]
            back=renderer.render(0,64,36,{'yaw':180,'stabilize':False})[18,32]
            self.assertGreater(int(front[2]),200); self.assertLess(int(front[0]),20)
            self.assertGreater(int(back[0]),200); self.assertLess(int(back[2]),20)
        finally: renderer.close()
    def test_stabilization_uses_decoded_frame_time(self):
        import struct
        from pano import MAGIC
        path=self.folder/'timed.insv'
        subprocess.run([tool('ffmpeg'),'-hide_banner','-loglevel','error','-y',
            '-f','lavfi','-i','testsrc=s=128x64:r=25:d=2','-c:v','libx264','-g','10','-f','mp4',str(path)],check=True,creationflags=CREATE_FLAGS)
        info=b'\x12\x04Test'; rec=info+struct.pack('<HI',0x101,len(info))
        with path.open('ab') as out: out.write(rec+b'\0'*32+struct.pack('<II',len(rec)+72,1)+MAGIC)
        renderer=PanoRenderer(path); asked=[]
        original=renderer.data.stabilization
        renderer.data.stabilization=lambda t,r:(asked.append(t),original(t,r))[1]
        try:
            # 30 fps timeline over a 25 fps clip, forwards and with backward seeks
            for t in [.53,.0,1.21,1.233,.4,1.9]:
                renderer.render(t,32,18,{'stabilize':True},use_gpu=False)
                self.assertAlmostEqual(asked[-1],round(t*25)/25,places=6)
        finally: renderer.close()
    def test_cancel_preserves_output(self):
        p=self.basic(); out=self.folder/'cancel.mp4'; out.write_bytes(b'keep')
        cancel=threading.Event(); cancel.set()
        with self.assertRaisesRegex(RuntimeError,'cancelled'): export(p,out,cancel=cancel)
        self.assertEqual(out.read_bytes(),b'keep')
    def test_keyframe_easing_and_bounds(self):
        r={'keys':[{'t':1,'view':{'yaw':0}},{'t':3,'view':{'yaw':90}}]}
        self.assertEqual(view_at(r,0)['yaw'],0)
        self.assertAlmostEqual(view_at(r,2)['yaw'],45)
        self.assertEqual(view_at(r,4)['yaw'],90)
    @unittest.skipUnless(os.environ.get('ELITE_TEST_INSV'),'Set ELITE_TEST_INSV for real camera integration')
    def test_real_insv_preview_and_export(self):
        path=Path(os.environ['ELITE_TEST_INSV']); renderer=PanoRenderer(path)
        try:
            self.assertTrue(renderer.data.pair); self.assertGreater(len(renderer.data.t),100)
            frame=renderer.render(2,320,180,{'yaw':30,'stabilize':True,'lockDirection':True})
            self.assertEqual(frame.shape,(180,320,3)); self.assertGreater(frame.std(),20)
        finally: renderer.close()
        self.assertTrue(secondary(path.with_name(path.name.replace('_00_','_10_'))))
        p=Project(); m=p.add_media(path); c=p.add_clip(m['id']); c.update(duration=.3,**{'in':2},pano={'yaw':20,'pitch':0,'stabilize':True})
        p.settings.update(width=320,height=180,fps=10)
        out=self.folder/'360-export.mp4'; export(p,out)
        self.assertTrue(out.is_file()); self.assertAlmostEqual(probe(out)['duration'],.3,places=1)
        self.assertTrue(c.get('pano')); self.assertEqual(p.media[0]['path'],str(path.resolve()))


def ui_check():
    import faulthandler
    faulthandler.dump_traceback_later(18,exit=True)
    import app as application
    from PySide6.QtWidgets import QApplication
    from PySide6.QtCore import QTimer, QPoint, Qt
    from PySide6.QtTest import QTest
    original=QApplication.exec; failures=[]
    def execute(qapp):
        def run():
            editor=next(w for w in qapp.topLevelWidgets() if type(w).__name__=='Editor')
            messages=[]; editor.error=messages.append
            try:
                WindowsTests.setUpClass()
                editor.import_paths([str(WindowsTests.red),str(WindowsTests.blue)])
                deadline=__import__('time').monotonic()+10
                while editor.pending and __import__('time').monotonic()<deadline:
                    QTest.qWait(25); __import__('time').sleep(.025)
                assert not editor.pending and len(editor.project.media)==2,(editor.pending,len(editor.project.media),messages)
                editor.append_media(editor.project.media[0]['id']); editor.seek(.3)
                assert editor.viewer.pixmap() and not editor.viewer.pixmap().isNull()
                cid=editor.selected; editor.cut(.5); assert len(editor.project.clips)==2
                editor.timeline.setFocus(); editor.undo(); assert len(editor.project.clips)==1
                editor.redo(); assert len(editor.project.clips)==2
                editor.select(cid)
                rect=editor.timeline.clip_rect(editor.selected_clip()); start=rect.center().toPoint()
                QTest.mousePress(editor.timeline,Qt.MouseButton.LeftButton,pos=start)
                QTest.mouseMove(editor.timeline,start+QPoint(20,72),delay=20)
                QTest.mouseRelease(editor.timeline,Qt.MouseButton.LeftButton,pos=start+QPoint(20,72))
                assert editor.selected_clip()['track']==1
                editor.add_title(); assert editor.selected_clip()['track']==2
                editor.seek(.1); editor.render_preview(); editor.play(); QTest.qWait(150); editor.pause()
                if os.environ.get('ELITE_TEST_INSV'):
                    p=Project(); m=p.add_media(os.environ['ELITE_TEST_INSV']); c=p.add_clip(m['id']); c['duration']=4
                    editor.reset(p); editor.select(c['id']); editor.seek(2)
                    assert editor.pano_fields['yaw'].isEnabled()
                    editor.pano_fields['yaw'].setValue(25); editor.set_pano('yaw')
                    editor.add_pano_key(); assert len(c['pano']['keys'])==1
                    editor.seek(3); editor.pano_fields['yaw'].setValue(50); editor.set_pano('yaw')
                    assert len(c['pano']['keys'])==2
                assert not messages,messages
                editor.grab().save(str(Path(tempfile.gettempdir())/'elite-windows-ui.png'))
                print('PASS: GUI import, preview, split, undo/redo, drag across tracks, title, playback, 360 controls/keyframes')
            except Exception as e:
                import traceback; traceback.print_exc(); failures.append(str(e))
            finally:
                editor.dirty=False; editor.pending=False; editor.close(); QTest.qWait(150); WindowsTests.tearDownClass(); qapp.quit()
        QTimer.singleShot(300,run)
        return original()
    QApplication.exec=execute
    application.gui()
    if failures: raise AssertionError(failures)


if __name__=='__main__':
    if '--ui' in __import__('sys').argv: ui_check()
    else: unittest.main(verbosity=2)

