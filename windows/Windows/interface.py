"""Mac-inspired navy and gold UI for the Windows editor."""
from __future__ import annotations
import math
import subprocess
import threading
from pathlib import Path
import cv2
import numpy as np
from PySide6.QtCore import Qt, QObject, Signal, QSize, QPointF, QRectF
from PySide6.QtGui import QColor, QPainter, QPen, QIcon, QPixmap, QImage, QPolygonF, QFont, QAction, QKeySequence
from PySide6.QtWidgets import (QWidget,QVBoxLayout,QHBoxLayout,QFormLayout,QLabel,QPushButton,QToolButton,
    QComboBox,QCheckBox,QDoubleSpinBox,QScrollArea,QSplitter,QSlider,QSizePolicy,QAbstractSpinBox,QLayout)
from core import tool, CREATE_FLAGS

GOLD='#e4ca4a'
NAVY='#0b1826'
STYLE='''
QWidget { color:#dce4ec; background:#0b1826; font-family:"Segoe UI"; font-size:11px; }
QMainWindow { background:#081420; }
QMenuBar { background:#09131e; padding:1px 7px; spacing:15px; font-size:11px; }
QMenuBar::item { padding:4px 5px; } QMenuBar::item:selected,QMenu::item:selected { background:#23364a; }
QMenu { border:1px solid #263849; padding:5px; } QMenu::item { padding:6px 24px 6px 10px; }
QLabel { background:transparent; }
QLabel[section="true"] { color:#e4ca4a; font-size:10px; font-weight:700; letter-spacing:2px; padding-top:8px; padding-bottom:5px; }
QLabel[muted="true"] { color:#82909e; font-size:10px; }
QLabel#currentTime { color:#e4ca4a; font-weight:700; font-size:11px; }
QLabel#totalTime { color:#8e9ba8; font-size:11px; }
QWidget#timelineBar { border-top:1px solid #172b3d; border-bottom:1px solid #172b3d; }
QToolButton { color:#e4ca4a; background:transparent; border:0; border-radius:3px; padding:3px 5px; }
QToolButton:hover { background:#203345; } QToolButton:checked { background:#e4ca4a; color:#14202a; }
QToolButton[transport="true"] { padding:3px; } QToolButton[transport="true"]:hover { background:#1b2b39; }
QPushButton { background:#243649; border:1px solid #33465a; border-radius:3px; padding:4px 7px; }
QPushButton:hover { background:#344c62; }
QLineEdit,QDoubleSpinBox,QSpinBox,QComboBox { background:#394451; border:1px solid #495562; border-radius:3px; padding:2px 5px; min-height:17px; selection-background-color:#8e8037; }
QDoubleSpinBox { padding-right:13px; } QDoubleSpinBox::up-button,QDoubleSpinBox::down-button { width:13px; background:#6f6b3b; border:0; }
QComboBox::drop-down { border:0; width:15px; background:#8c803b; border-radius:2px; }
QComboBox QAbstractItemView { background:#1b2d3e; selection-background-color:#4b5360; }
QCheckBox { spacing:5px; font-size:11px; color:#a8b4c1; background:transparent; }
QCheckBox::indicator { width:12px; height:12px; background:#283747; border-radius:2px; border:1px solid #334657; }
QCheckBox::indicator:checked { background:#d7bd42; border:1px solid #ebd866; image:none; }
QSlider::groove:horizontal { height:3px; background:#2c3c4a; border-radius:1px; }
QSlider::sub-page:horizontal { background:#d8bf40; border-radius:1px; }
QSlider::handle:horizontal { width:12px; margin:-5px 0; background:#8895a2; border-radius:6px; }
QListWidget { border:0; outline:0; background:#0b1826; }
QListWidget::item { padding:5px 0; border:0; border-radius:3px; }
QListWidget::item:selected { background:#192f43; } QListWidget::item:hover { background:#142639; }
QScrollArea { border:0; } QScrollBar:vertical { background:#0b1826; width:7px; margin:0; }
QScrollBar::handle:vertical { background:#344253; border-radius:3px; min-height:25px; }
QScrollBar:horizontal { background:#08131e; height:7px; margin:0; }
QScrollBar::handle:horizontal { background:#3c4854; border-radius:3px; min-width:30px; }
QScrollBar::add-line,QScrollBar::sub-line { width:0; height:0; }
QScrollBar::add-page,QScrollBar::sub-page { background:none; }
QSplitter::handle { background:#152a3c; width:1px; height:2px; }
QStatusBar { background:#0b1826; color:#80909f; border:0; font-size:10px; min-height:17px; }
QToolTip { color:#e0e5eb; background:#24374a; border:1px solid #4a5e70; padding:4px; }
'''


def icon(name,color=GOLD,size=18):
    pix=QPixmap(size,size); pix.fill(Qt.GlobalColor.transparent)
    p=QPainter(pix); p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.scale(size/20,size/20); p.setPen(QPen(QColor(color),1.5)); p.setBrush(QColor(color))
    triangle=lambda pts:p.drawPolygon(QPolygonF([QPointF(*v) for v in pts]))
    if name in ('play','next','end'):
        triangle([(6,4),(15,10),(6,16)])
        if name in ('next','end'): p.drawLine(16,4,16,16)
        if name=='end': p.drawLine(3,4,3,16)
    elif name in ('previous','start'):
        triangle([(14,4),(5,10),(14,16)]); p.drawLine(3,4,3,16)
        if name=='start': p.drawLine(17,4,17,16)
    elif name=='pause': p.drawRect(6,4,2,12); p.drawRect(12,4,2,12)
    elif name=='select':
        p.setBrush(Qt.BrushStyle.NoBrush); p.drawPolyline(QPolygonF([QPointF(5,16),QPointF(5,4),QPointF(16,11),QPointF(10,11),QPointF(13,16)]))
    elif name in ('razor','cut'):
        p.setBrush(Qt.BrushStyle.NoBrush); p.drawEllipse(QPointF(5,5),2.5,2.5); p.drawEllipse(QPointF(5,15),2.5,2.5)
        p.drawLine(7,7,16,15); p.drawLine(7,13,16,5)
    elif name=='plus': p.drawLine(10,4,10,16); p.drawLine(4,10,16,10)
    elif name=='fit': p.drawLine(3,10,17,10); p.drawLine(3,10,6,7); p.drawLine(3,10,6,13); p.drawLine(17,10,14,7); p.drawLine(17,10,14,13)
    elif name=='zoom':
        p.setBrush(Qt.BrushStyle.NoBrush); p.drawEllipse(QPointF(8,8),4,4); p.drawLine(11,11,16,16)
    elif name=='eye':
        p.setBrush(Qt.BrushStyle.NoBrush); p.drawEllipse(QRectF(3,6,14,8)); p.setBrush(QColor(color)); p.drawEllipse(QPointF(10,10),2,2)
    elif name=='speaker':
        triangle([(4,8),(7,8),(11,4),(11,16),(7,12),(4,12)]); p.setBrush(Qt.BrushStyle.NoBrush); p.drawArc(8,4,9,12,-70*16,140*16)
    elif name=='missing': triangle([(10,3),(18,17),(2,17)]); p.setPen(QPen(QColor(NAVY),2)); p.drawLine(10,7,10,11); p.drawPoint(10,14)
    elif name=='remove':
        p.setBrush(Qt.BrushStyle.NoBrush); p.drawRoundedRect(3,5,14,10,2,2); p.drawLine(7,8,13,12); p.drawLine(13,8,7,12)
    p.end(); return QIcon(pix)


def section(text):
    label=QLabel(text); label.setProperty('section',True); return label


def muted(text=''):
    label=QLabel(text); label.setProperty('muted',True); label.setWordWrap(True); return label


def button(name,callback,text='',tip='',checkable=False):
    b=QToolButton(); b.setText(text); b.setIcon(icon(name) if name else QIcon()); b.setIconSize(QSize(15,15))
    if text: b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
    b.setCheckable(checkable); b.setToolTip(tip or text); b.clicked.connect(callback); return b


class MediaVisuals(QObject):
    ready=Signal(str,object,object)
    def __init__(self,parent=None):
        super().__init__(parent); self.frames={}; self.peaks={}; self.pending=set(); self.workers=[]; self.stop=threading.Event(); self.suspended=threading.Event(); self.limit=threading.Semaphore(2); self.processes=[]
        self.ready.connect(self.deliver)
    def deliver(self,mid,frames,peaks):
        self.frames[mid]=frames; self.peaks[mid]=peaks; self.pending.discard(mid)
    def request(self,m):
        mid=m['id']
        if mid in self.frames or mid in self.pending or not Path(m['path']).is_file(): return
        self.pending.add(mid)
        def run():
            frames=[]; peaks=None
            with self.limit:
                if self.stop.is_set(): return
                while self.suspended.is_set() and not self.stop.is_set(): self.stop.wait(.05)
                try:
                    if m.get('hasVideo',True):
                        cap=cv2.VideoCapture(m['path'])
                        try:
                            for t in np.linspace(0,max(0,m.get('duration',0)-.12),12):
                                if self.stop.is_set(): return
                                while self.suspended.is_set() and not self.stop.is_set(): self.stop.wait(.05)
                                cap.set(cv2.CAP_PROP_POS_MSEC,float(t)*1000); ok,bgr=cap.read()
                                if ok:
                                    h,w=bgr.shape[:2]; bgr=cv2.resize(bgr,(max(1,round(w*60/h)),60))
                                    rgb=cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB)
                                    frames.append((float(t),QImage(rgb.data,rgb.shape[1],rgb.shape[0],rgb.strides[0],QImage.Format.Format_RGB888).copy()))
                        finally: cap.release()
                    if m.get('hasAudio') and not self.stop.is_set():
                        proc=subprocess.Popen([tool('ffmpeg'),'-v','error','-i',m['path'],'-vn','-ac','1','-ar','1000','-f','f32le','pipe:1'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=CREATE_FLAGS)
                        self.processes.append(proc)
                        try: data,_=proc.communicate(timeout=90)
                        finally:
                            if proc.poll() is None: proc.kill(); proc.communicate()
                            self.processes.remove(proc)
                        sound=np.abs(np.frombuffer(data,dtype='<f4')); count=len(sound)//10
                        if count:
                            peaks=sound[:count*10].reshape(count,10).max(axis=1)
                            peaks=np.sqrt(peaks/max(.05,float(peaks.max())))
                except Exception: pass
            if not self.stop.is_set(): self.ready.emit(mid,frames,peaks)
        worker=threading.Thread(target=run,daemon=True); self.workers.append(worker); worker.start()
    def close(self):
        self.stop.set()
        for proc in self.processes[:]:
            try: proc.kill()
            except OSError: pass
        for worker in self.workers:
            if worker.is_alive(): worker.join(timeout=.5)


def build_ui(editor,Viewer,Bin,Timeline):
    e=editor
    def action(name,fn,shortcut=None,menu=None):
        a=QAction(name,e); a.triggered.connect(fn)
        if shortcut: a.setShortcut(QKeySequence(shortcut))
        if menu: menu.addAction(a)
        return a
    file=e.menuBar().addMenu('File')
    for name,fn,key in [('Nuovo progetto',e.new_project,'Ctrl+N'),('Apri progetto…',e.open_dialog,'Ctrl+O'),('Salva',e.save,'Ctrl+S'),('Salva con nome…',e.save_as,'Ctrl+Shift+S'),('Importa media…',e.import_dialog,'Ctrl+I'),('Ricollega file mancanti…',e.relink,None),('Esporta MP4…',e.export_dialog,'Ctrl+E')]: action(name,fn,key,file)
    edit=e.menuBar().addMenu('Modifica')
    for name,fn,key in [('Annulla',e.undo,'Ctrl+Z'),('Ripeti',e.redo,'Ctrl+Shift+Z'),('Copia',e.copy_clip,'Ctrl+C'),('Incolla',e.paste_clip,'Ctrl+V'),('Seleziona tutto',e.select_all,'Ctrl+A')]: action(name,fn,key,edit)
    view=e.menuBar().addMenu('Vista'); action('Adatta timeline',e.fit,'\\',view)
    sequence_menu=e.menuBar().addMenu('Sequenza'); action('Taglia al cursore',e.cut,'Ctrl+K',sequence_menu); action('Aggiungi titolo',e.add_title,'Ctrl+T',sequence_menu)
    action('Elimina e chiudi',lambda:e.delete(True),None,sequence_menu)
    action('Rifila inizio fino al cursore · Q',lambda:e.ripple_trim(True),None,sequence_menu)
    action('Rifila fine dal cursore · W',lambda:e.ripple_trim(False),None,sequence_menu)
    action('Genera sottotitoli automatici',e.generate_captions,None,sequence_menu)
    action('Aggiungi sottotitolo',e.add_caption,None,sequence_menu)
    action('Aggiungi testo libero',e.add_text,None,sequence_menu)
    action('Dissolvenza incrociata con precedente',e.apply_crossfade,None,sequence_menu)
    action('Regola automaticamente il volume',e.normalize_volume,None,sequence_menu)
    action('Aggiungi traccia video/audio',e.add_track,None,sequence_menu)
    action('Recupera sessione interrotta',e.recover_session,None,file)
    action('Apri versione precedente come copia',e.restore_version,None,file)
    performance=e.menuBar().addMenu('Fluidità')
    action('Crea proxy delle clip selezionate',e.start_proxies,None,performance)
    action('Interrompi preparazione proxy',e.cancel_proxies,None,performance)
    action('Prepara anteprima fluida',e.prepare_preview,None,performance)
    action('Pulisci cache delle anteprime',e.clear_cache,None,performance)
    help_menu=e.menuBar().addMenu('Aiuto')
    import os
    action('Guida rapida e avvio',lambda:os.startfile(str(Path(__file__).resolve().parent.parent/'LEGGIMI - Avvio e comandi.txt')),None,help_menu)
    e.play_action=action('Play',e.toggle)
    e.visuals=MediaVisuals(e)
    body=QWidget(); layout=QVBoxLayout(body); layout.setContentsMargins(0,0,0,0); layout.setSpacing(0)
    vertical=QSplitter(Qt.Orientation.Vertical); vertical.setChildrenCollapsible(False)
    top=QSplitter(Qt.Orientation.Horizontal); top.setChildrenCollapsible(False)
    project=QWidget(); project.setMinimumWidth(180); pl=QVBoxLayout(project); pl.setContentsMargins(10,0,9,0); pl.setSpacing(4)
    heading=QHBoxLayout(); heading.addWidget(section('PROGETTO')); heading.addStretch()
    e.missing_button=button('missing',e.relink,tip='Ricollega file mancanti'); heading.addWidget(e.missing_button)
    heading.addWidget(button('plus',e.import_dialog,tip='Importa media · Ctrl+I')); pl.addLayout(heading)
    e.bin=Bin(e); e.bin.setIconSize(QSize(48,34)); e.bin.setSpacing(2); e.bin.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff); pl.addWidget(e.bin,1)
    e.bin_search=QLineEditSafe(); e.bin_search.setPlaceholderText('Cerca file nel progetto…'); e.bin_search.setClearButtonEnabled(True); pl.insertWidget(1,e.bin_search)
    def search_bin(text):
        for i in range(e.bin.count()): e.bin.item(i).setHidden(text.casefold() not in e.bin.item(i).text().casefold())
    e.bin_search.textChanged.connect(search_bin)
    top.addWidget(project)
    center=QWidget(); cl=QVBoxLayout(center); cl.setContentsMargins(6,7,6,0); cl.setSpacing(3)
    e.viewer=Viewer(e); e.viewer.setAlignment(Qt.AlignmentFlag.AlignCenter); e.viewer.setMinimumSize(280,170)
    e.viewer.setSizePolicy(QSizePolicy.Policy.Ignored,QSizePolicy.Policy.Ignored); e.viewer.setStyleSheet('background:#000; border:0;'); cl.addWidget(e.viewer,1)
    transport=QWidget(); tl=QHBoxLayout(transport); tl.setContentsMargins(3,3,3,5); tl.setSpacing(8)
    e.time_label=QLabel('00:00:00:00'); e.time_label.setObjectName('currentTime'); tl.addWidget(e.time_label); tl.addStretch()
    def jump_cut(direction):
        points=sorted(set([0,e.project.duration]+[v for c in e.project.clips for v in (c['start'],c['start']+c['duration'])]))
        values=[p for p in points if p<e.position-.001] if direction<0 else [p for p in points if p>e.position+.001]
        e.pause()
        if values: e.seek(values[-1] if direction<0 else values[0])
    for name,fn,tip in [('start',lambda:(e.pause(),e.seek(0)),'Inizio'),('previous',lambda:jump_cut(-1),'Taglio precedente')]:
        b=button(name,fn,tip=tip); b.setProperty('transport',True); tl.addWidget(b)
    e.play_button=button('play',e.toggle,tip='Play / pausa · Spazio'); e.play_button.setProperty('transport',True); e.play_button.setIconSize(QSize(18,18)); tl.addWidget(e.play_button)
    for name,fn,tip in [('next',lambda:jump_cut(1),'Taglio successivo'),('end',lambda:(e.pause(),e.seek(e.project.duration)),'Fine')]:
        b=button(name,fn,tip=tip); b.setProperty('transport',True); tl.addWidget(b)
    tl.addStretch()
    from PySide6.QtWidgets import QProgressBar
    e.audio_meter=QProgressBar(); e.audio_meter.setRange(0,60); e.audio_meter.setValue(0); e.audio_meter.setFormat('Audio'); e.audio_meter.setFixedWidth(90); e.audio_meter.setToolTip('Picco del segnale audio in ascolto, prima del dispositivo di uscita'); tl.addWidget(e.audio_meter)
    e.duration_label=QLabel('00:00:00:00'); e.duration_label.setObjectName('totalTime'); tl.addWidget(e.duration_label); cl.addWidget(transport)
    top.addWidget(center)
    e.inspector=QWidget(); e.inspector.setMinimumWidth(240); il=QVBoxLayout(e.inspector); il.setSizeConstraint(QLayout.SizeConstraint.SetMinimumSize); il.setContentsMargins(11,0,10,8); il.setSpacing(5)
    def form(parent):
        f=QFormLayout(parent); f.setSizeConstraint(QLayout.SizeConstraint.SetMinimumSize); f.setContentsMargins(0,0,0,0); f.setHorizontalSpacing(10); f.setVerticalSpacing(5); f.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow); return f
    e.sequence_panel=QWidget(); sq=QVBoxLayout(e.sequence_panel); sq.setContentsMargins(0,0,0,0); sq.setSpacing(5); sq.addWidget(section('SEQUENZA'))
    seqform=QWidget(); sf=form(seqform)
    e.sequence=QComboBox(); e.sequence.addItems(['9:16 · 1080×1920','16:9 · 1920×1080','1:1 · 1080×1080','Personalizzato…']); e.sequence.activated.connect(e.sequence_changed); sf.addRow('Formato',e.sequence)
    e.fps_combo=QComboBox(); e.fps_combo.addItems(['24 fps','25 fps','30 fps','50 fps','60 fps'])
    def fps_changed(index):
        e.checkpoint(); e.project.settings['fps']=[24,25,30,50,60][index]; e.changed()
    e.fps_combo.activated.connect(fps_changed); sf.addRow('Fotogrammi',e.fps_combo); sq.addWidget(seqform)
    sq.addWidget(section('LOGO')); e.logo=QCheckBox('Logo Coppa Élite'); e.logo.toggled.connect(e.toggle_logo); sq.addWidget(e.logo)
    logo_form=QFormLayout(); e.logo_fields={}
    for key,label,lo,hi,default in [('logoSize','Dimensione',20,800,190),('logoY','Distanza dall’alto',0,1920,320)]:
        field=QDoubleSpinBox(); field.setRange(lo,hi); field.setValue(default); field.setDecimals(0)
        field.editingFinished.connect(e.edit_logo); e.logo_fields[key]=field; logo_form.addRow(label,field)
    e.logo_right=QCheckBox('Logo a destra'); e.logo_right.toggled.connect(e.edit_logo); logo_form.addRow(e.logo_right); sq.addLayout(logo_form)
    sq.addWidget(section('INFO')); e.project_info=muted(); sq.addWidget(e.project_info); sq.addWidget(muted('Seleziona una clip per modificarla.')); il.addWidget(e.sequence_panel)
    e.clip_panel=QWidget(); cp=QVBoxLayout(e.clip_panel); cp.setSizeConstraint(QLayout.SizeConstraint.SetMinimumSize); cp.setContentsMargins(0,0,0,0); cp.setSpacing(4); cp.addWidget(section('CLIP'))
    e.name=QLabel(); e.name.setWordWrap(True); e.name.setStyleSheet('font-weight:600; font-size:11px;'); cp.addWidget(e.name)
    e.clip_stats=muted(); cp.addWidget(e.clip_stats)
    e.fields={}
    def spin(key,lo,hi,step,decimals=3):
        field=QDoubleSpinBox(); field.setRange(lo,hi); field.setDecimals(decimals); field.setSingleStep(step); field.editingFinished.connect(lambda k=key:e.set_property(k)); e.fields[key]=field; return field
    cp.addWidget(section('VELOCITÀ')); cp.addWidget(spin('speed',.1,16,.1,2)); cp.addWidget(muted('La durata della clip segue la velocità impostata.'))
    cp.addWidget(section('AUDIO')); volume_line=QHBoxLayout(); volume_line.addWidget(muted('Volume')); volume_line.addStretch(); e.volume_label=muted('100%'); volume_line.addWidget(e.volume_label); cp.addLayout(volume_line)
    e.volume_slider=QSlider(Qt.Orientation.Horizontal); e.volume_slider.setRange(0,200)
    spin('volume',0,2,.05).hide()
    e.volume_slider.valueChanged.connect(lambda v:(e.volume_label.setText(f'{v}%'),e.fields['volume'].setValue(v/100)))
    e.volume_slider.sliderReleased.connect(lambda:e.set_property('volume')); cp.addWidget(e.volume_slider)
    e.pano_panel=QWidget(); pn=QVBoxLayout(e.pano_panel); pn.setSizeConstraint(QLayout.SizeConstraint.SetMinimumSize); pn.setContentsMargins(0,0,0,0); pn.setSpacing(4); pn.addWidget(section('360°')); pn.addWidget(muted("Trascina nel visore per scegliere l'inquadratura."))
    e.stabilize_box=QCheckBox('Stabilizzazione (giroscopio)'); e.stabilize_box.toggled.connect(lambda v:e.set_pano_flag('stabilize',v)); pn.addWidget(e.stabilize_box)
    e.direction_box=QCheckBox('Blocca direzione'); e.direction_box.toggled.connect(lambda v:e.set_pano_flag('lockDirection',v)); pn.addWidget(e.direction_box)
    e.pano_fields={}
    pfwidget=QWidget(); pf=form(pfwidget)
    for key,label,lo,hi,step in [('smooth','Morbidezza (s)',.05,8,.1),('yaw','Direzione',-360,360,1),('pitch','Inclinazione',-90,90,1),('roll','Rotazione',-180,180,1),('fov','Campo visivo',20,330,1),('distance','Prospettiva',0,1.5,.05)]:
        field=QDoubleSpinBox(); field.setRange(lo,hi); field.setDecimals(2); field.setSingleStep(step); field.editingFinished.connect(lambda k=key:e.set_pano(k)); e.pano_fields[key]=field; pf.addRow(label,field)
    pn.addWidget(pfwidget)
    presets=QHBoxLayout()
    for name,values in [('Normale',dict(fov=100,distance=0,pitch=0,roll=0)),('Ampio',dict(fov=140,distance=.6)),('Pianeta',dict(fov=300,distance=1,pitch=-90,roll=0))]:
        b=QPushButton(name); b.clicked.connect(lambda checked=False,v=values:e.pano_preset(v)); presets.addWidget(b)
    pn.addLayout(presets); pn.addWidget(section('KEYFRAME')); keyrow=QHBoxLayout()
    e.add_key_button=QPushButton('◆ Aggiungi'); e.add_key_button.clicked.connect(e.add_pano_key); keyrow.addWidget(e.add_key_button)
    e.remove_key_button=QPushButton('Rimuovi'); e.remove_key_button.clicked.connect(e.remove_pano_key); keyrow.addWidget(e.remove_key_button); pn.addLayout(keyrow); cp.addWidget(e.pano_panel)
    e.title_panel=QWidget(); tf=form(e.title_panel); tf.addRow(section('TITOLO'))
    e.title_style=QComboBox(); e.title_style.addItems(['Cartellino Coppa Élite','Testo libero']); e.title_style.activated.connect(e.set_title_style); tf.addRow('Tipo',e.title_style)
    e.title_names=QLineEditSafe(); e.title_names.setPlaceholderText('Nome | Cognome'); e.title_names.editingFinished.connect(e.set_title); tf.addRow('Nomi',e.title_names)
    e.title_tag=QLineEditSafe(); e.title_tag.editingFinished.connect(e.set_title); tf.addRow('Tag',e.title_tag)
    e.title_label=QLineEditSafe(); e.title_label.editingFinished.connect(e.set_title); tf.addRow('Etichetta',e.title_label); cp.addWidget(e.title_panel)
    e.title_show_label=QCheckBox('Mostra etichetta'); e.title_show_label.toggled.connect(e.edit_title_layout); tf.addRow(e.title_show_label)
    e.title_fields={}
    for key,label,lo,hi,step,default in [('x','Posizione X',0,1,.01,.056),('y','Posizione Y',0,1,.01,.693),('size','Dimensione',.2,3,.1,1),('fade','Dissolvenza',0,3,.1,.4)]:
        field=QDoubleSpinBox(); field.setRange(lo,hi); field.setSingleStep(step); field.setDecimals(3); field.setValue(default)
        field.editingFinished.connect(e.edit_title_layout); e.title_fields[key]=field; tf.addRow(label,field)
    apply_style=QPushButton('Applica stile a tutti i titoli'); apply_style.clicked.connect(e.apply_title_style); tf.addRow(apply_style)
    advanced_toggle=QToolButton(); advanced_toggle.setText('▸ Tempi e trasformazione'); advanced_toggle.setCheckable(True); cp.addWidget(advanced_toggle)
    advanced=QWidget(); af=form(advanced)
    for key,label,lo,hi,step in [('start','Inizio',0,86400,.1),('in','Sorgente',0,86400,.1),('duration','Durata',.01,86400,.1),('opacity','Opacità',0,1,.05),('scale','Scala',.05,8,.05),('x','Posizione X',-2,2,.01),('y','Posizione Y',-2,2,.01)]: af.addRow(label,spin(key,lo,hi,step))
    e.track=QComboBox(); e.track.addItems(['V1 / A1','V2 / A2','Titoli']); e.track.activated.connect(e.set_track); af.addRow('Traccia',e.track)
    e.fill=QCheckBox('Riempi fotogramma'); e.fill.toggled.connect(e.set_fill); af.addRow(e.fill); advanced.hide(); advanced_toggle.toggled.connect(advanced.setVisible); cp.addWidget(advanced)
    il.removeWidget(e.sequence_panel)
    from PySide6.QtWidgets import QTabWidget
    e.inspector_tabs=QTabWidget(); il.addWidget(e.inspector_tabs)
    clip_page=QWidget(); clip_layout=QVBoxLayout(clip_page); clip_layout.setContentsMargins(0,0,0,0); clip_layout.addWidget(e.sequence_panel); clip_layout.addWidget(e.clip_panel); clip_layout.addStretch()
    e.inspector_tabs.addTab(clip_page,'Clip')
    effects_page=QWidget(); effects_layout=QVBoxLayout(effects_page); effects_layout.setContentsMargins(0,0,0,0)
    from productivity import build_effects
    build_effects(e,effects_layout); effects_layout.addStretch(); e.inspector_tabs.addTab(effects_page,'Effetti')
    captions_page=QWidget(); captions_layout=QVBoxLayout(captions_page); captions_layout.setContentsMargins(0,0,0,0)
    from editor_actions import build_caption_panel
    build_caption_panel(e,captions_layout); captions_layout.addStretch(); e.inspector_tabs.addTab(captions_page,'Sottotitoli')
    inspector_scroll=QScrollArea(); inspector_scroll.setWidget(e.inspector); inspector_scroll.setWidgetResizable(True); inspector_scroll.setMinimumWidth(250); inspector_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    top.addWidget(inspector_scroll); top.setSizes([350,600,310]); top.setStretchFactor(1,1); vertical.addWidget(top)
    lower=QWidget(); low=QVBoxLayout(lower); low.setContentsMargins(0,0,0,0); low.setSpacing(0)
    bar=QWidget(); bar.setObjectName('timelineBar'); bl=QHBoxLayout(bar); bl.setContentsMargins(8,4,8,4); bl.setSpacing(9)
    e.select_button=button('select',lambda:e.choose_tool(False),tip='Selezione · V',checkable=True); e.select_button.setChecked(True); e.select_button.setIcon(icon('select','#14202a')); bl.addWidget(e.select_button)
    e.razor_button=button('razor',lambda:e.choose_tool(True),tip='Lametta · C',checkable=True); bl.addWidget(e.razor_button)
    bl.addSpacing(10); bl.addWidget(button('cut',e.cut,'Taglia','Taglia al cursore · Ctrl+K')); bl.addWidget(button('remove',lambda:e.delete(True),'Elimina e chiudi','Shift+Canc')); bl.addWidget(button(None,e.add_title,'Aa  Titolo','Aggiungi titolo · Ctrl+T'))
    bl.addStretch(); e.tool_label=muted('Pronto'); bl.addWidget(e.tool_label); bl.addStretch()
    e.snap_box=QCheckBox('Snap'); e.snap_box.setChecked(True); e.snap_box.toggled.connect(lambda v:setattr(e,'snapping',v)); e.snap_box.setToolTip('Aggancio ai tagli · S'); bl.addWidget(e.snap_box)
    e.preview_quality=QComboBox(); e.preview_quality.addItems(['Preview 360','Preview 720','Preview 960']); e.preview_quality.setCurrentIndex(1)
    e.preview_quality.setToolTip('La qualità dell’anteprima non modifica il video esportato')
    e.preview_quality.activated.connect(lambda i:(setattr(e,'preview_limit',[360,720,960][i]),e.render_preview())); bl.addWidget(e.preview_quality)
    bl.addWidget(button('zoom',lambda:e.zoom(1/1.3),tip='Riduci timeline'))
    e.zoom_slider=QSlider(Qt.Orientation.Horizontal); e.zoom_slider.setRange(2,200); e.zoom_slider.setValue(22); e.zoom_slider.setFixedWidth(95)
    e.zoom_slider.valueChanged.connect(lambda v:e.set_timeline_zoom(v)); bl.addWidget(e.zoom_slider); bl.addWidget(button('fit',e.fit,tip='Adatta timeline'))
    low.addWidget(bar)
    e.timeline=Timeline(e); e.timeline.zoom=22
    e.scroll=QScrollArea(); e.scroll.setWidget(e.timeline); e.scroll.setWidgetResizable(True); low.addWidget(e.scroll,1)
    for lane in range(2):
        for key in ('videoHidden','audioMuted'):
            box=QCheckBox(e); box.hide(); box.toggled.connect(lambda v,k=key,n=lane:e.toggle_track(k,n,v)); setattr(e,f'{key}{lane}',box)
    vertical.addWidget(lower); vertical.setSizes([390,370]); vertical.setStretchFactor(0,1); vertical.setStretchFactor(1,1)
    layout.addWidget(vertical); e.setCentralWidget(body); e.setAcceptDrops(True); e.statusBar().showMessage('Importa media con Ctrl+I o trascina i file nel progetto')
    def visuals_ready(mid,frames,peaks):
        for row in range(e.bin.count()):
            item=e.bin.item(row)
            if item.data(Qt.ItemDataRole.UserRole)==mid and frames: item.setIcon(QIcon(QPixmap.fromImage(frames[0][1])))
        e.timeline.update()
    e.visuals.ready.connect(visuals_ready)


# QLineEdit is imported separately to keep the widget list above easy to scan.
from PySide6.QtWidgets import QLineEdit as QLineEditSafe


def update_design(e):
    c=e.selected_clip(); m=e.project.item(c) if c else None
    e.sequence_panel.setVisible(c is None and e.caption() is None); e.clip_panel.setVisible(c is not None)
    is_pano=bool(c and m and (m.get('pano') or 'pano' in c))
    e.pano_panel.setVisible(is_pano); e.title_panel.setVisible(bool(c and 'title' in c))
    plain=bool(c and c.get('title',{}).get('style')=='text')
    for field in (e.title_tag,e.title_label,e.title_show_label):
        field.setVisible(not plain)
        label=e.title_panel.layout().labelForField(field)
        if label: label.setVisible(not plain)
    e.title_names.setPlaceholderText('Il tuo testo' if plain else 'Nome | Altro nome')
    e.project_info.setText(f'{len(e.project.clips)} clip · {int(e.project.duration)//60}:{int(e.project.duration)%60:02d}')
    missing=sum(not Path(m['path']).is_file() for m in e.project.media); e.missing_button.setVisible(missing>0); e.missing_button.setToolTip(f'Mancanti ({missing}) · Ricollega media')
    if c:
        fps=e.project.settings['fps']
        def stamp(t): return f'{int(t)//3600:02d}:{int(t)//60%60:02d}:{int(t)%60:02d}:{int(t%1*fps):02d}'
        end=c.get('in',0)+c['duration']*c.get('speed',1)
        e.clip_stats.setText(f'Inizio       {stamp(c["start"])}\nDurata      {stamp(c["duration"])}\nSorgente   {c.get("in",0):.2f} → {end:.2f} s\nTraccia      {"Titoli" if c["track"]==2 else "V2 / A2" if c["track"]==1 else "V1 / A1"}')
        e.volume_slider.blockSignals(True); e.volume_slider.setValue(round(c.get('volume',1)*100)); e.volume_slider.blockSignals(False); e.volume_label.setText(f'{c.get("volume",1):.0%}')
    fps=e.project.settings.get('fps',30); values=[24,25,30,50,60]
    e.fps_combo.setCurrentIndex(values.index(fps) if fps in values else -1)
