"""Editing conveniences using existing Qt, FFmpeg and Pillow installations."""
import copy
import os
from pathlib import Path
import re
import subprocess
import threading
from effects import DEFAULTS,MOTION,at,crossfade


class Productivity:
    def clear_cache(self):
        from storage import prune
        if self.pending or self.exporting or getattr(self,'proxy_running',False): self.statusBar().showMessage('Attendi la fine dell’operazione in corso per pulire la cache.'); return
        self.pause(); self.sequence_preview.invalidate(); self.project.data.pop('preview',None)
        for cap in self.captures.values(): cap.release()
        self.captures.clear(); self.frame_cache.clear()
        for m in self.project.media: m.pop('proxyPath',None); m.pop('proxyFingerprint',None)
        remaining=prune(limit=0); self.render_preview(); self.statusBar().showMessage(f'Cache pulita. File ancora in uso: {remaining/1024**2:.1f} MB. Gli originali restano disponibili.')

    def add_track(self):
        if len(self.project.lanes)>=8: self.statusBar().showMessage('Sono già disponibili otto tracce video/audio.'); return
        self.checkpoint(); tracks=self.project.data['tracks']; count=len(tracks['videoHidden']); new=3 if count==2 else count
        for key in ('videoHidden','audioMuted'): tracks[key]+=[False]*(new+1-len(tracks[key]))
        self.changed()
    def edit_effect(self,key):
        c=self.selected_clip()
        if self.updating or not c or 'title' in c: return
        value=self.effect_fields[key].value(); e=c.setdefault('effects',{})
        if abs(e.get(key,DEFAULTS.get(key,0))-value)<1e-7: return
        self.checkpoint(); e[key]=value
        if key=='rotation' and e.get('keys'): self.store_motion_key(c,{'rotation':value})
        self.changed()

    def store_motion_key(self,c,overrides=None):
        t=self.media_time(c); e=c.setdefault('effects',{}); keys=e.setdefault('keys',[])
        frame=dict(t=t,**at(c,self.position-c['start'])); frame.update(overrides or {})
        nearest=next((k for k in keys if abs(k['t']-t)<.5/self.project.settings['fps']*c.get('speed',1)),None)
        if nearest is not None: nearest.update(frame)
        else: keys.append(frame); keys.sort(key=lambda k:k['t'])

    def add_motion_key(self):
        c=self.selected_clip()
        if not c or 'title' in c: return
        self.checkpoint(); self.store_motion_key(c); self.changed()

    def delete_motion_key(self):
        c=self.selected_clip()
        if not c or not c.get('effects',{}).get('keys'): return
        keys=c['effects']['keys']; near=min(keys,key=lambda k:abs(k['t']-self.media_time(c)))
        self.checkpoint(); keys.remove(near); self.changed()

    def visit_motion_key(self,direction):
        c=self.selected_clip()
        if not c: return
        times=sorted(c['start']+(k['t']-c.get('in',0))/c.get('speed',1) for k in c.get('effects',{}).get('keys',[]))
        values=[t for t in times if t<self.position-.001] if direction<0 else [t for t in times if t>self.position+.001]
        if values: self.pause(); self.seek(values[-1] if direction<0 else values[0]); self.update_inspector()

    def reset_effects(self):
        c=self.selected_clip()
        if c: self.checkpoint(); c.pop('effects',None); self.changed()

    def set_motion_ease(self):
        c=self.selected_clip()
        if self.updating or not c: return
        self.checkpoint(); c.setdefault('effects',{})['ease']='smooth' if self.motion_ease.isChecked() else 'linear'; self.changed()

    def update_effect_fields(self):
        c=self.selected_clip(); enabled=bool(c and 'title' not in c)
        self.effects_panel.setVisible(enabled)
        self.inspector_tabs.setTabEnabled(1,enabled)
        e=c.get('effects',{}) if c else {}
        for key,field in self.effect_fields.items(): field.setValue(e.get(key,DEFAULTS[key])); field.setEnabled(enabled)
        self.motion_ease.setChecked(e.get('ease','smooth')=='smooth')
        self.motion_info.setText(f'{len(e.get("keys",[]))} keyframe · al cursore' if enabled else '')
        if enabled and e.get('keys'):
            current=at(c,self.position-c['start'])
            for key,value in current.items():
                field=self.effect_fields.get(key) or self.fields.get(key)
                if field: field.setValue(value)

    def apply_crossfade(self):
        c=self.selected_clip()
        if not c: self.error('Seleziona la seconda di due clip consecutive.'); return
        before=self.snapshot()
        try: d=crossfade(self.project,c['id'])
        except ValueError as exc: self.project.data=before; self.error(str(exc)); return
        self.undo_stack.append(before); self.redo_stack.clear(); self.changed()
        self.statusBar().showMessage(f'Dissolvenza incrociata di {d:.2f} s. Le clip si sovrappongono e la sequenza si accorcia dello stesso intervallo.')

    def add_text(self):
        self.add_title(); c=self.selected_clip()
        c['title'].update(style='text',names='Il tuo testo',tag='',showLabel=False,x=.08,y=.45,size=1.)
        self.changed()

    def set_title_style(self,index):
        c=self.selected_clip()
        if self.updating or not c or 'title' not in c: return
        self.checkpoint(); c['title']['style']='text' if index else 'card'; self.changed()

    def normalize_volume(self):
        from core import tool,CREATE_FLAGS
        c=self.selected_clip(); m=self.project.item(c) if c else None
        if not m or not m.get('hasAudio'): self.error('Seleziona una clip con audio.'); return
        if self.pending: return
        self.pending=True; project=self.project; cid=c['id']; original=copy.deepcopy(c)
        self.statusBar().showMessage('Analizzo il volume della clip…')
        def work():
            result=subprocess.run([tool('ffmpeg'),'-v','info','-ss',str(c.get('in',0)),'-t',str(c['duration']*c.get('speed',1)),'-i',m['path'],'-vn','-af','volumedetect','-f','null','-'],capture_output=True,creationflags=CREATE_FLAGS)
            text=result.stderr.decode(errors='replace'); mean=re.search(r'mean_volume:\s*(-?[\d.]+)',text); peak=re.search(r'max_volume:\s*(-?[\d.]+)',text)
            if result.returncode or not mean or not peak: raise ValueError('Impossibile analizzare il volume della clip.')
            gain=min(-18-float(mean[1]),-1.5-float(peak[1])); return max(0,min(2,10**(gain/20)))
        def done(value):
            self.pending=False
            if self.project is not project or c not in project.clips or c!=original: return
            self.checkpoint(); c['volume']=value
            factor=value/max(.000001,original.get('volume',1))
            for k in c.get('effects',{}).get('keys',[]): k['volume']=min(2,k.get('volume',original.get('volume',1))*factor)
            self.changed(); self.statusBar().showMessage(f'Volume regolato al {value:.0%}, con margine sui picchi.')
        self.run_job(work,done)

    def start_proxies(self,automatic=False):
        from storage import proxy,fingerprint
        if getattr(self,'proxy_running',False): return
        selected={c.get('media') for c in self.selected_clips()}
        media=[copy.deepcopy(m) for m in self.project.media if (automatic or not selected or m['id'] in selected) and m.get('hasVideo') and not m.get('still') and not m.get('pano')
               and (not automatic or max(m.get('width',0),m.get('height',0))>1920)]
        if not media: return
        self.proxy_running=True; self.proxy_cancel=threading.Event(); project=self.project
        self.statusBar().showMessage('Preparo i proxy in background…')
        def work():
            results=[]
            for m in media:
                if self.proxy_cancel.is_set(): break
                try: results.append((m['id'],proxy(m,self.proxy_cancel)))
                except RuntimeError:
                    if self.proxy_cancel.is_set(): break
                    raise
            return results
        def done(results):
            self.proxy_running=False
            if self.project is not project: return
            for mid,value in results:
                m=next((m for m in project.media if m['id']==mid),None)
                if m and value:
                    m.update(proxyPath=value[0],proxyFingerprint=value[1])
                    cap=self.captures.pop(mid,None)
                    if cap: cap.release()
                    self.frame_cache.pop(mid,None)
            self.render_preview(); self.statusBar().showMessage('Preparazione proxy interrotta.' if self.proxy_cancel.is_set() else 'Proxy pronti. L’esportazione usa sempre gli originali.')
        self.run_job(work,done,on_error=lambda:setattr(self,'proxy_running',False))

    def cancel_proxies(self):
        if getattr(self,'proxy_running',False): self.proxy_cancel.set()

    def prepare_preview(self):
        from core import Project,export
        from playback import preview_signature
        from storage import CACHE,prune
        if self.pending or self.exporting or self.project.duration<=0: return
        key=preview_signature(self.project); project=self.project; rendered=Project(); rendered.data=self.snapshot()
        ratio=min(1,720/max(rendered.settings['width'],rendered.settings['height']))
        for dim in ('width','height'): rendered.settings[dim]=max(2,round(rendered.settings[dim]*ratio/2)*2)
        CACHE.mkdir(parents=True,exist_ok=True); target=CACHE/f'preview-{key}.mp4'
        self.pending=True; self.statusBar().showMessage('Preparo l’anteprima fluida con audio ed effetti…')
        from PySide6.QtWidgets import QProgressDialog
        from PySide6.QtCore import Qt
        cancel=threading.Event(); dialog=QProgressDialog('Preparo l’anteprima fluida…','Annulla',0,100,self)
        dialog.setWindowModality(Qt.WindowModality.WindowModal); dialog.setMinimumDuration(0); dialog.canceled.connect(cancel.set)
        def progress(value): dialog.setValue(min(100,round(value*100)))
        self.preview_progress.connect(progress)
        def close_dialog():
            self.preview_progress.disconnect(progress); dialog.close(); dialog.deleteLater()
        def work():
            prune()
            try:
                if not target.exists(): export(rendered,target,self.preview_progress.emit,cancel)
            except RuntimeError:
                if cancel.is_set(): return None
                raise
            from storage import CACHE_LIMIT
            if target.stat().st_size>CACHE_LIMIT//2:
                target.unlink(); raise ValueError('Anteprima troppo grande per la cache limitata. Prepara i proxy delle singole clip.')
            prune(protect=[target]); return target
        def done(path):
            close_dialog(); self.pending=False
            if path is None: self.statusBar().showMessage('Preparazione anteprima annullata.'); return
            if self.project is not project or preview_signature(self.project)!=key: return
            self.project.data['preview']=dict(path=str(path),fingerprint=key)
            # A saved path is not required for an absolute cached preview.
            self.sequence_preview.configure(self.project); self.seek(self.position)
            self.statusBar().showMessage('Anteprima pronta. Qualsiasi modifica la invalida automaticamente.')
        self.run_job(work,done,on_error=close_dialog)

    def recover_session(self,automatic=False):
        from storage import recoverable
        from core import Project
        from PySide6.QtWidgets import QMessageBox,QInputDialog
        paths=recoverable()
        if not paths:
            if not automatic: self.statusBar().showMessage('Nessuna sessione interrotta da recuperare.')
            return
        if automatic and QMessageBox.question(self,'Recupero progetto','È disponibile una sessione interrotta. Recuperarla?',QMessageBox.StandardButton.Yes|QMessageBox.StandardButton.No)!=QMessageBox.StandardButton.Yes: return
        if not self.confirm_leave(): return
        try: p=Project.load(paths[0])
        except Exception as exc: self.error(f'Sessione non recuperabile: {exc}'); return
        p.path=None; p.data.pop('_recoverySource',None); self.reset(p); self.dirty=True; self.autosave.start()
        paths[0].unlink(missing_ok=True)
        self.statusBar().showMessage('Sessione recuperata: salva il progetto con un nuovo nome.')

    def restore_version(self):
        from storage import history
        from PySide6.QtWidgets import QInputDialog
        from core import Project
        paths=history(self.project.path)
        if not paths: self.statusBar().showMessage('Non sono ancora disponibili versioni precedenti di questo progetto.'); return
        label,ok=QInputDialog.getItem(self,'Versioni precedenti','Scegli una versione da aprire come copia',[p.stem for p in paths],0,False)
        if ok and self.confirm_leave():
            p=Project.load(next(p for p in paths if p.stem==label)); p.path=None; self.reset(p); self.dirty=True; self.autosave.start()


def build_effects(e,layout):
    from PySide6.QtWidgets import QWidget,QVBoxLayout,QFormLayout,QDoubleSpinBox,QPushButton,QHBoxLayout,QCheckBox,QLabel,QGroupBox
    from interface import section,muted
    e.effects_panel=QWidget(); outer=QVBoxLayout(e.effects_panel); outer.setContentsMargins(0,0,0,0); e.effect_fields={}
    for heading,fields in [('Dissolvenze', [('fadeIn','Video ingresso',0,10,.1),('fadeOut','Video uscita',0,10,.1),('audioFadeIn','Audio ingresso',0,10,.1),('audioFadeOut','Audio uscita',0,10,.1)]),
                           ('Colore',[('exposure','Esposizione',-3,3,.1),('contrast','Contrasto',.2,2,.05),('saturation','Saturazione',0,2,.05),('temperature','Temperatura',-1,1,.05)]),
                           ('Animazione',[('rotation','Rotazione',-360,360,1)])]:
        group=QGroupBox(heading); form=QFormLayout(group)
        for key,label,lo,hi,step in fields:
            spin=QDoubleSpinBox(); spin.setRange(lo,hi); spin.setSingleStep(step); spin.setDecimals(2); spin.editingFinished.connect(lambda k=key:e.edit_effect(k)); e.effect_fields[key]=spin; form.addRow(label,spin)
        outer.addWidget(group)
    e.motion_info=muted(); outer.addWidget(e.motion_info)
    row=QHBoxLayout()
    for label,callback in [('◀',lambda:e.visit_motion_key(-1)),('◆ Aggiungi',e.add_motion_key),('Rimuovi',e.delete_motion_key),('▶',lambda:e.visit_motion_key(1))]:
        button=QPushButton(label); button.clicked.connect(callback); row.addWidget(button)
    outer.addLayout(row); e.motion_ease=QCheckBox('Movimento morbido'); e.motion_ease.toggled.connect(e.set_motion_ease); outer.addWidget(e.motion_ease)
    outer.addWidget(muted('Aggiungi un keyframe, sposta il cursore, modifica scala, posizione, rotazione, opacità o volume.'))
    from color_grading import open_window
    for text,callback in [('Color grading automatico…',lambda:open_window(e)),('Dissolvenza incrociata con precedente',e.apply_crossfade),('Regola automaticamente il volume',e.normalize_volume),('Reimposta effetti e animazione',e.reset_effects)]:
        button=QPushButton(text); button.clicked.connect(callback); outer.addWidget(button)
    layout.addWidget(e.effects_panel)
