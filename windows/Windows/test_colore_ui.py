"""Offscreen integration coverage for the Windows Colore window."""
import json, os, shutil, subprocess, sys, tempfile, time, traceback
from pathlib import Path
from unittest.mock import patch
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QMainWindow
from PySide6.QtTest import QTest
from core import Project, tool
import app
import grading

original=QApplication.exec; failures=[]

def execute(qapp):
    def run():
        e=next(w for w in qapp.topLevelWidgets() if isinstance(w,QMainWindow)); messages=[]; e.error=messages.append
        td=Path(tempfile.mkdtemp(prefix='colore-ui-'))
        try:
            src=td/'src.mp4'
            subprocess.run([tool('ffmpeg'),'-y','-f','lavfi','-i','testsrc=size=320x180:rate=24','-t','2','-pix_fmt','yuv420p',str(src)],check=True,capture_output=True)
            p=Project(); p.settings.update(width=320,height=180,fps=24); m=p.add_media(src); a=p.add_clip(m['id']); a['duration']=1; b=p.add_clip(m['id'],0,1); b['duration']=1
            e.reset(p); e.select(a['id'])
            from color_grading import GradingWindow
            w=GradingWindow(e); e.grading_window=w; w.show()
            deadline=time.monotonic()+30
            while w.busy and time.monotonic()<deadline: QTest.qWait(50)
            assert w.tabs.count()==5 and [w.tabs.tabText(i) for i in range(5)]==['Automatico','Primarie','Curve','Curve HSL','LUT']
            assert w.scope.pixmap() and not w.scope.pixmap().isNull()
            scope=w.scope.pixmap().toImage(); colors={scope.pixel(x,y) for x in range(0,scope.width(),8) for y in range(0,scope.height(),8)}; assert len(colors)>1
            before=json.dumps(a.get('effects',{}).get('grade',{}),sort_keys=True)
            e.checkpoint(); w.wheel_changed(.4,.2,'lift'); assert json.dumps(a['effects']['grade'],sort_keys=True)!=before
            e.undo(); a=next(c for c in e.project.clips if c['id']==a['id']); b=next(c for c in e.project.clips if c['id']==b['id']); w.targets=[a,b]
            assert a.get('effects',{}).get('grade',{}).get('wheels',{}).get('lift',[0,0,0])==[0,0,0]
            w.targets=[a]
            w.state['curves']['master']=[]; w.curve_channel.setCurrentIndex(0); w.curve.points=[]; w.curve_changed([[.35,.6]])
            assert a['effects']['grade']['curves']['master']==[[.35,.6]]
            w.hue_channel.setCurrentIndex(0); w.hue_changed([[.4,.75]]); assert a['effects']['grade']['hue']['sat']
            cube=grading.cube(w.grade_for(a),td); w.set_lut('inputLut',{'path':str(cube),'amount':1}); assert a['effects']['grade']['inputLut']['path']==str(cube)
            w.focus=a; w.copy_grade(); b_before=json.dumps(b.get('effects',{}).get('grade'),sort_keys=True); w.targets=[b]; w.paste_grade(); assert b['effects']['grade']['inputLut']['path']==str(cube)
            e.undo(); a=next(c for c in e.project.clips if c['id']==a['id']); b=next(c for c in e.project.clips if c['id']==b['id']); assert json.dumps(b.get('effects',{}).get('grade'),sort_keys=True)==b_before
            w.targets=[a]; w.focus=a
            with patch('color_grading.QInputDialog.getText',return_value=('test preset',True)):
                w.save_preset()
            with patch('color_grading.QInputDialog.getItem',return_value=('test preset',True)):
                w.load_preset()
            assert (w.preset_dir()/'test preset.json').is_file()
            w.reset_section('Curve HSL'); assert not a['effects']['grade']['hue']
            assert all(w.tabs.widget(i) is not None for i in range(w.tabs.count()))
            assert not messages,messages
            print('PASS: Colore tabs, wheel/curve/HSL/LUT JSON, undo, copy/paste, preset save/load, scopes',flush=True)
            w.close()
        except Exception:
            failures.append(traceback.format_exc()); print(failures[-1],flush=True)
        finally:
            e.dirty=False; e.pending=False; e.close(); QTest.qWait(300); shutil.rmtree(td,ignore_errors=True); qapp.quit()
    QTimer.singleShot(400,run)
    return original()

with patch.object(QApplication,'exec',execute): app.gui()
if failures: sys.exit(1)
