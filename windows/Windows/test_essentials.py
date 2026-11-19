import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
import cv2
import numpy as np
from PIL import Image
from core import Project,export,tool,CREATE_FLAGS
from effects import at,color,envelope,crossfade,validate
import test_windows as fixtures


class EssentialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.WindowsTests.setUpClass(); cls.folder=fixtures.WindowsTests.folder; cls.red=fixtures.WindowsTests.red; cls.blue=fixtures.WindowsTests.blue
    @classmethod
    def tearDownClass(cls): fixtures.WindowsTests.tearDownClass()
    def basic(self): return fixtures.WindowsTests.basic(self)
    def frame(self,path,t):
        cap=cv2.VideoCapture(str(path)); cap.set(cv2.CAP_PROP_POS_MSEC,t*1000); ok,frame=cap.read(); cap.release(); self.assertTrue(ok); return frame
    def test_neutral_color_is_zero_cost(self):
        im=Image.new('RGBA',(100,100),'red'); self.assertIs(color(im,{}),im)
    def test_color_export_matches_preview(self):
        p=self.basic(); p.clips[0]['effects']=dict(exposure=-.7,contrast=.8,saturation=.4,temperature=-.3)
        path=self.folder/'color.mp4'; export(p,path); actual=self.frame(path,.5)[90,160][::-1]
        source=self.frame(self.red,.5)[90,160][::-1]; im=Image.fromarray(np.array([[source]],dtype=np.uint8)).convert('RGBA')
        expected=np.array(color(im,p.clips[0]['effects']))[0,0,:3]
        self.assertLess(np.abs(actual.astype(float)-expected).max(),6)
    def test_media_time_motion_survives_split(self):
        p=self.basic(); c=p.clips[0]; c['effects']=dict(keys=[dict(t=0,x=-.2),dict(t=2,x=.2)],ease='linear')
        before=at(c,.75); p.split(c['id'],.5); right=max(p.clips,key=lambda c:c['start'])
        self.assertAlmostEqual(at(right,.25)['x'],before['x'])
    def test_motion_video_export_changes_position_and_opacity(self):
        p=self.basic(); c=p.clips[0]; c.update(scale=.4)
        c['effects']=dict(ease='linear',keys=[dict(t=0,x=-.25,opacity=.2,scale=.4),dict(t=1,x=.25,opacity=1,scale=.4)])
        path=self.folder/'motion.mp4'; export(p,path)
        early=self.frame(path,.15); late=self.frame(path,.85)
        self.assertGreater(early[90,80,2],20); self.assertLess(early[90,240,2],10)
        self.assertGreater(late[90,240,2],150); self.assertLess(late[90,80,2],10)
    def test_video_audio_fades(self):
        p=self.basic(); p.clips[0]['effects']=dict(fadeIn=.5,fadeOut=.3,audioFadeIn=.5,audioFadeOut=.3)
        path=self.folder/'fades.mp4'; export(p,path)
        early=self.frame(path,.04)[90,160,2]; middle=self.frame(path,.6)[90,160,2]
        self.assertLess(early,middle*.4)
        pcm=subprocess.run([tool('ffmpeg'),'-v','error','-i',str(path),'-vn','-ac','1','-ar','48000','-f','f32le','pipe:1'],capture_output=True,check=True,creationflags=CREATE_FLAGS).stdout
        sound=np.frombuffer(pcm,dtype='<f4'); self.assertLess(np.std(sound[1000:3000]),np.std(sound[25000:28000])*.4)
    def test_animated_scale_and_rotation_export(self):
        p=self.basic(); c=p.clips[0]
        c['effects']=dict(ease='linear',keys=[dict(t=0,scale=.3,rotation=0),dict(t=1,scale=.8,rotation=20)])
        path=self.folder/'scale.mp4'; export(p,path)
        early=self.frame(path,.1); late=self.frame(path,.85)
        self.assertLess(np.count_nonzero(early[:,:,2]>100),np.count_nonzero(late[:,:,2]>100)*.6)
    def test_crossfade_overlaps_and_renders_both_videos(self):
        p=self.basic(); m=p.add_media(self.blue); b=p.add_clip(m['id'],0,1); b['duration']=1
        d=crossfade(p,b['id'],.4); self.assertEqual(d,.4); self.assertAlmostEqual(p.duration,1.6)
        path=self.folder/'crossfade.mp4'; export(p,path); mix=self.frame(path,.8)[90,160]
        self.assertGreater(mix[0],60); self.assertGreater(mix[2],60)
    def test_crossfade_preserves_occupied_lane_and_uses_a_free_track(self):
        p=self.basic(); m=p.add_media(self.blue); b=p.add_clip(m['id'],0,1); b['duration']=1
        overlay=p.add_clip(m['id'],1,.5); overlay['duration']=1
        crossfade(p,b['id'])
        self.assertEqual(b['track'],3); self.assertIn(overlay,p.clips); self.assertEqual(overlay['track'],1)
        self.assertEqual(p.lanes,[0,1,3])
    def test_proxy_uses_source_signature_and_respects_dimensions(self):
        import storage
        p=self.basic()
        with tempfile.TemporaryDirectory() as tmp,patch.object(storage,'CACHE',Path(tmp)):
            path,key=storage.proxy(p.media[0]); self.assertEqual(key,storage.fingerprint(self.red))
            cap=cv2.VideoCapture(path); self.assertLessEqual(max(cap.get(cv2.CAP_PROP_FRAME_WIDTH),cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),960); cap.release()
            self.assertEqual(storage.proxy(p.media[0]),(path,key))
    def test_cache_limit_and_protected_files(self):
        import storage
        with tempfile.TemporaryDirectory() as tmp,patch.object(storage,'CACHE',Path(tmp)):
            a=Path(tmp)/'a'; b=Path(tmp)/'b'; a.write_bytes(b'a'*100); b.write_bytes(b'b'*100)
            storage.prune(limit=100,protect=[b]); self.assertFalse(a.exists()); self.assertTrue(b.exists())
    def test_recovery_and_history_preserve_media_resolution(self):
        import storage
        p=self.basic()
        with tempfile.TemporaryDirectory() as tmp,patch.object(storage,'SUPPORT',Path(tmp)):
            storage.snapshot(p); recovered=Project.load(storage.recovery_path()); self.assertEqual(recovered.media[0]['path'],str(self.red.resolve()))
            p.save(Path(tmp)/'project.elitestudio'); storage.backup(p.path)
            paths=storage.history(p.path); self.assertEqual(len(paths),1); self.assertEqual(Project.load(paths[0]).media[0]['path'],str(self.red.resolve()))
            storage.discard_recovery(); self.assertFalse(storage.recovery_path().exists())
    def test_effect_validation_rejects_nonfinite_keys(self):
        with self.assertRaises(ValueError): validate(dict(keys=[dict(t=float('nan'))]))
    def test_extra_tracks_roundtrip_and_render(self):
        p=self.basic(); m=p.add_media(self.blue); c=p.add_clip(m['id'],3,0); c['duration']=1; p.ensure_tracks()
        self.assertEqual(p.lanes,[0,1,3]); self.assertEqual(p.track_label(3),'V3 / A3')
        path=self.folder/'tracks.elitestudio'; p.save(path); loaded=Project.load(path)
        self.assertEqual(loaded.lanes,[0,1,3]); self.assertEqual(loaded.clips[-1]['track'],3)
        out=self.folder/'tracks.mp4'; export(loaded,out); pixel=self.frame(out,.5)[90,160]
        self.assertGreater(pixel[0],200); self.assertLess(pixel[2],10)
    def test_hardware_export_and_captions_or_cpu_fallback(self):
        from captions import normalize
        p=self.basic(); p.data['captions']=normalize([dict(start=0,end=.9,text='Test')]); p.data['captionStyle'].update(look='bianco',pop=False)
        out=self.folder/'hardware.mp4'; export(p,out,hardware=True)
        self.assertTrue(out.is_file()); self.assertGreater(self.frame(out,.5)[90,160,2],100)
    def test_volume_keyframes_are_applied_to_export(self):
        p=self.basic(); p.clips[0]['effects']=dict(ease='linear',keys=[dict(t=0,volume=0),dict(t=1,volume=1)])
        out=self.folder/'volume.mp4'; export(p,out)
        result=subprocess.run([tool('ffmpeg'),'-v','error','-i',str(out),'-vn','-ac','1','-ar','48000','-f','f32le','pipe:1'],capture_output=True,check=True,creationflags=CREATE_FLAGS)
        pcm=np.frombuffer(result.stdout,dtype='<f4'); self.assertGreater(np.std(pcm[34000:38000]),np.std(pcm[5000:9000])*2)
    def test_hardware_failure_retries_cpu_but_cancel_does_not(self):
        import core
        p=self.basic()
        with patch.object(core,'_export',side_effect=[RuntimeError('Driver error'),None]) as render:
            core.export(p,self.folder/'fallback.mp4',hardware=True); self.assertEqual(render.call_count,2)
            self.assertFalse(render.call_args.args[5])
        cancel=threading.Event(); cancel.set()
        with patch.object(core,'_export',side_effect=RuntimeError('Export cancelled')) as render:
            with self.assertRaises(RuntimeError): core.export(p,self.folder/'cancel.mp4',cancel=cancel,hardware=True)
            self.assertEqual(render.call_count,1)
    def test_overlapping_long_fades_match_preview(self):
        p=self.basic(); c=p.clips[0]; c['effects']=dict(fadeIn=3,fadeOut=3)
        out=self.folder/'overlapping-fades.mp4'; export(p,out)
        value=self.frame(out,.5)[90,160,2]
        self.assertAlmostEqual(value,253*envelope(c,.5),delta=8)


if __name__=='__main__': unittest.main(verbosity=2)
