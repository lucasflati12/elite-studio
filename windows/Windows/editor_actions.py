"""Common editing commands and captions inspector for the native Windows UI."""
import copy
from pathlib import Path
from captions import DEFAULT_STYLE,retime,set_text,chunks,transcribe


class EditingActions:
    def edit_title_layout(self):
        c=self.selected_clip()
        if self.updating or not c or 'title' not in c: return
        values={k:field.value() for k,field in self.title_fields.items()}; values['showLabel']=self.title_show_label.isChecked()
        defaults=dict(x=.056,y=.693,size=1,fade=.4,showLabel=True)
        if all(c['title'].get(k,defaults[k])==v for k,v in values.items()): return
        self.checkpoint(); c['title'].update(values); self.changed()

    def update_layout_fields(self):
        c=self.selected_clip(); title=c.get('title',{}) if c else {}
        for key,field in self.title_fields.items(): field.setValue(title.get(key,dict(x=.056,y=.693,size=1,fade=.4)[key]))
        self.title_show_label.setChecked(title.get('showLabel',True))

    def apply_title_style(self):
        c=self.selected_clip()
        if not c or 'title' not in c: return
        self.checkpoint()
        for other in self.project.clips:
            if 'title' in other:
                names=other['title'].get('names',''); other['title']=copy.deepcopy(c['title']); other['title']['names']=names
        self.changed()

    def selected_clips(self):
        ids=set(self.selection)
        if self.selected: ids.add(self.selected)
        return [c for c in self.project.clips if c['id'] in ids]

    def select_all(self):
        from PySide6.QtWidgets import QApplication,QLineEdit,QTextEdit
        focus=QApplication.focusWidget()
        if isinstance(focus,(QLineEdit,QTextEdit)): focus.selectAll(); return
        self.selection={c['id'] for c in self.project.clips}; self.selected=next(iter(self.selection),None)
        self.selected_caption=None; self.update_inspector(); self.timeline.update()

    def ripple_trim(self,to_playhead):
        from editing import extract
        c=self.selected_clip() or next((c for c in self.project.clips if c['start']<self.position<c['start']+c['duration']),None)
        if not c or not c['start']<self.position<c['start']+c['duration']: return
        a,b=(c['start'],self.position) if to_playhead else (self.position,c['start']+c['duration'])
        self.checkpoint(); extract(self.project,a,b); self.position=a; self.changed()

    def shuttle(self,direction):
        rate=min(8,abs(self.play_rate)*2) if self.playing and self.play_rate*direction>0 else 1
        self.pause(); self.play_rate=rate*direction; self.play()

    def caption(self):
        return next((c for c in self.project.data.get('captions',[]) if c['id']==self.selected_caption),None)

    def select_caption(self,cid):
        self.selected=None; self.selection.clear(); self.selected_caption=cid
        self.update_inspector(); self.timeline.update()
        self.inspector_tabs.setCurrentIndex(2)

    def add_caption(self):
        from core import uid
        self.checkpoint(); c=dict(id=uid(),start=self.position,end=self.position+1.5,words=[])
        set_text(c,'Nuovo sottotitolo'); self.project.data['captions'].append(c)
        self.select_caption(c['id']); self.changed()

    def generate_captions(self):
        from PySide6.QtWidgets import QProgressDialog
        from PySide6.QtCore import Qt
        if self.pending or self.exporting: return
        if not self.project.clips: self.error('Aggiungi una clip con audio alla timeline.'); return
        self.pause(); self.pending=True; project=copy.deepcopy(self.project)
        dialog=QProgressDialog('Preparo i sottotitoli…',None,0,0,self)
        dialog.setWindowTitle('Sottotitoli automatici'); dialog.setWindowModality(Qt.WindowModality.ApplicationModal)
        dialog.setMinimumDuration(0); dialog.show()
        def close_dialog():
            self.caption_status.disconnect(dialog.setLabelText); dialog.close(); dialog.deleteLater()
        def done(captions):
            close_dialog(); self.pending=False
            if not captions: self.statusBar().showMessage('Nessuna parola riconosciuta'); return
            self.checkpoint(); self.project.data['captions']=captions; self.project.data['tracks']['captionsHidden']=False
            self.selected_caption=None; self.changed(); self.statusBar().showMessage(f'Sottotitoli pronti: {len(captions)} frasi')
        def failed(): close_dialog()
        self.run_job(lambda:transcribe(project,self.caption_status.emit),done,on_error=failed)
        self.caption_status.connect(dialog.setLabelText)

    def update_caption_fields(self):
        c=self.caption(); s={**DEFAULT_STYLE,**self.project.data.get('captionStyle',{})}
        self.caption_text.setEnabled(c is not None)
        self.caption_text.setText(' '.join(w['w'] for w in c.get('words',[])) if c else '')
        for key,field in self.caption_times.items():
            field.setEnabled(c is not None); field.setValue(c[key] if c else 0)
        self.caption_visible.setChecked(not self.project.data['tracks'].get('captionsHidden',False))
        self.caption_look.setCurrentIndex(['negativo','bianco','oro'].index(s['look']) if s['look'] in ['negativo','bianco','oro'] else 0)
        self.caption_words.setValue(s['maxWords']); self.caption_size.setValue(s['size']); self.caption_y.setValue(s['y'])
        self.caption_upper.setChecked(s['uppercase']); self.caption_pop.setChecked(s['pop'])
        self.caption_language.setCurrentIndex(max(0,self.caption_language.findData(s['language'])))

    def edit_caption(self):
        if self.updating: return
        c=self.caption()
        if not c: return
        start=self.caption_times['start'].value(); end=self.caption_times['end'].value()
        if end<=start: self.error('La fine deve essere successiva all’inizio.'); self.update_inspector(); return
        old=copy.deepcopy(c); new=copy.deepcopy(c); retime(new,start,end); set_text(new,self.caption_text.text())
        if old!=new: self.checkpoint(); c.update(new); self.changed()

    def style_captions(self):
        if self.updating: return
        style=dict(look=['negativo','bianco','oro'][self.caption_look.currentIndex()],maxWords=self.caption_words.value(),
                   size=self.caption_size.value(),y=self.caption_y.value(),uppercase=self.caption_upper.isChecked(),
                   pop=self.caption_pop.isChecked(),language=self.caption_language.currentData())
        previous={**DEFAULT_STYLE,**self.project.data.get('captionStyle',{})}
        visible=self.caption_visible.isChecked()
        if style==previous and visible!=self.project.data['tracks'].get('captionsHidden',False): return
        self.checkpoint(); self.project.data['captionStyle']=style; self.project.data['tracks']['captionsHidden']=not visible
        if style['maxWords']!=previous['maxWords']:
            self.project.data['captions']=chunks([w for c in self.project.data['captions'] for w in c.get('words',[])],style['maxWords']); self.selected_caption=None
        self.changed()

    def split_caption(self,c,t):
        from core import uid
        if not c['start']+.05<t<c['end']-.05: return
        left=[w for w in c['words'] if (w['s']+w['e'])/2<t]; right=[w for w in c['words'] if (w['s']+w['e'])/2>=t]
        if not left or not right: return
        self.checkpoint(); other=copy.deepcopy(c); other.update(id=uid(),start=t,words=right,text=' '.join(w['w'] for w in right))
        c.update(end=t,words=left,text=' '.join(w['w'] for w in left)); self.project.data['captions'].append(other); self.changed()

    def bin_menu(self,point):
        from PySide6.QtWidgets import QMenu,QMessageBox
        from PySide6.QtCore import Qt
        import os
        item=self.bin.itemAt(point)
        if not item: return
        mid=item.data(Qt.ItemDataRole.UserRole); m=next(m for m in self.project.media if m['id']==mid)
        menu=QMenu(self)
        menu.addAction('Aggiungi in fondo alla timeline',lambda:self.append_media(mid))
        menu.addAction('Inserisci al cursore',lambda:self.append_media(mid,0,self.position))
        if Path(m['path']).is_file(): menu.addAction('Mostra in Esplora file',lambda:os.startfile(str(Path(m['path']).parent)))
        def remove():
            used=[c for c in self.project.clips if c.get('media')==mid]
            if used and QMessageBox.question(self,'Rimuovi dal progetto',f'Rimuovere anche le {len(used)} clip che usano questo file?',QMessageBox.StandardButton.Yes|QMessageBox.StandardButton.No)!=QMessageBox.StandardButton.Yes: return
            self.checkpoint(); self.project.data['clips']=[c for c in self.project.clips if c.get('media')!=mid]
            self.project.media.remove(m); self.changed()
        menu.addSeparator(); menu.addAction('Rimuovi dal progetto',remove); menu.exec(self.bin.mapToGlobal(point))


def build_caption_panel(e,layout):
    from PySide6.QtWidgets import QWidget,QVBoxLayout,QFormLayout,QPushButton,QLineEdit,QDoubleSpinBox,QSpinBox,QComboBox,QCheckBox,QToolButton
    from interface import section,muted
    layout.addWidget(section('SOTTOTITOLI'))
    generate=QPushButton('Genera sottotitoli automatici'); generate.clicked.connect(e.generate_captions); layout.addWidget(generate)
    add=QPushButton('Aggiungi sottotitolo al cursore'); add.clicked.connect(e.add_caption); layout.addWidget(add)
    e.caption_visible=QCheckBox('Mostra sottotitoli'); e.caption_visible.toggled.connect(e.style_captions); layout.addWidget(e.caption_visible)
    e.caption_text=QLineEdit(); e.caption_text.setPlaceholderText('Seleziona una frase nella traccia CC'); e.caption_text.editingFinished.connect(e.edit_caption); layout.addWidget(e.caption_text)
    form=QFormLayout(); e.caption_times={}
    for key,label in [('start','Inizio'),('end','Fine')]:
        field=QDoubleSpinBox(); field.setDecimals(3); field.setRange(0,86400); field.setSingleStep(.1); field.editingFinished.connect(e.edit_caption); form.addRow(label,field); e.caption_times[key]=field
    layout.addLayout(form)
    toggle=QToolButton(); toggle.setText('Stile e lingua ▸'); toggle.setCheckable(True); layout.addWidget(toggle)
    advanced=QWidget(); af=QFormLayout(advanced); af.setContentsMargins(0,0,0,0)
    e.caption_look=QComboBox(); e.caption_look.addItems(['Negativo','Bianco','Oro']); e.caption_look.activated.connect(e.style_captions); af.addRow('Stile',e.caption_look)
    e.caption_words=QSpinBox(); e.caption_words.setRange(1,8); e.caption_words.valueChanged.connect(e.style_captions); af.addRow('Parole per frase',e.caption_words)
    e.caption_size=QDoubleSpinBox(); e.caption_size.setRange(.2,3); e.caption_size.setSingleStep(.1); e.caption_size.editingFinished.connect(e.style_captions); af.addRow('Dimensione',e.caption_size)
    e.caption_y=QDoubleSpinBox(); e.caption_y.setRange(0,1); e.caption_y.setSingleStep(.01); e.caption_y.editingFinished.connect(e.style_captions); af.addRow('Posizione Y',e.caption_y)
    e.caption_upper=QCheckBox('Maiuscolo'); e.caption_upper.toggled.connect(e.style_captions); af.addRow(e.caption_upper)
    e.caption_pop=QCheckBox('Animazione pop'); e.caption_pop.toggled.connect(e.style_captions); af.addRow(e.caption_pop)
    e.caption_language=QComboBox()
    for name,code in [('Italiano','it-IT'),('English','en-US'),('Español','es-ES'),('Français','fr-FR'),('Deutsch','de-DE')]: e.caption_language.addItem(name,code)
    e.caption_language.activated.connect(e.style_captions); af.addRow('Lingua',e.caption_language)
    advanced.hide(); toggle.toggled.connect(advanced.setVisible); layout.addWidget(advanced)
