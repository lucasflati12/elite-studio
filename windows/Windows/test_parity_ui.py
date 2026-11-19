"""Exercise user gestures and commands in the actual Qt editor."""
import copy
import os
from pathlib import Path
import sys
import tempfile
import traceback
from unittest.mock import patch
from PySide6.QtWidgets import QApplication,QMainWindow
from PySide6.QtCore import QTimer,QPoint,Qt
from PySide6.QtTest import QTest
import app
from core import Project
from captions import normalize

original=QApplication.exec
failures=[]


def execute(qapp):
    def run():
        e=next(w for w in qapp.topLevelWidgets() if isinstance(w,QMainWindow)); messages=[]; e.error=messages.append
        try:
            p=Project(); p.settings.update(width=640,height=360,fps=30)
            p.data['clips']=[dict(id='a',track=2,start=0,duration=2,title=dict(names='Primo titolo')),
                     dict(id='b',track=2,start=3,duration=2,title=dict(names='Secondo titolo'))]
            e.reset(p); e.timeline.zoom=80; e.timeline.refresh(); e.timeline.setFocus()
            a,b=e.project.clips
            QTest.mouseClick(e.timeline,Qt.MouseButton.LeftButton,pos=e.timeline.clip_rect(a).center().toPoint())
            QTest.mouseClick(e.timeline,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.ControlModifier,pos=e.timeline.clip_rect(b).center().toPoint())
            assert len(e.selected_clips())==2, 'Ctrl+click selection'
            e.copy_clip(); e.seek(1); e.paste_clip(); assert len(e.selected_clips())==2
            assert sorted(c['start'] for c in e.selected_clips())==[1,4], 'Paste must keep relative timing'
            e.timeline.setFocus(); e.undo(); assert len(e.project.clips)==2
            e.select_all(); assert len(e.selected_clips())==2
            start=e.timeline.clip_rect(e.project.clips[0]).center().toPoint()
            QTest.mousePress(e.timeline,Qt.MouseButton.LeftButton,pos=start)
            QTest.mouseMove(e.timeline,start+QPoint(80,0),delay=20)
            QTest.mouseRelease(e.timeline,Qt.MouseButton.LeftButton,pos=start+QPoint(80,0))
            assert sorted(c['start'] for c in e.project.clips)==[1,4], 'Group move'
            e.undo(); e.select(None)
            QTest.mousePress(e.timeline,Qt.MouseButton.LeftButton,pos=QPoint(e.timeline.left+500,e.timeline.row_y(1)+8))
            QTest.mouseMove(e.timeline,QPoint(e.timeline.left+1,e.timeline.top+1),delay=20)
            QTest.mouseRelease(e.timeline,Qt.MouseButton.LeftButton,pos=QPoint(e.timeline.left+1,e.timeline.top+1))
            assert len(e.selected_clips())==2, 'Rectangle selection'
            e.select('a'); e.seek(1); e.ripple_trim(True)
            assert sorted(c['start'] for c in e.project.clips)==[0,2], 'Q ripple trim'
            e.undo(); e.select('a'); e.seek(1); e.ripple_trim(False)
            assert e.project.clips[0]['duration']==1 and e.project.clips[1]['start']==2, 'W ripple trim'
            e.undo(); e.seek(.2); e.add_caption(); e.caption_text.setText('Uno due tre'); e.edit_caption()
            c=e.caption(); assert len(c['words'])==3
            e.caption_look.setCurrentIndex(2); e.style_captions(); assert e.project.data['captionStyle']['look']=='oro'
            e.caption_times['end'].setValue(2.2); e.edit_caption(); assert e.caption()['end']==2.2
            e.seek(1); e.cut(); assert len(e.project.data['captions'])==2, 'Caption razor'
            e.undo(); e.selected_caption=None; e.select_caption(e.project.data['captions'][0]['id'])
            start=e.timeline.caption_rect(e.caption()).center().toPoint()
            QTest.mousePress(e.timeline,Qt.MouseButton.LeftButton,pos=start)
            QTest.mouseMove(e.timeline,start+QPoint(80,0),delay=20)
            QTest.mouseRelease(e.timeline,Qt.MouseButton.LeftButton,pos=start+QPoint(80,0))
            assert abs(e.caption()['start']-1.2)<.01, 'Caption drag retimes words'
            assert abs(e.caption()['words'][0]['s']-1.2)<.01
            e.seek(1.7); e.render_preview(); QTest.qWait(120); e.grab().save(str(Path(tempfile.gettempdir())/'elite-parity-ui.png'))
            e.delete(); assert not e.project.data['captions']; e.undo(); assert e.project.data['captions']
            e.seek(2); e.shuttle(-1); QTest.qWait(120); e.pause(); assert e.position<2, 'J reverse'
            e.shuttle(1); e.shuttle(1); assert e.play_rate==2; e.pause()
            if os.environ.get('ELITE_TEST_SPEECH'):
                p=Project(); m=p.add_media(os.environ['ELITE_TEST_SPEECH']); p.add_clip(m['id']); p.data['captionStyle']['language']='en-US'; e.reset(p)
                e.generate_captions()
                import time
                deadline=time.monotonic()+60
                while e.pending and time.monotonic()<deadline: QTest.qWait(50); time.sleep(.01)
                assert not e.pending and e.project.data['captions'],('GUI transcription',messages)
            assert not messages,messages
            print('PASS: multiselection, rectangle, group move/copy/paste, Q/W, captions text/style/time/drag/split/delete, undo, J/L, speech GUI',flush=True)
        except Exception:
            failures.append(traceback.format_exc()); print(failures[-1],flush=True)
        finally:
            e.dirty=False; e.pending=False; e.close(); qapp.quit()
    QTimer.singleShot(350,run)
    return original()


with patch.object(QApplication,'exec',execute): app.gui()
if failures: sys.exit(1)
