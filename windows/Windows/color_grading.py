"""Colour grading window: analyses the clips, applies a look straight away, before/after compare."""
from __future__ import annotations
import copy
import shutil
import threading
from pathlib import Path

from PIL import Image
from PySide6.QtCore import Qt, QObject, QSize, Signal, QRectF
from PySide6.QtGui import QColor, QFont, QIcon, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QCheckBox, QDialog, QFileDialog, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QPushButton, QSlider, QVBoxLayout, QWidget)

import grading

ORDER = ['alpine', 'golden', 'moody', 'vivid', 'film', 'bw', 'none']
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


class Bridge(QObject):
    progress = Signal(int, int, str)
    done = Signal(object)
    failed = Signal(str)


class GradingWindow(QDialog):
    def __init__(self, editor):
        super().__init__(editor); self.e = editor
        self.setWindowTitle('Color grading automatico'); self.resize(1120, 700); self.setModal(False)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.targets = self.pick_targets(); self.focus = None; self.source = None; self.busy = False
        cached = getattr(editor, 'grade_analysis', None)
        if cached is None: editor.grade_analysis = cached = {}
        self.analysis = cached
        first = next((c.get('effects', {}).get('grade') for c in self.targets if grading.active(c.get('effects', {}))), None)
        self.state = dict(look=first.get('look', grading.DEFAULT_LOOK), amount=float(first.get('amount', 1)), correct=bool(first.get('correct', True)),
                          match=bool(first.get('match', True))) if first else dict(look=grading.DEFAULT_LOOK, amount=1., correct=True, match=True)

        root = QHBoxLayout(self)
        left = QVBoxLayout(); root.addLayout(left, 3)
        self.compare = Compare(); left.addWidget(self.compare, 1)
        self.info = QLabel(); self.info.setWordWrap(True); self.info.setStyleSheet('color:#8796a5'); left.addWidget(self.info)
        self.looks = QListWidget(); self.looks.setViewMode(QListWidget.ViewMode.IconMode); self.looks.setIconSize(QSize(168, 95))
        self.looks.setFlow(QListWidget.Flow.LeftToRight); self.looks.setWrapping(False); self.looks.setFixedHeight(142)
        self.looks.setMovement(QListWidget.Movement.Static); self.looks.setSpacing(4)
        for k in ORDER:
            item = QListWidgetItem(NAMES[k]); item.setData(Qt.ItemDataRole.UserRole, k); item.setSizeHint(QSize(178, 128)); self.looks.addItem(item)
        self.looks.currentItemChanged.connect(self.look_chosen); left.addWidget(self.looks)

        panel = QWidget(); panel.setFixedWidth(300); right = QVBoxLayout(panel); right.setContentsMargins(0, 0, 0, 0); root.addWidget(panel)
        title = QLabel('COLOR GRADING'); title.setStyleSheet('color:#e4ca4a;font-weight:bold;font-size:13px'); right.addWidget(title)
        right.addWidget(QLabel('Clip coinvolte'))
        self.clips = QListWidget(); self.clips.currentItemChanged.connect(self.clip_focused); right.addWidget(self.clips, 1)
        self.correct = QCheckBox('Correzione automatica\n(livelli, bilanciamento, profilo D-Cinelike)'); self.correct.setChecked(self.state['correct'])
        self.match = QCheckBox('Uniforma le clip tra loro'); self.match.setChecked(self.state['match'])
        self.correct.toggled.connect(lambda v: self.set_state(correct=v)); self.match.toggled.connect(lambda v: self.set_state(match=v))
        right.addWidget(self.correct); right.addWidget(self.match)
        self.amount_label = QLabel(); right.addWidget(self.amount_label)
        self.amount = QSlider(Qt.Orientation.Horizontal); self.amount.setRange(0, 150); self.amount.setValue(round(self.state['amount'] * 100))
        self.amount.valueChanged.connect(self.amount_moving); self.amount.sliderReleased.connect(lambda: self.set_state(amount=self.amount.value() / 100))
        right.addWidget(self.amount)
        for text, fn in (('Applica di nuovo / rianalizza', self.reanalyse), ('Esporta LUT .cube (DaVinci)…', self.export_cube),
                         ('Rimuovi grading', self.remove), ('Chiudi', self.close)):
            b = QPushButton(text); b.clicked.connect(fn); right.addWidget(b)
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
        return dict(look=s['look'], amount=round(s['amount'], 3), correct=s['correct'], match=s['match'], auto=copy.deepcopy(auto))

    def apply(self):
        if not self.targets: return
        autos = self.autos(); self.e.checkpoint()
        for c in self.targets: c.setdefault('effects', {})['grade'] = self.grade_for(c, autos)
        self.e.changed(); self.refresh_preview(thumbnails=True)
        name = NAMES[self.state['look']]
        self.info.setText(f"Applicato «{name}» al {round(self.state['amount'] * 100)}% su {len(self.targets)} clip. "
                          'Trascina la linea gialla per confrontare. Ctrl+Z annulla. L’export usa la stessa LUT.')

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
        self.compare.set_images(to_pixmap(src), to_pixmap(src if removed else grading.pil(src, grade)))
        if thumbnails:
            small = src.copy(); small.thumbnail((336, 190), Image.Resampling.BILINEAR)
            for i in range(self.looks.count()):
                item = self.looks.item(i); k = item.data(Qt.ItemDataRole.UserRole)
                item.setIcon(QIcon(to_pixmap(grading.pil(small, self.grade_for(self.focus, look=k, amount=1)))))


def open_window(editor):
    old = getattr(editor, 'grading_window', None)
    try:
        if old is not None and old.isVisible(): old.close()
    except RuntimeError: pass
    editor.pause(); editor.grading_window = GradingWindow(editor); editor.grading_window.show()
