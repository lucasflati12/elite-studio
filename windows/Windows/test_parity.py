"""Regression tests for cross-platform captions and timeline editing."""
import copy
import json
import tempfile
from pathlib import Path
import unittest
from PIL import Image
import numpy as np
from core import Project,export,probe
from captions import normalize,chunks,retime,set_text,draw
from editing import extract,change_speed
from playback import preview_signature


class ParityTests(unittest.TestCase):
    def project(self):
        p=Project(); p.settings.update(width=320,height=180,fps=12)
        p.clips.append(dict(id='title',track=2,start=0,duration=2,title=dict(names='',tag='',label='',showLabel=False)))
        p.data['tracks']['titlesHidden']=True
        p.data['captions']=normalize([dict(start=.1,end=1.8,text='Prova video')])
        p.data['captionStyle'].update(look='bianco',pop=False)
        return p

    def test_mac_caption_roundtrip_and_hand_edits(self):
        p=self.project(); p.data['captions'][0]['text']='Testo corretto'
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'mac.elitestudio'; p.save(path); q=Project.load(path)
            self.assertEqual([w['w'] for w in q.data['captions'][0]['words']],['Testo','corretto'])
            self.assertEqual(q.data['captionStyle']['look'],'bianco')
            self.assertFalse(q.data['tracks']['captionsHidden'])

    def test_retime_preserves_relative_word_timing(self):
        c=normalize([dict(start=1,end=3,text='uno due')])[0]
        retime(c,3,7)
        self.assertEqual([(w['s'],w['e']) for w in c['words']],[(3,5),(5,7)])
        set_text(c,'tre quattro'); self.assertEqual(c['words'][1]['s'],5)

    def test_ripple_spanning_clip_keeps_source_time_and_captions(self):
        p=self.project(); p.clips[0].update(duration=6,speed=2,**{'in':1})
        p.data['captions']=normalize([dict(start=0,end=1,text='prima'),dict(start=1,end=2,text='taglio'),dict(start=4,end=5,text='dopo')])
        extract(p,1,3)
        self.assertEqual(len(p.clips),2)
        right=p.clips[1]; self.assertEqual((right['start'],right['duration'],right['in']),(1,3,7))
        self.assertEqual([c['text'] for c in p.data['captions']],['prima','dopo'])
        self.assertEqual(p.data['captions'][1]['start'],2)

    def test_speed_shifts_following_clips_and_captions(self):
        p=self.project(); first=p.clips[0]
        p.clips.append(dict(id='next',track=2,start=2,duration=1,title={}))
        p.data['captions']=normalize([dict(start=2,end=3,text='dopo')])
        change_speed(p,first,2)
        self.assertEqual(first['duration'],1); self.assertEqual(p.clips[1]['start'],1)
        self.assertEqual(p.data['captions'][0]['start'],1)

    def test_grouping_limits_words_and_breaks_on_pauses(self):
        words=[dict(w=w,s=i*.2,e=(i+1)*.2) for i,w in enumerate('uno due tre quattro cinque'.split())]
        caps=chunks(words,2)
        self.assertEqual([len(c['words']) for c in caps],[2,2,1])
        self.assertTrue(all(c['end']<=n['start'] for c,n in zip(caps,caps[1:])))

    def test_caption_changes_invalidate_rendered_preview(self):
        p=self.project(); old=preview_signature(p)
        p.data['captions'][0]['text']='modifica'; self.assertNotEqual(preview_signature(p),old)
        old=preview_signature(p); p.data['captionStyle']['size']=2; self.assertNotEqual(preview_signature(p),old)

    def test_negative_text_inverts_underlying_pixels(self):
        p=self.project(); canvas=Image.new('RGBA',(320,180),(20,60,100,255))
        image=draw(canvas,p.data['captions'],dict(look='negativo',pop=False),.5)
        rgb=np.array(image)[:,:,:3]
        self.assertGreater(np.count_nonzero(np.all(rgb==[235,195,155],axis=2)),20)
        self.assertTrue(np.array_equal(rgb[0,0],[20,60,100]))

    def test_caption_export_matches_preview_and_has_audio(self):
        import cv2
        p=self.project()
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'captions.mp4'; values=[]; export(p,out,values.append)
            cap=cv2.VideoCapture(str(out)); cap.set(cv2.CAP_PROP_POS_MSEC,500); ok,frame=cap.read(); cap.release()
            self.assertTrue(ok); self.assertTrue(probe(out)['hasAudio']); self.assertEqual(values[-1],1)
            expected=np.array(draw(Image.new('RGBA',(320,180),'black'),p.data['captions'],p.data['captionStyle'],.5))[:,:,:3]
            actual=cv2.cvtColor(frame,cv2.COLOR_BGR2RGB)
            self.assertLess(np.abs(actual.astype(float)-expected).mean(),3)
            self.assertGreater(actual.max(),200)

    def test_hidden_captions_not_burned(self):
        import cv2
        p=self.project(); p.data['tracks']['captionsHidden']=True
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'hidden.mp4'; export(p,out)
            cap=cv2.VideoCapture(str(out)); cap.set(cv2.CAP_PROP_POS_MSEC,500); ok,frame=cap.read(); cap.release()
            self.assertTrue(ok); self.assertLess(frame.max(),10)

    def test_cancel_during_caption_pass_preserves_previous_export(self):
        import threading
        p=self.project(); cancel=threading.Event()
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'keep.mp4'; out.write_bytes(b'previous')
            def progress(value):
                if value>.75: cancel.set()
            with self.assertRaisesRegex(RuntimeError,'cancelled'): export(p,out,progress,cancel)
            self.assertEqual(out.read_bytes(),b'previous')


if __name__=='__main__': unittest.main(verbosity=2)
