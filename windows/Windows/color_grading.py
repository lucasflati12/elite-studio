"""Colour grading window: analyses the clips, applies a look straight away, before/after compare."""
from __future__ import annotations
import copy
import json
import os
import shutil
import threading
from pathlib import Path

from PIL import Image
from PIL import ImageDraw
from PySide6.QtCore import Qt, QObject, QSize, Signal, QRectF, QPointF
from PySide6.QtGui import QColor, QFont, QIcon, QImage, QPainter, QPen, QPixmap, QPainterPath
from PySide6.QtWidgets import (QCheckBox, QDialog, QFileDialog, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QPushButton, QSlider, QVBoxLayout, QWidget, QComboBox, QInputDialog, QTabWidget, QScrollArea)
from PySide6.QtGui import QShortcut, QKeySequence

import grading

ORDER = ['natural', 'alpine', 'golden', 'moody', 'vivid', 'film', 'bw', 'none']
NAMES = {**{k: v['name'] for k, v in grading.LOOKS.items()}, 'none': 'Solo correzione'}


def to_pixmap(image):
    image = image.convert('RGBA'); raw = image.tobytes('raw', 'RGBA')
    return QPixmap.fromImage(QImage(raw, image.width, image.height, image.width * 4, QImage.Format.Format_RGBA8888).copy())


class Compare(QWidget):
    """Before | after, split by a line you can drag."""
    def __init__(self):
        super().__init__(); self.before = self.after = None; self.split = .5
        self.setMinimumSize(560, 315); self.setCursor(Qt.CursorShape.SplitHCursor)

    def set_images(self, before, after):
        self.before, self.after = before, after; self.update()

    def mousePressEvent(self, event): self.mouseMoveEvent(event)

    def mouseMoveEvent(self, event):
        r = self.target()
        if r.width() > 0: self.split = min(1, max(0, (event.position().x() - r.x()) / r.width())); self.update()

    def target(self):
        if not self.after: return QRectF()
        w, h = self.after.width(), self.after.height(); k = min(self.width() / w, self.height() / h)
        return QRectF((self.width() - w * k) / 2, (self.height() - h * k) / 2, w * k, h * k)

    def paintEvent(self, event):
        p = QPainter(self); p.fillRect(self.rect(), QColor('#050b12'))
        if not self.after:
            p.setPen(QColor('#8796a5')); p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, 'Analisi delle clip…'); return
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        r = self.target(); x = r.x() + r.width() * self.split
        p.drawPixmap(r, self.after, QRectF(self.after.rect()))
        if self.before:
            src = QRectF(0, 0, self.before.width() * self.split, self.before.height())
            p.drawPixmap(QRectF(r.x(), r.y(), r.width() * self.split, r.height()), self.before, src)
        p.setPen(QPen(QColor('#e4ca4a'), 2)); p.drawLine(int(x), int(r.top()), int(x), int(r.bottom()))
        p.setFont(QFont('Segoe UI', 9, QFont.Weight.Bold))
        for text, left in (('PRIMA', True), ('DOPO', False)):
            box = QRectF(r.x() + 10 if left else r.right() - 70, r.y() + 10, 60, 20)
            p.fillRect(box, QColor(0, 0, 0, 150)); p.setPen(QColor('#f2f2f2')); p.drawText(box, Qt.AlignmentFlag.AlignCenter, text)


class Wheel(QWidget):
    """Compact chroma puck; drag maps to a luma-neutral RGB balance."""
    began=Signal(); moved=Signal(float,float); reset=Signal()
    def __init__(self): super().__init__(); self.setFixedSize(104,104); self.xy=(0.,0.); self.drag=False
    def mousePressEvent(self,e):
        if e.button()==Qt.MouseButton.LeftButton:
            self.drag=True; self.began.emit(); self.mouseMoveEvent(e)
    def mouseMoveEvent(self,e):
        if self.drag:
            r=QRectF(8,8,self.width()-16,self.height()-16); x=(e.position().x()-r.center().x())/(r.width()/2); y=(r.center().y()-e.position().y())/(r.height()/2); d=max(1,(x*x+y*y)**.5); self.xy=(x/d*min(1,d),y/d*min(1,d)); self.moved.emit(*self.xy); self.update()
    def mouseReleaseEvent(self,e): self.drag=False
    def mouseDoubleClickEvent(self,e): self.xy=(0,0); self.reset.emit(); self.update()
    def paintEvent(self,e):
        p=QPainter(self); p.setRenderHint(QPainter.RenderHint.Antialiasing); r=QRectF(8,8,self.width()-16,self.height()-16); p.setBrush(QColor('#182431')); p.setPen(QPen(QColor('#9aa9b5'),1)); p.drawEllipse(r); p.drawLine(QPointF(r.center().x(),r.top()),QPointF(r.center().x(),r.bottom())); p.drawLine(QPointF(r.left(),r.center().y()),QPointF(r.right(),r.center().y())); p.setBrush(QColor('#e4ca4a')); p.drawEllipse(QPointF(r.center().x()+self.xy[0]*r.width()/2,r.center().y()-self.xy[1]*r.height()/2),5,5)


class CurveEditor(QWidget):
    changed=Signal(object)
    def __init__(self): super().__init__(); self.setMinimumSize(220,150); self.points=[]; self.selected=-1
    def pos(self,e): return ((e.position().x()-8)/(self.width()-16),1-(e.position().y()-8)/(self.height()-16))
    def mousePressEvent(self,e):
        x,y=self.pos(e); self.selected=min(range(len(self.points)),key=lambda i:(self.points[i][0]-x)**2+(self.points[i][1]-y)**2) if self.points else -1
        if self.selected<0 or sum((self.points[self.selected][0]-x)**2+(self.points[self.selected][1]-y)**2 for _ in [0])>.0025:
            self.points.append([x,y]); self.selected=len(self.points)-1; self.points.sort(); self.changed.emit(self.points)
        self.update()
    def mouseMoveEvent(self,e):
        if self.selected>=0:
            x,y=self.pos(e); self.points[self.selected]=[min(.99,max(.01,x)),min(1,max(0,y))]; self.points.sort(); self.selected=min(range(len(self.points)),key=lambda i:abs(self.points[i][0]-x)); self.changed.emit(self.points); self.update()
    def mouseDoubleClickEvent(self,e):
        if self.points:
            x,y=self.pos(e); i=min(range(len(self.points)),key=lambda j:(self.points[j][0]-x)**2+(self.points[j][1]-y)**2); self.points.pop(i); self.selected=-1; self.changed.emit(self.points); self.update()
    def paintEvent(self,e):
        p=QPainter(self); p.setRenderHint(QPainter.RenderHint.Antialiasing); r=QRectF(8,8,self.width()-16,self.height()-16); p.fillRect(r,QColor('#101923')); p.setPen(QPen(QColor('#425363'),1)); p.drawRect(r); p.setPen(QPen(QColor('#e4ca4a'),2)); pts=[[0,0],*sorted(self.points),[1,1]]; path=QPainterPath(); path.moveTo(r.left(),r.bottom());
        for x,y in pts[1:]: path.lineTo(r.left()+x*r.width(),r.bottom()-y*r.height())
        p.drawPath(path); p.setBrush(QColor('#e4ca4a'))
        for x,y in self.points:p.drawEllipse(QPointF(r.left()+x*r.width(),r.bottom()-y*r.height()),4,4)


class Bridge(QObject):
    progress = Signal(int, int, str)
    done = Signal(object)
    failed = Signal(str)


class GradingWindow(QDialog):
    def __init__(self, editor):
        super().__init__(editor); self.e = editor
        self.setWindowTitle('Colore'); self.resize(1120, 700); self.setModal(False)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.targets = self.pick_targets(); self.focus = None; self.source = None; self.busy = False
        cached = getattr(editor, 'grade_analysis', None)
        if cached is None: editor.grade_analysis = cached = {}
        self.analysis = cached
        first = next((c.get('effects', {}).get('grade') for c in self.targets if grading.active(c.get('effects', {}))), None)
        self.state = dict(look=first.get('look', grading.DEFAULT_LOOK), amount=float(first.get('amount', 1)), correct=bool(first.get('correct', True)),
                          match=bool(first.get('match', True)),
                          basic=copy.deepcopy(first.get('basic', grading.normalized({})['basic'])), wheels=copy.deepcopy(first.get('wheels', grading.normalized({})['wheels'])), curves=copy.deepcopy(first.get('curves',{})), hue=copy.deepcopy(first.get('hue',{})), inputLut=copy.deepcopy(first.get('inputLut',{})), creativeLut=copy.deepcopy(first.get('creativeLut',{}))) if first else dict(look=grading.DEFAULT_LOOK, amount=1., correct=True, match=True, basic=grading.normalized({})['basic'], wheels=grading.normalized({})['wheels'], curves={}, hue={}, inputLut={}, creativeLut={})

        root = QHBoxLayout(self)
        left = QVBoxLayout(); root.addLayout(left, 3)
        self.compare = Compare(); left.addWidget(self.compare, 1)
        self.info = QLabel(); self.info.setWordWrap(True); self.info.setStyleSheet('color:#8796a5'); left.addWidget(self.info)
        self.scope_kind=QComboBox(); self.scope_kind.addItems(['Waveform','RGB Parade','Vectorscope','Istogramma']); self.scope_kind.currentIndexChanged.connect(lambda _:self.refresh_preview()); left.addWidget(self.scope_kind)
        self.scope=QLabel(); self.scope.setFixedHeight(115); self.scope.setStyleSheet('background:#050b12'); left.addWidget(self.scope)
        self.looks = QListWidget(); self.looks.setViewMode(QListWidget.ViewMode.IconMode); self.looks.setIconSize(QSize(168, 95))
        self.looks.setFlow(QListWidget.Flow.LeftToRight); self.looks.setWrapping(False); self.looks.setFixedHeight(142)
        self.looks.setMovement(QListWidget.Movement.Static); self.looks.setSpacing(4)
        for k in ORDER:
            item = QListWidgetItem(NAMES[k]); item.setData(Qt.ItemDataRole.UserRole, k); item.setSizeHint(QSize(178, 128)); self.looks.addItem(item)
        self.looks.currentItemChanged.connect(self.look_chosen); left.addWidget(self.looks)

        panel = QWidget(); panel.setFixedWidth(300); right = QVBoxLayout(panel); right.setContentsMargins(0, 0, 0, 0); root.addWidget(panel)
        title = QLabel('COLORE'); title.setStyleSheet('color:#e4ca4a;font-weight:bold;font-size:13px'); right.addWidget(title)
        right.addWidget(QLabel('Clip coinvolte'))
        self.clips = QListWidget(); self.clips.currentItemChanged.connect(self.clip_focused); right.addWidget(self.clips, 1)
        self.correct = QCheckBox('Correzione automatica\n(livelli, bilanciamento, profilo D-Cinelike)'); self.correct.setChecked(self.state['correct'])
        self.match = QCheckBox('Uniforma le clip tra loro'); self.match.setChecked(self.state['match'])
        self.correct.toggled.connect(lambda v: self.set_state(correct=v)); self.match.toggled.connect(lambda v: self.set_state(match=v))
        right.addWidget(self.correct); right.addWidget(self.match)
        self.basic_sliders = {}
        for key, label, lo, hi, initial in [('temperature','Temperatura',-100,100,0),('tint','Tinta',-100,100,0),('exposure','Esposizione',-500,500,0),('contrast','Contrasto',0,200,100),('highlights','Luci',-100,100,0),('shadows','Ombre',-100,100,0),('whites','Bianchi',-100,100,0),('blacks','Neri',-100,100,0),('saturation','Saturazione',0,200,100),('vibrance','Vividezza',-100,100,0)]:
            right.addWidget(QLabel(label)); slider=QSlider(Qt.Orientation.Horizontal); slider.setRange(lo,hi)
            value=self.state['basic'].get(key,initial/100 if key not in ('contrast','saturation') else initial/100)
            slider.setValue(round(value*100)); slider.sliderReleased.connect(lambda k=key,s=slider:self.edit_basic(k,s.value()/100))
            right.addWidget(slider); self.basic_sliders[key]=slider
        self.wheel_name=QComboBox(); self.wheel_name.addItems(['lift','gamma','gain','offset']); right.addWidget(self.wheel_name)
        self.wheel=Wheel(); right.addWidget(self.wheel,0,Qt.AlignmentFlag.AlignHCenter)
        self.wheel.began.connect(self.e.checkpoint); self.wheel.moved.connect(self.wheel_changed); self.wheel.reset.connect(self.wheel_reset)
        self.curve_channel=QComboBox(); self.curve_channel.addItems(['master','r','g','b']); right.addWidget(self.curve_channel)
        self.curve=CurveEditor(); right.addWidget(self.curve); self.curve.changed.connect(self.curve_changed)
        self.amount_label = QLabel(); right.addWidget(self.amount_label)
        self.amount = QSlider(Qt.Orientation.Horizontal); self.amount.setRange(0, 150); self.amount.setValue(round(self.state['amount'] * 100))
        self.amount.valueChanged.connect(self.amount_moving); self.amount.sliderReleased.connect(lambda: self.set_state(amount=self.amount.value() / 100))
        right.addWidget(self.amount)
        for text, fn in (('Applica di nuovo / rianalizza', self.reanalyse), ('Esporta LUT .cube (DaVinci)…', self.export_cube),
                         ('Rimuovi grading', self.remove), ('Chiudi', self.close)):
            b = QPushButton(text); b.clicked.connect(fn); right.addWidget(b)
        self.bypass=QCheckBox('Confronto senza grading'); self.bypass.toggled.connect(lambda _:self.refresh_preview()); right.addWidget(self.bypass)
        self.tabs=QTabWidget();
        # Keep the complete control column reachable on laptop screens.
        scroll=QScrollArea(); scroll.setWidgetResizable(True); scroll.setWidget(panel); self.tabs.addTab(scroll,'Automatico / Primarie / Curve');
        root.removeWidget(panel); root.addWidget(self.tabs,1)
        for text,fn in (('Salva preset',self.save_preset),('Carica preset',self.load_preset),('Elimina preset',self.delete_preset),('Applica a tutte le clip',self.apply_all),('Applica alla traccia',self.apply_track)):
            b=QPushButton(text); right.addWidget(b); b.clicked.connect(fn)
        self.short_copy=QShortcut(QKeySequence('Ctrl+Shift+C'),self); self.short_copy.activated.connect(self.copy_grade)
        self.short_paste=QShortcut(QKeySequence('Ctrl+Shift+V'),self); self.short_paste.activated.connect(self.paste_grade)
        self.amount_moving(self.amount.value())
        self.fill_clips(); self.select_look(self.state['look'])
        self.start_analysis(apply_after=True)

    # ----- targets -----
    def pick_targets(self):
        p = self.e.project; chosen = [c for c in p.clips if c['id'] in (self.e.selection or set())]
        usable = lambda c: 'title' not in c and p.item(c) and p.item(c).get('hasVideo', True)
        chosen = [c for c in chosen if usable(c)]
        return sorted(chosen or [c for c in p.clips if usable(c)], key=lambda c: (c['start'], c['track']))

    def media(self, c): return self.e.project.item(c)

    def fill_clips(self):
        self.clips.blockSignals(True); self.clips.clear()
        for c in self.targets:
            m = self.media(c); a = self.analysis.get(m['path'])
            note = 'in analisi…' if a is None else ('D-Cinelike/flat' if a.get('flat') else 'standard')
            item = QListWidgetItem(f"{m['name']}  ·  {note}"); item.setData(Qt.ItemDataRole.UserRole, c['id']); self.clips.addItem(item)
        self.clips.blockSignals(False)
        if self.clips.count(): self.clips.setCurrentRow(0)

    def clip_focused(self, item, _=None):
        if not item: return
        self.focus = next((c for c in self.targets if c['id'] == item.data(Qt.ItemDataRole.UserRole)), None); self.source = None
        self.refresh_preview(thumbnails=True)

    # ----- analysis -----
    def start_analysis(self, apply_after=False, force=False):
        todo = [m for m in {self.media(c)['path']: self.media(c) for c in self.targets}.values() if force or m['path'] not in self.analysis]
        if not self.targets:
            self.info.setText('Nessuna clip video nella timeline: importa le clip e riapri questa finestra.'); return
        if not todo:
            if apply_after and not any(grading.active(c.get('effects', {})) for c in self.targets): self.apply()
            self.refresh_preview(thumbnails=True); return
        self.busy = True; bridge = Bridge(self); self.bridge = bridge
        bridge.progress.connect(lambda i, n, name: self.info.setText(f'Analisi {i}/{n}: {name}…'))
        bridge.failed.connect(lambda text: (setattr(self, 'busy', False), self.info.setText('Analisi non riuscita: ' + text)))
        def finished(results):
            self.busy = False; self.analysis.update(results); self.fill_clips()
            if apply_after and not any(grading.active(c.get('effects', {})) for c in self.targets): self.apply()
            elif force: self.apply()
            self.refresh_preview(thumbnails=True)
        bridge.done.connect(finished)
        def work():
            out = {}
            try:
                for i, m in enumerate(todo, 1):
                    bridge.progress.emit(i, len(todo), m['name'])
                    out[m['path']] = grading.analyze(m['path'], still=bool(m.get('still')))
                bridge.done.emit(out)
            except Exception as ex: bridge.failed.emit(str(ex))
        threading.Thread(target=work, daemon=True).start()

    def reanalyse(self): self.start_analysis(force=True)

    # ----- grade values -----
    def autos(self):
        paths = [self.media(c)['path'] for c in self.targets]
        unique = list(dict.fromkeys(p for p in paths if p in self.analysis))
        values = [self.analysis[p] for p in unique]
        if self.state['match']: values = grading.match(values)
        return dict(zip(unique, values))

    def grade_for(self, c, autos=None, **override):
        s = {**self.state, **override}; autos = autos if autos is not None else self.autos()
        auto = autos.get(self.media(c)['path'], grading.NEUTRAL_AUTO)
        return dict(look=s['look'], amount=round(s['amount'], 3), correct=s['correct'], match=s['match'], auto=copy.deepcopy(auto), basic=copy.deepcopy(s['basic']), wheels=copy.deepcopy(s['wheels']), curves=copy.deepcopy(s.get('curves',{})), hue=copy.deepcopy(s.get('hue',{})), inputLut=copy.deepcopy(s.get('inputLut',{})), creativeLut=copy.deepcopy(s.get('creativeLut',{})))

    def edit_basic(self, key, value):
        basic=copy.deepcopy(self.state['basic']); basic[key]=value
        self.set_state(basic=basic)

    def wheel_changed(self,x,y):
        k=self.wheel_name.currentText(); wheels=copy.deepcopy(self.state['wheels']); wheels[k]=[round(.25*x,4),round(.25*y,4),round(-.25*(.2126*x+.7152*y)/.0722,4)]; self.state['wheels']=wheels; self.apply(checkpoint=False)
    def wheel_reset(self):
        wheels=copy.deepcopy(self.state['wheels']); wheels[self.wheel_name.currentText()]=[0,0,0]; self.state['wheels']=wheels; self.apply(checkpoint=False)
    def curve_changed(self,points):
        curves=copy.deepcopy(self.state.get('curves',{})); curves[self.curve_channel.currentText()]=copy.deepcopy(points); self.state['curves']=curves; self.apply(checkpoint=False)

    def apply(self, checkpoint=True):
        if not self.targets: return
        autos = self.autos()
        if checkpoint:self.e.checkpoint()
        for c in self.targets: c.setdefault('effects', {})['grade'] = self.grade_for(c, autos)
        self.e.changed(); self.refresh_preview(thumbnails=True)
        name = NAMES[self.state['look']]
        self.info.setText(f"Applicato «{name}» al {round(self.state['amount'] * 100)}% su {len(self.targets)} clip. "
                          'Trascina la linea gialla per confrontare. Ctrl+Z annulla. L’export usa la stessa LUT.')

    def copy_grade(self):
        if not self.focus:return
        self._grade_clipboard=copy.deepcopy(self.focus.get('effects',{}).get('grade',self.grade_for(self.focus)))
    def paste_grade(self):
        grade=getattr(self,'_grade_clipboard',None)
        if not grade:return
        self.e.checkpoint()
        for c in self.targets:
            g=copy.deepcopy(grade); g['auto']=copy.deepcopy(c.get('effects',{}).get('grade',{}).get('auto',g.get('auto',grading.NEUTRAL_AUTO))); c.setdefault('effects',{})['grade']=g
        self.e.changed(); self.refresh_preview(thumbnails=True)
    def apply_all(self):
        self.targets=[c for c in self.e.project.clips if 'title' not in c and self.e.project.item(c) and self.e.project.item(c).get('hasVideo',True)]; self.apply()
    def apply_track(self):
        if not self.focus:return
        track=self.focus['track']; self.targets=[c for c in self.e.project.clips if c['track']==track and 'title' not in c and self.e.project.item(c) and self.e.project.item(c).get('hasVideo',True)]; self.apply()
    def preset_dir(self):
        p=Path(os.environ.get('LOCALAPPDATA',Path.home()))/'EliteStudioWindows'/'grades'; p.mkdir(parents=True,exist_ok=True); return p
    def save_preset(self):
        name,ok=QInputDialog.getText(self,'Preset grading','Nome preset:')
        if ok and name:
            g=self.grade_for(self.focus or self.targets[0]); g.pop('auto',None); (self.preset_dir()/(name+'.json')).write_text(json.dumps(g,ensure_ascii=False,indent=2),encoding='utf-8')
    def load_preset(self):
        files=list(self.preset_dir().glob('*.json'))
        if not files:return
        name,ok=QInputDialog.getItem(self,'Carica preset','Preset:',[p.stem for p in files],0,False)
        if ok:
            g=json.loads((self.preset_dir()/(name+'.json')).read_text(encoding='utf-8')); g['auto']=copy.deepcopy((self.focus or self.targets[0]).get('effects',{}).get('grade',{}).get('auto',grading.NEUTRAL_AUTO)); self.state.update({k:g[k] for k in ('look','amount','correct','basic','wheels','curves','hue','inputLut','creativeLut') if k in g}); self.apply()
    def delete_preset(self):
        files=list(self.preset_dir().glob('*.json'))
        if files:
            name,ok=QInputDialog.getItem(self,'Elimina preset','Preset:',[p.stem for p in files],0,False)
            if ok:(self.preset_dir()/(name+'.json')).unlink(missing_ok=True)

    def set_state(self, **kw):
        changed = any(self.state.get(k) != v for k, v in kw.items()); self.state.update(kw)
        if changed and not self.busy: self.apply()

    def amount_moving(self, value):
        self.amount_label.setText(f'Intensità look: {value}%')
        if self.amount.isSliderDown(): self.refresh_preview(amount=value / 100)

    def select_look(self, k):
        for i in range(self.looks.count()):
            if self.looks.item(i).data(Qt.ItemDataRole.UserRole) == k:
                self.looks.blockSignals(True); self.looks.setCurrentRow(i); self.looks.blockSignals(False)

    def look_chosen(self, item, _=None):
        if item: self.set_state(look=item.data(Qt.ItemDataRole.UserRole))

    def remove(self):
        self.e.checkpoint()
        for c in self.targets: c.get('effects', {}).pop('grade', None)
        self.e.changed(); self.info.setText('Grading rimosso dalle clip (Ctrl+Z per ripristinarlo).'); self.refresh_preview()

    def export_cube(self):
        c = self.focus or (self.targets[0] if self.targets else None)
        if not c: return
        m = self.media(c); suggested = str(Path(m['path']).with_name(Path(m['path']).stem + f"_{self.state['look']}.cube"))
        path, _ = QFileDialog.getSaveFileName(self, 'Esporta LUT', suggested, 'LUT 3D (*.cube)')
        if path: shutil.copyfile(grading.cube(self.grade_for(c)), path); self.info.setText(f'LUT salvata: {path}  (DaVinci: Color › LUTs › tasto destro › Apply LUT)')

    # ----- preview -----
    def frame(self):
        if self.source is not None or not self.focus: return self.source
        c = self.focus; m = self.media(c); pos = self.e.position
        local = pos - c['start'] if c['start'] <= pos < c['start'] + c['duration'] else c['duration'] / 2
        image = self.e.frame(m, c.get('in', 0) + local * c.get('speed', 1), c.get('pano', {}) if m.get('pano') or 'pano' in c else None, (960, 540))
        if image is None: return None
        image = image.convert('RGBA'); image.thumbnail((960, 540), Image.Resampling.BILINEAR); self.source = image; return image

    def refresh_preview(self, thumbnails=False, amount=None):
        src = self.frame()
        if src is None or not self.focus: return
        if self.focus['media'] and self.media(self.focus)['path'] not in self.analysis and self.busy: return
        grade = self.grade_for(self.focus, **({} if amount is None else dict(amount=amount)))
        removed = not grading.active(self.focus.get('effects', {}))
        graded=src if removed or self.bypass.isChecked() else grading.pil(src, grade)
        self.compare.set_images(to_pixmap(src), to_pixmap(graded)); self.update_scope(graded)
        if thumbnails:
            small = src.copy(); small.thumbnail((336, 190), Image.Resampling.BILINEAR)
            for i in range(self.looks.count()):
                item = self.looks.item(i); k = item.data(Qt.ItemDataRole.UserRole)
                item.setIcon(QIcon(to_pixmap(grading.pil(small, self.grade_for(self.focus, look=k, amount=1)))))

    def update_scope(self,image):
        im=image.convert('RGB').resize((256,112)); px=list(im.getdata()); canvas=Image.new('RGB',(256,112),(5,11,18)); d=ImageDraw.Draw(canvas); kind=self.scope_kind.currentText()
        if kind=='Istogramma':
            for c,col in enumerate(('#e66','#6d8','#69f')):
                hist=[0]*256
                for q in px:hist[q[c]]+=1
                peak=max(hist) or 1
                d.line([(x,110-int(hist[x]*100/peak)) for x in range(256)],fill=col)
        elif kind=='RGB Parade':
            for c,col in enumerate(('#e66','#6d8','#69f')):
                x0=c*85
                for x in range(x0,x0+84):
                    vals=[q[c] for q in px[(x-x0)::84]]
                    if vals:
                        for v in vals[::4]:d.point((x,110-int(v*108/255)),fill=col)
        elif kind=='Vectorscope':
            d.ellipse((72,0,184,112),outline='#617080')
            for r,g,b in px[::12]:
                yy=.2126*r+.7152*g+.0722*b; xx=(r-b)*.45; y=(g-yy)*.7
                d.point((128+int(xx*.35),56-int(y*.35)),fill=(r,g,b))
        else:
            for x in range(256):
                vals=[q[0]*.2126+q[1]*.7152+q[2]*.0722 for q in px[x::256]]
                for v in vals[::2]:d.point((x,110-int(v*108/255)),fill='#d7cf79')
        self.scope.setPixmap(to_pixmap(canvas))


def open_window(editor):
    old = getattr(editor, 'grading_window', None)
    try:
        if old is not None and old.isVisible(): old.close()
    except RuntimeError: pass
    editor.pause(); editor.grading_window = GradingWindow(editor); editor.grading_window.show()
