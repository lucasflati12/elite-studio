"""Synthetic-media coverage for Windows editing additions, Round 3a items 1–6."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import cv2
import numpy as np
from core import Project, export, probe, tool, CREATE_FLAGS, uid
from editing import apply_speed_ramp


class EditingPlusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='elite-editing-plus-')
        cls.root=Path(cls.temp.name); cls.source=cls.root/'source.mp4'
        subprocess.run([tool('ffmpeg'),'-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=24:duration=3','-f','lavfi','-i','sine=frequency=330:sample_rate=48000:duration=3','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-c:a','aac','-shortest',str(cls.source)],check=True,creationflags=CREATE_FLAGS)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def project(self):
        p=Project(); p.settings.update(width=320,height=180,fps=24)
        m=p.add_media(self.source); c=p.add_clip(m['id']); c['duration']=1.5
        return p,c
    def pixels(self,path,t=.2):
        cap=cv2.VideoCapture(str(path)); cap.set(cv2.CAP_PROP_POS_MSEC,t*1000); ok,frame=cap.read(); cap.release(); self.assertTrue(ok); return frame
    def test_1_markers_roundtrip_edit_and_undo_snapshot(self):
        p,c=self.project(); before=copy.deepcopy(p.data); p.data['markers']=[dict(t=.5,name='Ritornello',color='#ff3366')]
        target=self.root/'markers.elitestudio'; p.save(target); loaded=Project.load(target)
        self.assertEqual(loaded.data['markers'],p.data['markers']); self.assertEqual(loaded.data['clips'][0]['id'],c['id'])
        loaded.data=before; self.assertEqual(loaded.data.get('markers',[]),[])
    def test_2_speed_ramp_is_three_renderable_segments_and_undoable(self):
        p,c=self.project(); before=copy.deepcopy(p.data); parts=apply_speed_ramp(p,c,1,'Bullet')
        self.assertEqual(len(parts),3); self.assertEqual([x['speedRamp']['segment'] for x in parts],[0,1,2])
        self.assertAlmostEqual(sum(x['duration'] for x in parts),4.2,places=2)
        for part in parts:part['pitch']=False
        out=self.root/'ramp.mp4'; export(p,out); self.assertAlmostEqual(probe(out)['duration'],sum(x['duration'] for x in parts),delta=.12)
        saved=self.root/'ramp.elitestudio'; p.save(saved); self.assertEqual(len(Project.load(saved).clips),3)
        p.data=before; self.assertEqual(len(p.clips),1)
    def test_3_freeze_image_clip_exports_for_its_duration(self):
        still=self.root/'freeze.png'; subprocess.run([tool('ffmpeg'),'-v','error','-y','-ss','0.7','-i',str(self.source),'-frames:v','1',str(still)],check=True,creationflags=CREATE_FLAGS)
        p=Project(); p.settings.update(width=320,height=180,fps=24); m=probe(still); p.media.append(m); c=p.add_clip(m['id']); c.update(duration=2,freezeFrame=True,freezeSource={'media':'source','time':.7})
        out=self.root/'freeze.mp4'; export(p,out); self.assertAlmostEqual(probe(out)['duration'],2,delta=.12)
        first=self.pixels(out,.1); later=self.pixels(out,1.8); self.assertLess(float(np.mean(np.abs(first.astype(float)-later.astype(float)))),2.5)
        saved=self.root/'freeze.elitestudio'; p.save(saved); self.assertEqual(Project.load(saved).clips[0]['freezeSource']['time'],.7)
    def test_4_reverse_intermediate_exports_in_reverse_frame_order(self):
        reverse=self.root/'reverse.mp4'
        subprocess.run([tool('ffmpeg'),'-v','error','-y','-i',str(self.source),'-vf','reverse','-af','areverse','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-c:a','aac',str(reverse)],check=True,creationflags=CREATE_FLAGS)
        p=Project(); p.settings.update(width=320,height=180,fps=24); m=probe(reverse); p.media.append(m); c=p.add_clip(m['id']); c.update(duration=1.5,reversed=True,reverseSource={'media':'source','in':0,'duration':1.5})
        out=self.root/'reverse-export.mp4'; export(p,out); self.assertEqual(c['in'],0)
        self.assertLess(float(np.mean(np.abs(self.pixels(out,.04).astype(float)-self.pixels(self.source,2.9).astype(float)))),45)
        saved=self.root/'reverse.elitestudio'; p.save(saved); self.assertTrue(Project.load(saved).clips[0]['reversed'])
    def test_5_crop_flip_and_6_blurred_canvas_export_and_json(self):
        p,c=self.project(); before=copy.deepcopy(p.data); c.update(crop={'left':.1,'right':.1,'top':.05,'bottom':.05},flipH=True,background={'type':'blur','amount':8})
        out=self.root/'transform.mp4'; export(p,out)
        pixel=self.pixels(out,.2); self.assertGreater(float(np.std(pixel)),20)
        target=self.root/'transform.elitestudio'; p.save(target); loaded=Project.load(target)
        self.assertEqual(loaded.clips[0]['crop'],c['crop']); self.assertTrue(loaded.clips[0]['flipH']); self.assertEqual(loaded.clips[0]['background'],c['background'])
        p.data=before; self.assertNotIn('crop',p.clips[0])


if __name__=='__main__': unittest.main()
