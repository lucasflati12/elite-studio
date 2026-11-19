"""Actual Qt workflow for the lightweight editing additions."""
import os
import tempfile
import time
import traceback
from pathlib import Path
from unittest.mock import patch
from PySide6.QtCore import QTimer,Qt,QPoint
from PySide6.QtWidgets import QApplication,QMainWindow
from PySide6.QtTest import QTest
from core import Project
from test_windows import WindowsTests as Fixtures
import app

original=QApplication.exec; failures=[]


def execute(qapp):
    def run():
        e=next(w for w in qapp.topLevelWidgets() if isinstance(w,QMainWindow)); messages=[]; e.error=messages.append
        try:
            Fixtures.setUpClass()
            p=Project(); p.settings.update(width=320,height=180,fps=24)
            red=p.add_media(Fixtures.red); blue=p.add_media(Fixtures.blue)
            a=p.add_clip(red['id']); a['duration']=1
            b=p.add_clip(blue['id'],0,1); b['duration']=1
            p.settings.update(width=320,height=180,fps=24)
            e.reset(p); e.select(a['id']); e.inspector_tabs.setCurrentIndex(1)
            e.effect_fields['exposure'].setValue(-.5); e.edit_effect('exposure'); assert a['effects']['exposure']==-.5
            e.effect_fields['audioFadeIn'].setValue(.2); e.edit_effect('audioFadeIn')
            e.seek(0); e.add_motion_key(); e.seek(.8); e.fields['scale'].setValue(.5); e.set_property('scale')
            assert len(a['effects']['keys'])==2 and a['effects']['keys'][-1]['scale']==.5
            e.seek(.4); assert .5<e.fields['scale'].value()<1
            e.normalize_volume(); deadline=time.monotonic()+10
            while e.pending and time.monotonic()<deadline: QTest.qWait(50); time.sleep(.01)
            assert not e.pending and 0<a['volume']<=2
            e.select(b['id']); e.apply_crossfade(); assert b['track']==1 and b['start']<1
            e.add_track(); assert e.project.lanes==[0,1,3] and len(e.audio)==3
            assert e.track.count()==4 and e.track.itemText(3)=='V3 / A3'
            e.select(a['id']); e.set_track(3); assert a['track']==3
            assert e.timeline.track_at(e.timeline.clip_rect(a).center().y())==3
            e.bin_search.setText('blue'); assert sum(not e.bin.item(i).isHidden() for i in range(e.bin.count()))==1; e.bin_search.clear()
            e.start_proxies(); deadline=time.monotonic()+15
            while e.proxy_running and time.monotonic()<deadline: QTest.qWait(50); time.sleep(.01)
            assert not e.proxy_running and e.project.media[0].get('proxyPath')
            e.prepare_preview(); deadline=time.monotonic()+20
            while e.pending and time.monotonic()<deadline: QTest.qWait(50); time.sleep(.01)
            assert not e.pending and e.sequence_preview.valid, messages
            e.seek(.5); e.play(); QTest.qWait(400); e.pause()
            e.select(a['id']); e.effect_fields['contrast'].setValue(.9); e.edit_effect('contrast'); assert not e.sequence_preview.valid
            e.inspector_tabs.setCurrentIndex(1); QTest.qWait(120)
            e.grab().save(str(Path(tempfile.gettempdir())/'elite-essentials-ui.png'))
            e.auto_save()
            from storage import recovery_path
            assert recovery_path().is_file()
            e.add_text(); assert e.selected_clip()['title']['style']=='text'
            assert not messages,messages
            print('PASS: effects, keyframes, volume analysis, transition, added tracks, search, proxies, cached playback, recovery, free text',flush=True)
        except Exception:
            failures.append(traceback.format_exc()); print(failures[-1],flush=True)
        finally:
            e.dirty=False; e.pending=False; e.close(); QTest.qWait(100); Fixtures.tearDownClass(); qapp.quit()
    QTimer.singleShot(300,run)
    return original()


with patch.object(QApplication,'exec',execute): app.gui()
if failures: raise SystemExit(1)
