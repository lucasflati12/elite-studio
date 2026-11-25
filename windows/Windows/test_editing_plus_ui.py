"""Qt interaction and undo coverage for Round 3a commands."""
import shutil
import tempfile
import traceback
from pathlib import Path
from unittest.mock import patch

from PySide6.QtCore import QTimer,Qt,QPoint
from PySide6.QtWidgets import QApplication,QMainWindow
from PySide6.QtTest import QTest
from core import Project,tool,CREATE_FLAGS
import subprocess
import app

original=QApplication.exec; failures=[]

def execute(qapp):
    def run():
        e=next(w for w in qapp.topLevelWidgets() if isinstance(w,QMainWindow))
        try:
            folder=tempfile.mkdtemp(prefix='elite-editing-plus-ui-')
            try:
                source=Path(folder)/'source.mp4'
                subprocess.run([tool('ffmpeg'),'-v','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=24:duration=3','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',str(source)],check=True,creationflags=CREATE_FLAGS)
                p=Project(); p.settings.update(width=320,height=180,fps=24); m=p.add_media(source); c=p.add_clip(m['id']); c['duration']=1
                e.reset(p); e.select(c['id']); e.seek(.5)
                QTest.keyClick(e.timeline,Qt.Key.Key_M); assert len(e.project.data['markers'])==1
                e.undo(); assert not e.project.data['markers']; e.redo(); assert len(e.project.data['markers'])==1
                e.project.data['markers']=[dict(t=.2,name='A',color='#ff0000'),dict(t=.8,name='B',color='#00ff00')]
                e.seek(.1); QTest.keyClick(e.timeline,Qt.Key.Key_M,Qt.KeyboardModifier.ShiftModifier); assert abs(e.position-.2)<.001
                QTest.keyClick(e.timeline,Qt.Key.Key_M,Qt.KeyboardModifier.ShiftModifier); assert abs(e.position-.8)<.001
                QTest.keyClick(e.timeline,Qt.Key.Key_M,Qt.KeyboardModifier.ControlModifier|Qt.KeyboardModifier.ShiftModifier); assert abs(e.position-.2)<.001
                e.transform_fields['left'].setValue(.1); e.set_property('crop_left'); assert abs(e.selected_clip()['crop']['left']-.1)<.001
                e.undo(); assert 'crop' not in e.selected_clip(); e.redo(); assert abs(e.selected_clip()['crop']['left']-.1)<.001
                e.flip_h.setChecked(True); assert e.selected_clip().get('flipH') is True; e.undo(); assert not e.selected_clip().get('flipH')
                e.background_blur.setChecked(True); assert e.selected_clip()['background']['type']=='blur'; e.undo(); assert 'background' not in e.selected_clip()
                from editing import apply_speed_ramp
                e.checkpoint(); apply_speed_ramp(e.project,e.selected_clip(),1,'Bullet'); e.changed(); assert len(e.project.clips)==3
                e.undo(); assert len(e.project.clips)==1; e.redo(); assert len(e.project.clips)==3; e.undo()
                e.seek(.5); e.freeze_frame(); assert abs(e.project.duration-3)<.01
                e.undo(); assert abs(e.project.duration-1)<.01; e.redo(); assert abs(e.project.duration-3)<.01
                e.undo(); e.select(c['id']); e.reverse_clip(); assert e.selected_clip()['reversed'] and e.selected_clip()['in']==0
                e.undo(); assert not e.selected_clip().get('reversed')
                e.undo(); c.update(start=0,duration=1); later=dict(c,id='later',start=2); e.project.clips.append(later); e.seek(.5)
                e.select_right_of_playhead(); assert e.selection=={'later'}
                e.nudge_selected(-1); assert abs(next(v for v in e.project.clips if v['id']=='later')['start']-(2-1/24))<.001
                e.undo(); assert abs(next(v for v in e.project.clips if v['id']=='later')['start']-2)<.001
                e.select('later'); e.close_gaps(); assert abs(next(v for v in e.project.clips if v['id']=='later')['start']-1)<.001
                e.undo(); later=next(v for v in e.project.clips if v['id']=='later'); e.select('later')
                rect=e.timeline.clip_rect(later); start=QPoint(int(rect.center().x()),int(rect.center().y()))
                QTest.mousePress(e.timeline,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.AltModifier,start)
                QTest.mouseMove(e.timeline,start+QPoint(36,0),50); QTest.mouseRelease(e.timeline,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.AltModifier,start+QPoint(36,0))
                assert len(e.project.clips)==3,'Alt-drag duplicate'; e.undo(); assert len(e.project.clips)==2
                print('PASS: markers, transform/freeze/reverse, nudge, right selection, close gaps, Alt-drag duplicate, undo/redo',flush=True)
            finally:shutil.rmtree(folder,ignore_errors=True)
        except Exception:
            failures.append(traceback.format_exc()); print(failures[-1],flush=True)
        finally:
            e.dirty=False; e.close(); QTest.qWait(100); qapp.quit()
    QTimer.singleShot(300,run)
    return original()

with patch.object(QApplication,'exec',execute): app.gui()
if failures: raise SystemExit(1)
