"""Elite Studio for Windows: Qt editor with compatible JSON projects."""
from __future__ import annotations
import argparse, copy, json, os, sys, threading, time
from pathlib import Path
from core import Project, ROOT, VIDEO, AUDIO, IMAGES, probe, title_image, export, uid
from editor_actions import EditingActions
from productivity import Productivity


def cli():
    parser=argparse.ArgumentParser(description='Elite Studio for Windows')
    parser.add_argument('project',nargs='?')
    parser.add_argument('--check',metavar='PROJECT')
    parser.add_argument('--export',nargs=2,metavar=('PROJECT','OUTPUT'))
    parser.add_argument('--hevc',action='store_true')
    parser.add_argument('--captions',metavar='PROJECT')
    parser.add_argument('--lang',default=None)
    parser.add_argument('--words',type=int,default=None)
    args=parser.parse_args()
    try:
        if args.captions:
            from captions import transcribe
            p=Project.load(args.captions)
            if args.lang: p.data['captionStyle']['language']=args.lang
            if args.words: p.data['captionStyle']['maxWords']=min(8,max(1,args.words))
            p.data['captions']=transcribe(p,lambda value:print(value,flush=True))
            p.data['tracks']['captionsHidden']=False; p.save()
            print(f"Sottotitoli salvati: {len(p.data['captions'])} frasi"); return 0
        if args.check:
            p=Project.load(args.check)
            if p.missing: raise FileNotFoundError('\n'.join(p.missing))
            print(json.dumps(p.data,indent=2,ensure_ascii=False))
            print(f'ok: {len(p.clips)} clips, {p.duration:.2f} s')
            return 0
        if args.export:
            export(Project.load(args.export[0]),args.export[1],lambda n: print(f'{n:.0%}',flush=True),hevc=args.hevc)
            return 0
    except Exception as e:
        print(str(e),file=sys.stderr); return 1
    return gui(args.project)


def gui(initial=None):
    import cv2
    from pano import PanoRenderer, secondary, primary, view_at, DEFAULT_VIEW
    from PIL import Image
    from PySide6.QtCore import Qt, QTimer, Signal, QObject, QUrl, QRectF, QPointF, QSize
    from PySide6.QtGui import QColor, QPainter, QPen, QImage, QPixmap, QAction, QKeySequence, QIcon
    from PySide6.QtWidgets import (QApplication,QMainWindow,QWidget,QVBoxLayout,QHBoxLayout,QSplitter,
        QListWidget,QListWidgetItem,QLabel,QPushButton,QToolBar,QFileDialog,QMessageBox,QFormLayout,
        QDoubleSpinBox,QLineEdit,QCheckBox,QComboBox,QScrollArea,QInputDialog,QProgressDialog,
        QAbstractSpinBox,QTextEdit)
    from PySide6.QtMultimedia import QMediaPlayer,QAudioOutput

    class Signals(QObject):
        done=Signal(object)
        error=Signal(str)
        progress=Signal(float)

    class Timeline(QWidget):
        def __init__(self,editor):
            super().__init__(); self.editor=editor; self.zoom=22.; self.left=57; self.top=24; self.lane=42; self.drag=None
            self.setMinimumHeight(260); self.setAcceptDrops(True); self.setMouseTracking(True)
            self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        def caption_rect(self,c):
            return QRectF(self.left+c['start']*self.zoom,self.row_y(len(self.rows())-1)+2,max(3,(c['end']-c['start'])*self.zoom),26)
        def rows(self):
            lanes=self.editor.project.lanes
            return [('T',2,False,28)]+[(f'V{i+1 if i<2 else i}',i,False,54 if i==0 else 42) for i in reversed(lanes)]+[(f'A{i+1 if i<2 else i}',i,True,40) for i in lanes]+[('CC',-1,False,32)]
        def caption_at(self,pos):
            return next((c for c in reversed(self.editor.project.data.get('captions',[])) if self.caption_rect(c).contains(pos)),None)
        def refresh(self):
            self.setMinimumHeight(self.top+sum(r[3] for r in self.rows())+12); self.setMinimumWidth(int(self.left+max(15,self.editor.project.duration+5)*self.zoom)); self.update()
        def row_y(self,row):
            return self.top+sum(r[3] for r in self.rows()[:row])
        def track_at(self,y):
            return next((lane for row,(_,lane,_,height) in enumerate(self.rows()) if lane not in (2,-1) and self.row_y(row)<=y<self.row_y(row)+height),0)
        def clip_rect(self,c,audio=False):
            m=self.editor.project.item(c)
            is_audio=audio or bool(m and not m.get('hasVideo',True))
            row=next((i for i,(_,lane,a,_) in enumerate(self.rows()) if lane==c['track'] and (lane==2 or a==is_audio)),0)
            return QRectF(self.left+c['start']*self.zoom,self.row_y(row)+2,max(3,c['duration']*self.zoom),self.rows()[row][3]-5)
        def at(self,position):
            for c in reversed(self.editor.project.clips):
                m=self.editor.project.item(c)
                if self.clip_rect(c).contains(position) or (m and m.get('hasAudio') and self.clip_rect(c,True).contains(position)): return c
            return None
        def time_at(self,x): return max(0,(x-self.left)/self.zoom)
        def keyPressEvent(self,event): self.editor.keyPressEvent(event)
        def paintEvent(self,event):
            import numpy as np
            from PySide6.QtCore import QLineF
            from PySide6.QtGui import QPolygonF,QFont
            from interface import icon
            p=QPainter(self); p.fillRect(self.rect(),QColor('#081520')); width=self.width()
            font=QFont('Segoe UI',9); p.setFont(font)
            for row,(name,track,audio,h) in enumerate(self.rows()[:-1]):
                y=self.row_y(row)
                p.fillRect(0,y,width,h,QColor('#0c1c2b' if row in [0,1,2,4] else '#102231'))
                p.setPen(QColor('#172a3a')); p.drawLine(0,y+h,width,y+h)
                p.fillRect(0,y,self.left,h,QColor('#0a1825'))
                p.setPen(QColor('#b7c3cf')); p.drawText(7,y+h//2+4,name)
                hidden=self.editor.project.data['tracks'].get('titlesHidden',False) if row==0 else self.editor.project.data['tracks']['audioMuted' if audio else 'videoHidden'][track]
                ico=icon('speaker' if audio else 'eye','#384c5e' if hidden else '#738494')
                ico.paint(p,self.left-26,y+(h-16)//2,17,16)
            p.fillRect(0,0,width,self.top,QColor('#0b1826'))
            if self.editor.gap:
                lane,a,b=self.editor.gap
                r=self.clip_rect(dict(track=lane,start=a,duration=b-a))
                p.fillRect(r,QColor(228,202,74,32)); p.setPen(QPen(QColor('#e4ca4a'),1)); p.drawRect(r.adjusted(1,1,-1,-1))
            step=5 if self.zoom>=14 else 10 if self.zoom>=6 else 30
            p.setPen(QColor('#8b99a6'))
            for sec in range(0,int(self.time_at(width))+step+1):
                x=int(self.left+sec*self.zoom)
                if sec%step==0:
                    p.drawText(x+3,11,f'{sec//60}:{sec%60:02d}'); p.drawLine(x,self.top-6,x,self.top)
                else: p.drawLine(x,self.top-3,x,self.top)
                if self.zoom>=18: p.drawLine(int(x+self.zoom/2),self.top-2,int(x+self.zoom/2),self.top)
            for c in self.editor.project.clips:
                m=self.editor.project.item(c); title=c.get('title'); selected=c['id'] in self.editor.selection or c['id']==self.editor.selected
                rects=[]
                if title is not None or not m or m.get('hasVideo',True): rects.append((self.clip_rect(c),False))
                if m and m.get('hasAudio'): rects.append((self.clip_rect(c,True),True))
                for r,audio in rects:
                    if not r.intersects(QRectF(event.rect())): continue
                    p.save(); p.setClipRect(r)
                    p.fillRect(r,QColor('#276c4b' if audio else '#ae9434' if title is not None else '#315e98'))
                    if m and not audio:
                        frames=self.editor.visuals.frames.get(m['id'],[])
                        if frames:
                            tile=78
                            first=max(0,int((event.rect().left()-r.left())//tile))
                            for cell in range(first,int(min(r.width(),event.rect().right()-r.left())//tile)+1):
                                x=r.left()+cell*tile
                                t=c.get('in',0)+max(0,(x-r.left())/self.zoom)*c.get('speed',1)
                                img=min(frames,key=lambda pair:abs(pair[0]-t))[1]
                                dst=QRectF(x,r.top(),tile,r.height()); crop_width=img.height()*tile/r.height()
                                crop=QRectF(max(0,(img.width()-crop_width)/2),0,min(img.width(),crop_width),img.height())
                                p.drawImage(dst,img,crop)
                    if audio and m:
                        peaks=self.editor.visuals.peaks.get(m['id'])
                        if peaks is not None and len(peaks):
                            x0=max(int(r.left()),event.rect().left()); x1=min(int(r.right()),event.rect().right())
                            xs=np.arange(x0,x1,2)
                            indices=np.clip(((c.get('in',0)+(xs-r.left())/self.zoom*c.get('speed',1))*100).astype(int),0,len(peaks)-1)
                            amps=peaks[indices]*min(1,c.get('volume',1))*(r.height()/2-3)
                            p.setPen(QPen(QColor('#a3dfb9'),1)); mid=r.center().y()
                            p.drawLines([QLineF(float(x),mid-float(a),float(x),mid+float(a)) for x,a in zip(xs,amps)])
                    if not audio:
                        name=title.get('names','Titolo') if title is not None else m['name'] if m else 'File mancante'
                        if isinstance(name,list): name=' / '.join(name)
                        name=str(name).replace('\n',' / ')
                        p.setFont(QFont('Segoe UI',8,QFont.Weight.DemiBold))
                        text_width=min(r.width()-7,p.fontMetrics().horizontalAdvance(name)+8)
                        p.fillRect(QRectF(r.left()+2,r.top()+2,max(0,text_width),14),QColor(8,20,32,195))
                        p.setPen(QColor('#eef4f8')); p.drawText(r.adjusted(5,1,-3,-1),Qt.AlignmentFlag.AlignTop,name)
                    p.restore(); p.setBrush(Qt.BrushStyle.NoBrush)
                    p.setPen(QPen(QColor('#f1f3f6' if selected else '#4779a9' if not audio else '#4eaa78'),1.5 if selected else 1))
                    p.drawRoundedRect(r.adjusted(.6,.6,-.6,-.6),2,2)
            cy=self.row_y(len(self.rows())-1); p.fillRect(0,cy,width,32,QColor('#142133')); p.setPen(QColor('#b7c3cf')); p.drawText(7,cy+20,'CC')
            icon('eye','#384c5e' if self.editor.project.data['tracks'].get('captionsHidden') else '#738494').paint(p,self.left-26,cy+7,17,16)
            for caption in self.editor.project.data.get('captions',[]):
                r=self.caption_rect(caption); p.setPen(QPen(QColor('#fff3ad' if caption['id']==self.editor.selected_caption else '#a8953e'),1.5))
                p.setBrush(QColor('#594e22')); p.drawRoundedRect(r,2,2); p.save(); p.setClipRect(r)
                p.setPen(QColor('#fff1b9')); p.drawText(r.adjusted(4,2,-3,-1),' '.join(w['w'] for w in caption.get('words',[]))); p.restore()
            if self.drag and self.drag[0]=='box':
                p.setPen(QPen(QColor('#e4ca4a'),1)); p.setBrush(QColor(228,202,74,35)); p.drawRect(QRectF(self.drag[1],self.drag[2]).normalized())
            for marker in self.editor.project.data.get('markers',[]):
                mx=self.left+marker.get('t',marker.get('time',0))*self.zoom
                p.setPen(QPen(QColor(marker.get('color','#e4ca4a')),1)); p.drawLine(QPointF(mx,self.top-5),QPointF(mx,self.height()))
                p.setBrush(QColor(marker.get('color','#e4ca4a'))); p.drawPolygon(QPolygonF([QPointF(mx-5,2),QPointF(mx+5,2),QPointF(mx,9)]))
                if marker.get('name'): p.drawText(int(mx+4),self.top-7,marker['name'][:24])
            x=self.left+self.editor.position*self.zoom
            p.setPen(QPen(QColor('#f03d47'),1)); p.drawLine(QPointF(x,12),QPointF(x,self.height()))
            p.setBrush(QColor('#f03d47')); p.drawPolygon(QPolygonF([QPointF(x-5,4),QPointF(x+5,4),QPointF(x+5,12),QPointF(x,18),QPointF(x-5,12)]))
            p.end()
        def mousePressEvent(self,event):
            if event.button()!=Qt.MouseButton.LeftButton: return
            self.setFocus(); pos=event.position(); self.editor.pause()
            additive=not self.editor.razor and bool(event.modifiers() & (Qt.KeyboardModifier.ControlModifier|Qt.KeyboardModifier.ShiftModifier))
            if pos.y()>=self.row_y(len(self.rows())-1):
                if pos.x()<self.left:
                    self.editor.checkpoint(); tracks=self.editor.project.data['tracks']; tracks['captionsHidden']=not tracks.get('captionsHidden',False); self.editor.changed(); return
                caption=self.caption_at(pos)
                if caption:
                    self.editor.select_caption(caption['id'])
                    if self.editor.razor: self.editor.split_caption(caption,self.time_at(pos.x())); return
                    r=self.caption_rect(caption); mode='left' if pos.x()-r.left()<7 else 'right' if r.right()-pos.x()<7 else 'move'
                    self.drag=('caption',caption['id'],mode,pos.x(),copy.deepcopy(caption),self.editor.snapshot()); return
            if pos.x()<self.left and pos.y()>=self.top:
                row=next((i for i,r in enumerate(self.rows()[:-1]) if self.row_y(i)<=pos.y()<self.row_y(i)+r[3]),None)
                if row is not None:
                    if row==0:
                        self.editor.checkpoint(); tracks=self.editor.project.data['tracks']; tracks['titlesHidden']=not tracks.get('titlesHidden',False); self.editor.changed()
                    else:
                        _,lane,audio,_=self.rows()[row]; key='audioMuted' if audio else 'videoHidden'
                        self.editor.toggle_track(key,lane,not self.editor.project.data['tracks'][key][lane])
                return
            c=self.at(pos)
            if c:
                if additive:
                    ids={v['id'] for v in self.editor.selected_clips()}
                    if c['id'] in ids: ids.remove(c['id'])
                    else: ids.add(c['id'])
                    self.editor.selection=ids; self.editor.selected=next(iter(ids),None); self.editor.selected_caption=None; self.editor.update_inspector(); self.update()
                    if c['id'] not in ids: return
                elif c['id'] not in {v['id'] for v in self.editor.selected_clips()}: self.editor.select(c['id'])
                self.editor.gap=None
                self.editor.sequence_preview.invalidate()
                if self.editor.razor: self.editor.cut(self.time_at(pos.x()),all_tracks=bool(event.modifiers()&Qt.KeyboardModifier.ShiftModifier)); return
                r=self.clip_rect(c); edge=min(7,max(1,r.width()*.2)); mode='left' if pos.x()-r.left()<edge else ('right' if r.right()-pos.x()<edge else 'move')
                if event.modifiers()&Qt.KeyboardModifier.AltModifier:
                    before=self.editor.snapshot(); copies=copy.deepcopy(self.editor.selected_clips() or [c]); ids=set()
                    for item in copies:item['id']=uid(); item['start']+=1/self.editor.project.settings['fps']; ids.add(item['id'])
                    self.editor.project.clips.extend(copies); self.editor.selection=ids; self.editor.selected=copies[0]['id']; c=copies[0]
                    self.editor.group_originals=copy.deepcopy(copies); self.drag=(c['id'],'move',pos.x(),copy.deepcopy(c),before)
                else:self.drag=(c['id'],mode,pos.x(),copy.deepcopy(c),self.editor.snapshot())
                self.group_originals=copy.deepcopy(self.editor.selected_clips())
            else:
                if pos.y()<self.top:
                    self.editor.seek(self.time_at(pos.x())); self.drag=('scrub',)
                else:
                    base={v['id'] for v in self.editor.selected_clips()} if additive else set()
                    self.editor.select(None); self.drag=('box',pos,pos,base); self.editor.seek(self.time_at(pos.x()))
                    lane=2 if pos.y()<self.row_y(1) else self.track_at(pos.y()); t=self.time_at(pos.x())
                    clips=sorted((c for c in self.editor.project.clips if c['track']==lane),key=lambda c:c['start'])
                    nxt=next((c['start'] for c in clips if c['start']>t),None); prev=max([c['start']+c['duration'] for c in clips if c['start']+c['duration']<=t] or [0])
                    if nxt is not None: self.editor.gap=(lane,prev,nxt)
        def mouseDoubleClickEvent(self,event):
            if event.button()==Qt.MouseButton.LeftButton and event.position().y()<=self.top:
                t=self.time_at(event.position().x()); markers=self.editor.project.data.get('markers',[])
                marker=min(markers,key=lambda m:abs(m.get('t',m.get('time',0))-t),default=None)
                if marker and abs(marker.get('t',marker.get('time',0))-t)<=8/self.zoom:self.editor.edit_marker(marker); return
                self.editor.seek(t); self.editor.add_marker(); return
            super().mouseDoubleClickEvent(event)
        def mouseMoveEvent(self,event):
            pos=event.position()
            if not self.drag:
                c=self.at(pos); edge=c and min(abs(pos.x()-self.clip_rect(c).left()),abs(pos.x()-self.clip_rect(c).right()))<min(7,max(1,self.clip_rect(c).width()*.2))
                self.setCursor(Qt.CursorShape.SizeHorCursor if edge else Qt.CursorShape.ArrowCursor); return
            if self.drag[0]=='scrub': self.editor.seek(self.time_at(pos.x())); return
            if self.drag[0]=='box':
                self.editor.gap=None
                _,origin,_,base=self.drag; self.drag=('box',origin,pos,base); rect=QRectF(origin,pos).normalized()
                ids=base|{c['id'] for c in self.editor.project.clips if rect.intersects(self.clip_rect(c)) or (self.editor.project.item(c) and self.editor.project.item(c).get('hasAudio') and rect.intersects(self.clip_rect(c,True)))}
                self.editor.selection=ids; self.editor.selected=next(iter(ids),None); self.editor.update_inspector(); self.update(); return
            if self.drag[0]=='caption':
                from captions import retime
                _,cid,mode,x,old,_=self.drag; c=next(c for c in self.editor.project.data['captions'] if c['id']==cid)
                delta=round((pos.x()-x)/self.zoom*self.editor.project.settings['fps'])/self.editor.project.settings['fps']
                if mode=='move': start=max(0,old['start']+delta); end=start+old['end']-old['start']
                elif mode=='left': start=max(0,min(old['end']-.05,old['start']+delta)); end=old['end']
                else: start=old['start']; end=max(start+.05,old['end']+delta)
                c.update(copy.deepcopy(old)); retime(c,start,end); self.update(); self.editor.render_preview(); return
            cid,mode,x,old,_=self.drag
            c=next((c for c in self.editor.project.clips if c['id']==cid),None)
            if c is None: return
            delta=(pos.x()-x)/self.zoom; fps=float(self.editor.project.settings['fps']); snap=lambda n:round(n*fps)/fps
            if mode=='move':
                start=max(0,snap(old['start']+delta))
                if self.editor.snapping:
                    points=[self.editor.position]+[v for other in self.editor.project.clips if other['id'] not in {c['id'] for c in self.group_originals} for v in (other['start'],other['start']+other['duration'])]
                    for point in points:
                        if abs(start-point)*self.zoom<8: start=point; break
                        if abs(start+old['duration']-point)*self.zoom<8: start=max(0,point-old['duration']); break
                delta=max(start-old['start'],-min(v['start'] for v in self.group_originals))
                lanes=self.editor.project.lanes
                lane_delta=lanes.index(self.track_at(pos.y()))-lanes.index(old['track']) if old['track']!=2 else 0
                media_originals=[v for v in self.group_originals if v['track']!=2]
                if any(not 0<=lanes.index(v['track'])+lane_delta<len(lanes) for v in media_originals): lane_delta=0
                for original in self.group_originals:
                    item=next(v for v in self.editor.project.clips if v['id']==original['id'])
                    item['start']=original['start']+delta; item['track']=2 if original['track']==2 else lanes[lanes.index(original['track'])+lane_delta]
            elif mode=='left':
                d=max(-old.get('in',0)/old.get('speed',1),min(old['duration']-1/fps,snap(delta))); d=max(-old['start'],d)
                c.update(start=old['start']+d,duration=old['duration']-d); c['in']=old.get('in',0)+d*old.get('speed',1)
            else:
                duration=max(1/fps,snap(old['duration']+delta)); m=self.editor.project.item(c)
                if m and not m.get('still'): duration=min(duration,max(1/fps,(m['duration']-old.get('in',0))/old.get('speed',1)))
                c['duration']=duration
            self.refresh(); self.editor.render_preview()
        def mouseReleaseEvent(self,event):
            if self.drag and self.drag[0] in ('box','scrub'): self.drag=None; self.update(); return
            if self.drag and self.drag[0]=='caption':
                _,cid,mode,x,old,snapshot=self.drag; c=next(c for c in self.editor.project.data['captions'] if c['id']==cid)
                if old!=c: self.editor.undo_stack.append(snapshot); self.editor.redo_stack.clear(); self.editor.changed()
                self.drag=None; return
            if self.drag and len(self.drag)>1:
                cid,mode,x,old,snapshot=self.drag; c=next((c for c in self.editor.project.clips if c['id']==cid),None)
                if c and c!=old:
                    self.editor.undo_stack.append(snapshot); self.editor.redo_stack.clear()
                    for item in self.editor.selected_clips() if mode=='move' else [c]: self.editor.overwrite(item,exclude={v['id'] for v in self.editor.selected_clips()})
                    self.editor.changed()
            self.drag=None
        def wheelEvent(self,event):
            if event.modifiers() & Qt.KeyboardModifier.ControlModifier:
                self.zoom=max(2,min(500,self.zoom*(1.18 if event.angleDelta().y()>0 else 1/1.18))); self.refresh(); event.accept()
            else: super().wheelEvent(event)
        def dragEnterEvent(self,event):
            if event.mimeData().hasUrls() or event.mimeData().hasText(): event.acceptProposedAction()
        def dropEvent(self,event):
            start=self.time_at(event.position().x()); track=self.track_at(event.position().y())
            if event.mimeData().hasUrls(): self.editor.import_paths([u.toLocalFile() for u in event.mimeData().urls()],(track,start))
            else:
                mid=event.mimeData().text()
                if any(m['id']==mid for m in self.editor.project.media): self.editor.append_media(mid,track,start)
            event.acceptProposedAction()

    class Viewer(QLabel):
        def __init__(self,editor):
            super().__init__(); self.editor=editor; self.drag=None
        def mousePressEvent(self,event):
            c=self.editor.pano_target()
            if c and event.button()==Qt.MouseButton.LeftButton:
                self.editor.pause(); self.editor.sequence_preview.invalidate(); self.editor.select(c['id']); self.editor.checkpoint()
                r=c.setdefault('pano',{}); t=self.editor.media_time(c)
                self.drag=(event.position(),view_at(r,t),c['id'])
        def mouseMoveEvent(self,event):
            if not self.drag: return
            pos,old,cid=self.drag; c=next((c for c in self.editor.project.clips if c['id']==cid),None)
            if not c: return
            delta=event.position()-pos; value=dict(old)
            value['yaw']=old['yaw']-delta.x()*old['fov']/max(1,self.width())
            value['pitch']=max(-90,min(90,old['pitch']+delta.y()*old['fov']/max(1,self.width())))
            self.editor.put_pano_view(c,value); self.editor.update_inspector(); self.editor.render_preview()
        def mouseReleaseEvent(self,event):
            if self.drag: self.drag=None; self.editor.changed()

    class Bin(QListWidget):
        def __init__(self,editor):
            super().__init__(); self.editor=editor; self.setDragEnabled(True); self.setAcceptDrops(True)
            self.itemDoubleClicked.connect(lambda item:editor.append_media(item.data(Qt.ItemDataRole.UserRole)))
            self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu); self.customContextMenuRequested.connect(editor.bin_menu)
        def mimeData(self,items):
            from PySide6.QtCore import QMimeData
            mime=QMimeData()
            if items: mime.setText(items[0].data(Qt.ItemDataRole.UserRole))
            return mime
        def dragEnterEvent(self,event):
            if event.mimeData().hasUrls(): event.acceptProposedAction()
            else: super().dragEnterEvent(event)
        def dragMoveEvent(self,event): event.acceptProposedAction()
        def dropEvent(self,event): self.editor.import_paths([u.toLocalFile() for u in event.mimeData().urls()]); event.acceptProposedAction()

    class Editor(QMainWindow,EditingActions,Productivity):
        caption_status=Signal(str)
        preview_progress=Signal(float)
        def __init__(self):
            super().__init__()
            self.project=Project(); self.selected=None; self.position=0; self.playing=False; self.dirty=False
            self.selection=set(); self.selected_caption=None; self.play_rate=1.
            self.gap=None
            self.undo_stack=[]; self.redo_stack=[]; self.clipboard=None; self.razor=False; self.snapping=True
            self.captures={}; self.frame_cache={}; self.title_cache={}; self.jobs=[]; self.pending=False; self.exporting=False
            self.audio=[]; self.updating=False; self.pano_renderers={}
            for _ in range(2):
                player=QMediaPlayer(self); output=QAudioOutput(self); player.setAudioOutput(output); self.audio.append([player,output,None])
            self.setWindowTitle('Elite Studio · Windows'); self.resize(1280,800)
            icon=next((p for p in (ROOT/'Resources'/'EliteStudio.ico',ROOT.parent/'assets'/'icon.png') if p.exists()),ROOT/'Resources'/'EliteStudio.ico')
            if icon.exists(): self.setWindowIcon(QIcon(str(icon)))
            self.build_ui()
            from playback import SequencePreview
            self.sequence_preview=SequencePreview(self.viewer,self)
            from audio_meter import attach
            for player,output,_ in self.audio: attach(self,player,output)
            attach(self,self.sequence_preview.player,self.sequence_preview.output)
            self.sequence_preview.ended.connect(self.pause)
            self.sequence_preview.failed.connect(lambda message:self.statusBar().showMessage('Preview fallback: '+message))
            self.timer=QTimer(self); self.timer.setInterval(33); self.timer.timeout.connect(self.tick); self.timer.start()
            self.autosave=QTimer(self); self.autosave.setSingleShot(True); self.autosave.setInterval(1200); self.autosave.timeout.connect(self.auto_save)
            self.refresh()
            if initial: QTimer.singleShot(100,lambda:self.open_path(initial))
            else: QTimer.singleShot(300,lambda:self.recover_session(automatic=True))
        def build_ui(self):
            from interface import build_ui
            build_ui(self,Viewer,Bin,Timeline)
        def choose_tool(self,razor):
            self.razor=razor
            from interface import icon
            self.select_button.setIcon(icon('select','#e4ca4a' if razor else '#14202a'))
            self.razor_button.setIcon(icon('razor','#14202a' if razor else '#e4ca4a'))
            self.select_button.setChecked(not razor); self.razor_button.setChecked(razor)
            self.tool_label.setText('Lametta' if razor else 'Selezione')
        def set_timeline_zoom(self,value):
            self.timeline.zoom=float(value); self.timeline.refresh()
        def snapshot(self): return copy.deepcopy(self.project.data)
        def checkpoint(self):
            self.undo_stack.append(self.snapshot()); self.undo_stack=self.undo_stack[-80:]; self.redo_stack.clear()
        def undo(self):
            focus=QApplication.focusWidget()
            if isinstance(focus,QLineEdit): focus.undo(); return
            if not self.undo_stack: return
            self.pause(); self.redo_stack.append(self.snapshot()); self.project.data=self.undo_stack.pop(); self.changed()
        def redo(self):
            focus=QApplication.focusWidget()
            if isinstance(focus,QLineEdit): focus.redo(); return
            if not self.redo_stack: return
            self.pause(); self.undo_stack.append(self.snapshot()); self.project.data=self.redo_stack.pop(); self.changed()
        def selected_clip(self): return next((c for c in self.project.clips if c['id']==self.selected),None)
        def select(self,cid):
            self.selected=cid; self.selection={cid} if cid else set(); self.selected_caption=None; self.update_inspector(); self.timeline.update()
            if self.inspector_tabs.currentIndex()==2 or not cid: self.inspector_tabs.setCurrentIndex(0)
            c=self.selected_clip(); m=self.project.item(c) if c else None
            if m and m.get('pano'): self.statusBar().showMessage('Clip 360°: trascina nel viewer per guardarti intorno. Scorri l’ispettore per stabilizzazione, direzione, FOV e keyframe.')
        def changed(self):
            self.pause(); self.sequence_preview.configure(self.project)
            self.dirty=True; self.frame_cache.clear(); self.title_cache.clear(); self.refresh()
            self.autosave.start()
        def refresh(self):
            self.project.ensure_tracks()
            while len(self.audio)<len(self.project.lanes):
                player=QMediaPlayer(self); output=QAudioOutput(self); player.setAudioOutput(output); self.audio.append([player,output,None])
                from audio_meter import attach
                attach(self,player,output)
            self.selection.intersection_update(c['id'] for c in self.project.clips)
            if self.selected and not any(c['id']==self.selected for c in self.project.clips): self.selected=next(iter(self.selection),None)
            from interface import icon
            from PySide6.QtGui import QFont
            from PySide6.QtCore import QSize
            selected=self.bin.currentItem().data(Qt.ItemDataRole.UserRole) if self.bin.currentItem() else None
            self.bin.clear()
            for m in self.project.media:
                missing=not Path(m['path']).is_file()
                duration=m.get('duration',0); dims=f'{int(m.get("width",0))}\u00d7{int(m.get("height",0))}' if m.get('hasVideo') else 'Audio'
                detail='File mancante' if missing else f'{int(duration)//60}:{int(duration)%60:02d} \u00b7 {dims}'+(' \u00b7 360\u00b0' if m.get('pano') else '')
                item=QListWidgetItem(f'{m["name"]}\n{detail}'); item.setData(Qt.ItemDataRole.UserRole,m['id']); item.setToolTip(m['path']); item.setSizeHint(QSize(180,50))
                if missing: item.setIcon(icon('missing','#f04451',32)); item.setForeground(QColor('#ed4a57'))
                else:
                    frames=self.visuals.frames.get(m['id'],[])
                    if frames: item.setIcon(QIcon(QPixmap.fromImage(frames[0][1])))
                    self.visuals.request(m)
                self.bin.addItem(item)
                item.setHidden(self.bin_search.text().casefold() not in item.text().casefold())
                if m['id']==selected: self.bin.setCurrentItem(item)
            self.timeline.refresh(); self.update_inspector(); self.render_preview()
            self.setWindowTitle(f'Elite Studio · Windows · {self.project.path.name if self.project.path else "Senza titolo"}{" *" if self.dirty else ""}')
        def update_inspector(self):
            self.updating=True; c=self.selected_clip(); m=self.project.item(c) if c else None
            self.name.setText('Titolo' if c and 'title' in c else m['name'] if m else 'Seleziona una clip')
            for k,field in self.fields.items():
                field.setEnabled(c is not None); field.setValue(float(c.get(k,1 if k in ['speed','volume','scale','opacity'] else 0)) if c else 0)
            for k,field in self.transform_fields.items():
                field.setEnabled(c is not None); field.setValue(float(c.get('crop',{}).get(k,0)) if c else 0)
            for key,box in [('flipH',self.flip_h),('flipV',self.flip_v),('backgroundBlur',self.background_blur)]:
                box.setEnabled(c is not None); box.setChecked(bool(c.get('flipH' if key=='flipH' else 'flipV',False) if c and key!='backgroundBlur' else c and c.get('background',{}).get('type')=='blur') if c else False)
            labels=[self.project.track_label(i) for i in range(max(3,len(self.project.data['tracks']['videoHidden']))) ]
            if self.track.count()!=len(labels): self.track.clear(); self.track.addItems(labels)
            self.track.setEnabled(c is not None); self.track.setCurrentIndex(c['track'] if c else 0); self.fill.setChecked(c.get('fill',False) if c else False)
            title=c.get('title',{}) if c else {}
            for widget,key,default in [(self.title_names,'names',''),(self.title_tag,'tag','MVP'),(self.title_label,'label','COPPA ÉLITE  /  WINTER EDITION')]:
                value=title.get(key,default); widget.setText(('\n'.join(value) if isinstance(value,list) else value).replace('\n',' | ')); widget.setEnabled(bool(c and 'title' in c))
            tracks=self.project.data['tracks']
            for lane in range(2):
                for key in ['videoHidden','audioMuted']: getattr(self,f'{key}{lane}').setChecked(tracks[key][lane])
            w,h=self.project.settings['width'],self.project.settings['height']
            self.sequence.setCurrentIndex(0 if (w,h)==(1080,1920) else 1 if (w,h)==(1920,1080) else 2 if (w,h)==(1080,1080) else 3)
            is_pano=bool(c and m and (m.get('pano') or 'pano' in c))
            r=c.get('pano',{}) if c else {}
            view=view_at(r,self.media_time(c)) if is_pano else DEFAULT_VIEW
            for key,field in self.pano_fields.items():
                field.setEnabled(is_pano); field.setValue(float(r.get('smooth',1) if key=='smooth' else view[key]))
            self.stabilize_box.setEnabled(is_pano); self.stabilize_box.setChecked(r.get('stabilize',True))
            self.direction_box.setEnabled(is_pano); self.direction_box.setChecked(r.get('lockDirection',False))
            self.add_key_button.setEnabled(is_pano); self.remove_key_button.setEnabled(is_pano and bool(r.get('keys')))
            from interface import update_design
            update_design(self)
            self.update_caption_fields()
            self.update_layout_fields()
            self.update_effect_fields()
            self.title_style.setCurrentIndex(1 if title.get('style')=='text' else 0)
            self.updating=False
        def pano_target(self):
            c=self.selected_clip()
            if c and self.project.item(c) and (self.project.item(c).get('pano') or 'pano' in c): return c
            return next((c for c in sorted(self.project.clips,key=lambda c:c['track'],reverse=True) if c['start']<=self.position<c['start']+c['duration'] and self.project.item(c) and self.project.item(c).get('pano')),None)
        def media_time(self,c):
            return c.get('in',0)+max(0,min(c['duration']-.001,self.position-c['start']))*c.get('speed',1)
        def put_pano_view(self,c,view):
            r=c.setdefault('pano',{}); keys=r.get('keys',[]); t=self.media_time(c)
            if keys:
                tolerance=c.get('speed',1)/self.project.settings['fps']*.5
                key=next((key for key in keys if abs(key['t']-t)<=tolerance),None)
                if key: key['view']=view
                else: keys.append(dict(t=t,view=view)); keys.sort(key=lambda k:k['t'])
            else: r.update(view)
        def set_pano(self,key):
            if self.updating: return
            c=self.pano_target()
            if not c: return
            value=self.pano_fields[key].value(); r=c.setdefault('pano',{})
            if key=='smooth':
                if abs(r.get(key,1)-value)<.0001: return
                self.checkpoint(); r[key]=value
            else:
                view=view_at(r,self.media_time(c))
                if abs(view[key]-value)<.0001: return
                self.checkpoint(); view[key]=value; self.put_pano_view(c,view)
            self.changed()
        def set_pano_flag(self,key,value):
            if self.updating: return
            c=self.pano_target()
            if not c: return
            self.checkpoint(); c.setdefault('pano',{})[key]=value; self.changed()
        def add_pano_key(self):
            c=self.pano_target()
            if not c: return
            self.checkpoint(); r=c.setdefault('pano',{}); t=self.media_time(c); view=view_at(r,t)
            keys=r.setdefault('keys',[])
            if not any(abs(key['t']-t)<.5/self.project.settings['fps'] for key in keys): keys.append(dict(t=t,view=view)); keys.sort(key=lambda k:k['t'])
            self.changed()
        def remove_pano_key(self):
            c=self.pano_target()
            if not c: return
            r=c.setdefault('pano',{}); keys=r.get('keys',[])
            if not keys: return
            self.checkpoint(); t=self.media_time(c); view=view_at(r,t); nearest=min(keys,key=lambda k:abs(k['t']-t)); keys.remove(nearest)
            if not keys: r.update(view)
            self.changed()
        def pano_preset(self,preset):
            c=self.pano_target()
            if not c: return
            self.checkpoint(); view=view_at(c.get('pano',{}),self.media_time(c)); view.update(preset); self.put_pano_view(c,view); self.changed()
        def set_property(self,key):
            c=self.selected_clip()
            if self.updating or not c: return
            value=self.transform_fields[key[5:]].value() if key.startswith('crop_') else self.fields[key].value()
            from effects import at
            if key.startswith('crop_'):
                field=key[5:]; previous=c.get('crop',{}).get(field,0); value=max(0,min(.45,value))
                if value+ c.get('crop',{}).get({'left':'right','right':'left','top':'bottom','bottom':'top'}[field],0)>.85: value=.85-c.get('crop',{}).get({'left':'right','right':'left','top':'bottom','bottom':'top'}[field],0)
                if abs(float(previous)-value)<.00001:return
                self.checkpoint(); c.setdefault('crop',{})[field]=value; self.changed(); return
            previous=at(c,self.position-c['start']).get(key,c.get(key,1 if key in ['speed','volume','opacity','scale'] else 0))
            if abs(float(previous)-value)<.00001: return
            self.checkpoint()
            if key in ('x','y','scale','opacity','volume') and c.get('effects',{}).get('keys'):
                self.store_motion_key(c,{key:value}); self.changed(); return
            if key=='speed':
                from editing import change_speed
                change_speed(self.project,c,value)
            c[key]=value
            if key in ['in','duration','speed']:
                m=self.project.item(c)
                if m and not m.get('still'):
                    c['in']=min(c.get('in',0),max(0,m['duration']-.01)); c['duration']=min(c['duration'],max(.01,(m['duration']-c['in'])/c.get('speed',1)))
            self.changed()
        def set_track(self,index):
            c=self.selected_clip()
            if self.updating or not c: return
            if (index==2)!=('title' in c): self.update_inspector(); return
            self.checkpoint(); c['track']=index; self.overwrite(c); self.changed()
        def set_fill(self,value):
            c=self.selected_clip()
            if self.updating or not c: return
            self.checkpoint(); c['fill']=value; self.changed()
        def set_clip_flag(self,key,value):
            c=self.selected_clip()
            if self.updating or not c:return
            self.checkpoint()
            if key=='backgroundBlur':
                if value:c['background']={'type':'blur','amount':12}
                else:c.pop('background',None)
            else:c[key]=value
            self.changed()
        def set_title(self):
            c=self.selected_clip()
            if self.updating or not c or 'title' not in c: return
            new=dict(names=self.title_names.text().replace(' | ','\n').replace('|','\n'),tag=self.title_tag.text(),label=self.title_label.text())
            if all(c['title'].get(k)==v for k,v in new.items()): return
            self.checkpoint(); c['title'].update(new); self.changed()
        def toggle_track(self,key,lane,value):
            if self.updating: return
            self.checkpoint(); self.project.data['tracks'][key][lane]=value; self.changed()
        def sequence_changed(self,index):
            sizes=[(1080,1920),(1920,1080),(1080,1080)]
            if index==3:
                text,ok=QInputDialog.getText(self,'Formato sequenza','Larghezza x altezza @ fps',text=f'{self.project.settings["width"]}x{self.project.settings["height"]}@{self.project.settings["fps"]}')
                if not ok: self.update_inspector(); return
                try:
                    size,fps=text.split('@'); w,h=map(int,size.lower().split('x')); fps=float(fps)
                    if not (16<=w<=8192 and 16<=h<=8192 and 1<=fps<=120): raise ValueError()
                except ValueError: self.error('Inserisci larghezza x altezza @ fps, per esempio 1920x1080@30.'); return
            else: w,h=sizes[index]; fps=self.project.settings.get('fps',30)
            self.checkpoint(); self.project.settings.update(width=w,height=h,fps=fps,customized=True); self.changed()
        def run_job(self,work,done,on_error=None):
            sig=Signals(); self.jobs.append(sig)
            def finished(value):
                try: done(value)
                finally:
                    if sig in self.jobs: self.jobs.remove(sig)
            def failed(message):
                if on_error: on_error()
                self.pending=False; self.error(message)
                if sig in self.jobs: self.jobs.remove(sig)
            sig.done.connect(finished); sig.error.connect(failed)
            def run():
                try: sig.done.emit(work())
                except Exception as e: sig.error.emit(str(e))
            threading.Thread(target=run,daemon=True).start()
        def error(self,text): QMessageBox.warning(self,'Elite Studio',str(text))
        def import_dialog(self):
            paths,_=QFileDialog.getOpenFileNames(self,'Importa video, audio o foto','','Media (*.mp4 *.mov *.m4v *.mkv *.avi *.webm *.mp3 *.wav *.m4a *.aac *.flac *.png *.jpg *.jpeg *.webp *.heic *.tif *.insv);;Tutti i file (*)')
            if paths: self.import_paths(paths)
        def import_paths(self,paths,drop=None):
            if self.pending: self.statusBar().showMessage('Attendi la fine dell’operazione in corso.'); return
            expanded=[]
            for path in paths:
                p=Path(path)
                if p.is_dir(): expanded.extend(str(f) for f in sorted(p.iterdir()) if f.suffix.lower() in VIDEO|AUDIO|IMAGES and not secondary(f))
                else: expanded.append(str(p))
            expanded=list(dict.fromkeys(str(primary(path)) for path in expanded if not Path(path).name.upper().startswith('LRV_')))
            if not expanded: return
            self.pending=True; self.statusBar().showMessage('Lettura dei file…')
            def work():
                results=[]; errors=[]
                for path in expanded:
                    try: results.append(probe(path))
                    except Exception as e: errors.append(str(e))
                return results,errors
            def done(result):
                self.pending=False; items,errors=result
                if items:
                    self.checkpoint(); start=drop[1] if drop else None
                    for m in items:
                        existing=next((old for old in self.project.media if old['path']==m['path']),None)
                        if existing: m=existing
                        else:
                            if not self.project.media and not self.project.clips and m['hasVideo'] and not self.project.settings.get('customized'):
                                portrait=m['height']>m['width']; self.project.settings.update(width=1080 if portrait else 1920,height=1920 if portrait else 1080)
                            self.project.media.append(m)
                        if drop:
                            c=self.project.add_clip(m['id'],drop[0],start); self.overwrite(c); start=c['start']+c['duration']
                    self.changed()
                self.statusBar().showMessage(f'Importati {len(items)} file. Doppio clic su un file per aggiungerlo alla timeline.')
                if errors: self.error('\n'.join(errors))
                if not errors: QTimer.singleShot(500,lambda:self.start_proxies(automatic=True))
            self.run_job(work,done)
        def append_media(self,mid,track=0,start=None):
            self.checkpoint(); c=self.project.add_clip(mid,track,start); self.overwrite(c); self.select(c['id']); self.changed()
        def overwrite(self,clip,exclude=()):
            if 'title' in clip: return
            a,b=clip['start'],clip['start']+clip['duration']; fragments=[]
            for other in self.project.clips[:]:
                if other is clip or other['id'] in exclude or other['track']!=clip['track']: continue
                item=self.project.item(clip); other_item=self.project.item(other)
                if item and other_item and bool(item.get('hasVideo',True))!=bool(other_item.get('hasVideo',True)): continue
                x,y=other['start'],other['start']+other['duration']
                if x>=b-.0001 or y<=a+.0001: continue
                self.project.clips.remove(other)
                if x<a-.0001:
                    left=copy.deepcopy(other); left['duration']=a-x; fragments.append(left)
                if y>b+.0001:
                    right=copy.deepcopy(other); right.update(id=uid(),start=b,duration=y-b); right['in']=other.get('in',0)+(b-x)*other.get('speed',1); fragments.append(right)
            self.project.clips.extend(fragments)
        def add_title(self):
            self.checkpoint(); c=dict(id=uid(),track=2,start=self.position,duration=3,**{'in':0,'speed':1},title=dict(names='Nome Cognome',tag='MVP',label='COPPA ÉLITE  /  WINTER EDITION'))
            self.project.clips.append(c); self.select(c['id']); self.changed()
        def cut(self,when=None,all_tracks=False):
            if isinstance(when,bool) or when is None: when=self.position
            if self.caption() and not all_tracks: self.split_caption(self.caption(),when); return
            targets=[c['id'] for c in self.selected_clips()] if self.selected_clips() and not all_tracks else [c['id'] for c in self.project.clips]; snapshot=self.snapshot(); changed=False
            for cid in targets: changed=self.project.split(cid,when) or changed
            if changed: self.undo_stack.append(snapshot); self.redo_stack.clear(); self.changed()
        def delete(self,ripple=False):
            caption=self.caption()
            if caption:
                self.checkpoint(); self.project.data['captions'].remove(caption); self.selected_caption=None; self.changed(); return
            clips=self.selected_clips()
            if not clips and self.gap:
                lane,a,b=self.gap; self.checkpoint()
                if not any(c['start']<b-1e-6 and c['start']+c['duration']>a+1e-6 for c in self.project.clips):
                    from editing import extract
                    extract(self.project,a,b)
                else:
                    for c in self.project.clips:
                        if c['track']==lane and c['start']>=b-1e-6: c['start']-=b-a
                self.gap=None; self.changed(); return
            if not clips: return
            self.checkpoint()
            if ripple:
                from editing import extract
                intervals=[]
                for c in sorted(clips,key=lambda c:c['start']):
                    a,b=c['start'],c['start']+c['duration']
                    if intervals and a<=intervals[-1][1]: intervals[-1][1]=max(intervals[-1][1],b)
                    else: intervals.append([a,b])
                for a,b in reversed(intervals): extract(self.project,a,b)
                self.position=min(self.position,self.project.duration)
            else:
                ids={c['id'] for c in clips}; self.project.data['clips']=[c for c in self.project.clips if c['id'] not in ids]
            self.select(None); self.changed()
        def copy_clip(self):
            focus=QApplication.focusWidget()
            if isinstance(focus,(QLineEdit,QTextEdit)): focus.copy(); return
            if self.selected_clips(): self.clipboard=copy.deepcopy(self.selected_clips())
        def paste_clip(self):
            focus=QApplication.focusWidget()
            if isinstance(focus,(QLineEdit,QTextEdit)): focus.paste(); return
            if self.clipboard:
                self.checkpoint(); clips=copy.deepcopy(self.clipboard); start=min(c['start'] for c in clips)
                for c in clips: c.update(id=uid(),start=self.position+c['start']-start)
                self.project.clips.extend(clips); ids={c['id'] for c in clips}
                for c in clips: self.overwrite(c,exclude=ids)
                self.selection=ids; self.selected=clips[0]['id']; self.selected_caption=None; self.changed()
        def confirm_leave(self):
            if not self.dirty: return True
            answer=QMessageBox.question(self,'Progetto non salvato','Salvare le modifiche al progetto?',QMessageBox.StandardButton.Save|QMessageBox.StandardButton.Discard|QMessageBox.StandardButton.Cancel)
            if answer==QMessageBox.StandardButton.Cancel: return False
            if answer==QMessageBox.StandardButton.Save: return self.save()
            return True
        def new_project(self):
            if self.pending or self.exporting: self.error('Wait for the current operation to finish.'); return
            if self.confirm_leave(): self.reset(Project())
        def reset(self,project):
            self.pause(); self.autosave.stop()
            for state in self.audio: state[0].stop(); state[0].setSource(QUrl()); state[2]=None
            for cap in self.captures.values(): cap.release()
            for renderer in self.pano_renderers.values(): renderer.close()
            self.pano_renderers.clear()
            self.captures.clear(); self.frame_cache.clear(); self.title_cache.clear()
            self.project=project; self.selected=None; self.position=0; self.undo_stack=[]; self.redo_stack=[]; self.dirty=False
            from storage import discard_recovery
            discard_recovery()
            self.selection.clear(); self.selected_caption=None; self.play_rate=1.
            self.gap=None
            self.sequence_preview.configure(project); self.refresh()
        def open_dialog(self):
            path,_=QFileDialog.getOpenFileName(self,'Apri progetto','','Elite Studio (*.elitestudio *.json)')
            if path: self.open_path(path)
        def open_path(self,path):
            if self.pending or self.exporting: self.error('Wait for the current operation to finish.'); return
            if not self.confirm_leave(): return
            try: project=Project.load(path)
            except Exception as e: self.error(str(e)); return
            self.reset(project); self.fit()
            if not project.missing: QTimer.singleShot(500,lambda:self.start_proxies(automatic=True))   # 4K: smooth playback
            if project.data.get('reviewStart'): self.seek(float(project.data['reviewStart']))
            if project.missing: self.error('File mancanti dal computer originale. Usa File > Ricollega file mancanti.\n\n'+'\n'.join(project.missing))
        def save(self):
            if not self.project.path: return self.save_as()
            try:
                from storage import backup
                backup(self.project.path); self.project.save(); self.dirty=False; self.setWindowTitle(f'Elite Studio · Windows — {self.project.path.name}'); self.statusBar().showMessage(f'Salvato {self.project.path}'); return True
            except Exception as e: self.error(str(e)); return False
        def save_as(self):
            path,_=QFileDialog.getSaveFileName(self,'Salva progetto',str(self.project.path or 'Montaggio.elitestudio'),'Elite Studio (*.elitestudio)')
            if not path: return False
            if not path.lower().endswith('.elitestudio'): path+='.elitestudio'
            try:
                from storage import backup
                backup(path); self.project.save(path); self.dirty=False; self.refresh(); return True
            except Exception as e: self.error(str(e)); return False
        def auto_save(self):
            from storage import snapshot
            if self.dirty:
                try: snapshot(self.project)
                except OSError as exc: self.statusBar().showMessage(f'Recupero automatico non disponibile: {exc}')
            if self.project.path and self.dirty: self.save()
        def relink(self):
            folder=QFileDialog.getExistingDirectory(self,'Scegli la cartella con i file originali')
            if not folder: return
            self.checkpoint(); candidates={}
            for p in Path(folder).rglob('*'):
                if p.is_file() and p.suffix.lower() in VIDEO|AUDIO|IMAGES: candidates.setdefault(p.name.lower(),[]).append(p)
            count=0; ambiguous=[]
            for m in self.project.media:
                if Path(m['path']).is_file(): continue
                name=m['path'].replace('\\','/').rsplit('/',1)[-1].lower(); matches=candidates.get(name,[])
                if len(matches)==1:
                    try:
                        info=probe(matches[0]); m.update({k:v for k,v in info.items() if k not in ['id','name']}); count+=1
                    except Exception as e: self.error(str(e))
                elif len(matches)>1: ambiguous.append(name)
            self.changed(); self.statusBar().showMessage(f'Ricollegati {count} file.')
            if ambiguous: self.error('Più file con lo stesso nome. Scegli una cartella più specifica per:\n'+'\n'.join(ambiguous))
        def export_dialog(self):
            if self.exporting: return
            self.pause()
            if self.project.duration<=0: self.error('Aggiungi prima delle clip alla timeline.'); return
            from export_options import choose,apply_preset
            options=choose(self)
            if options is None: return
            path,_=QFileDialog.getSaveFileName(self,'Esporta MP4',str(self.project.path.with_suffix('.mp4') if self.project.path else 'Montaggio.mp4'),'Video MP4 (*.mp4)')
            if not path: return
            if not path.lower().endswith('.mp4'): path+='.mp4'
            project=Project(); project.data=self.snapshot(); self.exporting=True; cancel=threading.Event()
            apply_preset(project,options['preset'])
            dialog=QProgressDialog('Esportazione MP4…','Annulla',0,100,self); dialog.setWindowTitle('Elite Studio - Esportazione')
            dialog.setWindowModality(Qt.WindowModality.WindowModal); dialog.setMinimumDuration(0); dialog.canceled.connect(cancel.set)
            signals=Signals(); self.jobs.append(signals); signals.progress.connect(lambda n:dialog.setValue(int(n*100)))
            def finish(result):
                self.exporting=False; dialog.close(); self.jobs.remove(signals)
                if result: self.error(result)
                else: self.statusBar().showMessage(f'Esportazione completata: {path}'); QMessageBox.information(self,'Esportazione completata',f'Video salvato:\n{path}')
            signals.done.connect(finish)
            def run():
                try: export(project,path,signals.progress.emit,cancel,hevc=options['hevc'],hardware=options['hardware'],quality=options['quality'],bitrate=options['bitrate']); signals.done.emit(None)
                except Exception as e: signals.done.emit(str(e))
            threading.Thread(target=run,daemon=True).start()
        def seek(self,position):
            self.position=max(0,min(float(position),self.project.duration))
            if self.sequence_preview.valid:
                self.sequence_preview.seek(self.position); self.update_clock()
            else: self.render_preview(); self.sync_audio(True)
            if not self.playing and hasattr(self,'effect_fields'):
                self.updating=True; self.update_effect_fields(); self.updating=False
        def toggle(self): self.pause() if self.playing else self.play()
        def play(self):
            if not self.project.duration: return
            if self.position>=self.project.duration and self.play_rate>0: self.position=0
            self.sequence_preview.configure(self.project)
            self.anchor=time.monotonic()-self.position; self.playing=True
            self.last_tick=time.monotonic()
            if self.play_rate<0: self.sequence_preview.invalidate()
            from interface import icon
            self.play_action.setText('Pause'); self.play_button.setText(''); self.play_button.setIcon(icon('pause'))
            self.visuals.suspended.set()
            if self.sequence_preview.valid:
                for state in self.audio: state[0].pause()
                self.sequence_preview.play(self.position)
                self.sequence_preview.player.setPlaybackRate(self.play_rate)
            else: self.sync_audio(True)
        def pause(self):
            if hasattr(self,'sequence_preview') and self.sequence_preview.valid:
                self.sequence_preview.pause()
                if self.playing: self.position=min(self.project.duration,self.sequence_preview.position())
            self.playing=False
            self.play_rate=1.
            from interface import icon
            self.play_action.setText('Play'); self.play_button.setText(''); self.play_button.setIcon(icon('play'))
            if hasattr(self,'visuals'): self.visuals.suspended.clear()
            for player,output,cid in self.audio: player.pause()
        def tick(self):
            if not self.playing: return
            if self.sequence_preview.valid and self.play_rate>0:
                self.position=min(self.project.duration,self.sequence_preview.position()); self.update_clock()
            else:
                now=time.monotonic(); delta=now-getattr(self,'last_tick',now); self.last_tick=now
                self.position=max(0,min(self.project.duration,self.position+delta*self.play_rate)); self.render_preview(); self.sync_audio()
            if self.position>=self.project.duration or (self.play_rate<0 and self.position<=0): self.pause()
        def sync_audio(self,force=False):
            if self.sequence_preview.valid:
                for state in self.audio: state[0].pause()
                return
            for lane,state in zip(self.project.lanes,self.audio):
                player,output,current=state
                active=[c for c in self.project.clips if c['track']==lane and c['start']<=self.position<c['start']+c['duration'] and self.project.item(c) and self.project.item(c).get('hasAudio')]
                c=active[-1] if active else None
                if c and not self.project.data['tracks']['audioMuted'][lane]:
                    m=self.project.item(c); changed=current!=c['id']
                    if changed: player.setSource(QUrl.fromLocalFile(m['path'])); state[2]=c['id']
                    from effects import at,envelope
                    gain=at(c,self.position-c['start'])['volume']*envelope(c,self.position-c['start'],True)
                    player.setPlaybackRate(c.get('speed',1)*max(.1,self.play_rate)); output.setVolume(min(1,gain) if self.play_rate>0 else 0)
                    source=round((c.get('in',0)+(self.position-c['start'])*c.get('speed',1))*1000)
                    if force or changed: player.setPosition(source)
                    if self.playing:
                        if player.playbackState()!=QMediaPlayer.PlaybackState.PlayingState: player.play()
                    else: player.pause()
                else: player.pause(); state[2]=None
        def update_clock(self):
            def stamp(t):
                rate=max(1,round(self.project.settings['fps']));frames=round(t*self.project.settings['fps']);seconds=frames//rate
                return f'{seconds//3600:02d}:{seconds//60%60:02d}:{seconds%60:02d}:{frames%rate:02d}'
            self.time_label.setText(stamp(self.position)); self.duration_label.setText(stamp(self.project.duration)); self.timeline.update()
        def frame(self,m,t,reframe=None,size=None):
            key=m['id']
            if not Path(m['path']).is_file(): return None
            try:
                if reframe is not None or m.get('pano'):
                    if key not in self.pano_renderers: self.pano_renderers[key]=PanoRenderer(m['path'])
                    bgr=self.pano_renderers[key].render(t,*(size or (640,360)),reframe)
                    return Image.fromarray(cv2.cvtColor(bgr,cv2.COLOR_BGR2RGBA))
                if m.get('still'):
                    with Image.open(m['path']) as im:
                        from PIL import ImageOps
                        return ImageOps.exif_transpose(im).convert('RGBA')
                if key not in self.captures:
                    while len(self.captures)>=4:
                        old_key=next(iter(self.captures));self.captures.pop(old_key).release();self.frame_cache.pop(old_key,None)
                    source=Path(m.get('proxyPath',m['path']))
                    if not source.is_absolute() and self.project.path: source=self.project.path.parent/source
                    self.captures[key]=cv2.VideoCapture(str(source if source.is_file() else m['path']))
                cap=self.captures[key]; fps=cap.get(cv2.CAP_PROP_FPS) or 30; index=round(t*fps); old=self.frame_cache.get(key)
                if old and old[0]==index and old[1]==size: return old[2]
                next_index=round(cap.get(cv2.CAP_PROP_POS_FRAMES));delta=index-next_index
                if 0<=delta<=12:
                    for _ in range(delta): cap.grab()
                elif delta and self.playing and 0<delta<=fps*3: pass   # running late (heavy 4K/10-bit): show the next frame, a seek would freeze ~1 s
                elif delta: cap.set(cv2.CAP_PROP_POS_MSEC,t*1000)
                ok,bgr=cap.read()
                if not ok: return None
                if size:
                    # Shrink 4K frames here (OpenCV, a few ms) instead of converting the whole frame first (~70 ms).
                    ih,iw=bgr.shape[:2]; k=max(size[0]/iw,size[1]/ih)
                    if k<.75: bgr=cv2.resize(bgr,(max(2,round(iw*k)),max(2,round(ih*k))),interpolation=cv2.INTER_LINEAR if self.playing else cv2.INTER_AREA)
                im=Image.fromarray(cv2.cvtColor(bgr,cv2.COLOR_BGR2RGBA)); self.frame_cache[key]=(index,size,im); return im
            except Exception as e:
                self.statusBar().showMessage(str(e)); return None
        def render_preview(self):
            if hasattr(self,'sequence_preview') and self.sequence_preview.valid:
                self.update_clock(); return
            w0,h0=int(self.project.settings['width']),int(self.project.settings['height'])
            ratio=min(max(100,self.viewer.width()-8)/w0,max(100,self.viewer.height()-8)/h0,getattr(self,'preview_limit',720)/max(w0,h0))
            w,h=max(2,int(w0*ratio)),max(2,int(h0*ratio)); canvas=Image.new('RGBA',(w,h),'black'); tracks=self.project.data['tracks']; warning=False
            for c in sorted(self.project.clips,key=lambda c:(99 if 'title' in c else c['track'],c['start'])):
                if not c['start']<=self.position<c['start']+c['duration']: continue
                title=c.get('title'); m=self.project.item(c)
                if title is not None:
                    if tracks.get('titlesHidden'): continue
                    key=(c['id'],w,h)
                    if key not in self.title_cache: self.title_cache[key]=title_image(title,(w,h))
                    image=self.title_cache[key].copy(); elapsed=self.position-c['start']; remaining=c['duration']-elapsed; fade=float(title.get('fade',.4))
                    alpha=min(1,elapsed/fade,remaining/fade) if fade else 1
                    animation=title.get('animationIn','Nessuna')
                    if animation=='Dissolvenza':alpha=min(alpha,max(0,elapsed/.35))
                    if animation=='Macchina da scrivere':alpha=min(alpha,max(0,elapsed/.7))
                    if animation=='Scorri su':image=image.transform(image.size,Image.Transform.AFFINE,(1,0,0,0,1,round(h*.12*(1-min(1,elapsed/.35)))))
                    if title.get('animationOut') in ('Dissolvenza','Scorri su','Pop/Scala') and remaining<.35:alpha*=max(0,remaining/.35)
                    if alpha<1: image.putalpha(image.getchannel('A').point(lambda x:int(x*max(0,alpha))))
                    oy=round((h-image.height)/2)
                    if title.get('animationOut')=='Scorri su' and remaining<.35:oy-=round(h*.12*(1-remaining/.35))
                    if title.get('animationOut')=='Pop/Scala' and remaining<.35:
                        scale=.7+.3*max(0,remaining/.35); image=image.resize((max(1,round(image.width*scale)),max(1,round(image.height*scale))),Image.Resampling.BILINEAR); oy=(h-image.height)//2
                    canvas.alpha_composite(image,((w-image.width)//2,oy))
                elif m and m.get('hasVideo',True) and not tracks['videoHidden'][c['track']]:
                    image=self.frame(m,c.get('in',0)+(self.position-c['start'])*c.get('speed',1),c.get('pano',{}) if m.get('pano') or 'pano' in c else None,(w,h))
                    if image is None: warning=True; continue
                    from effects import color,at,envelope,chroma
                    motion=at(c,self.position-c['start'])
                    crop=c.get('crop',{}); l,r,t,b=(max(0,min(.45,float(crop.get(k,0)))) for k in ('left','right','top','bottom'))
                    if l+r or t+b:image=image.crop((round(image.width*l),round(image.height*t),max(1,round(image.width*(1-r))),max(1,round(image.height*(1-b)))))
                    if c.get('flipH'):image=image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                    if c.get('flipV'):image=image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
                    iw,ih=image.size; factor=(max if c.get('fill') else min)(w/iw,h/ih)
                    iw,ih=max(1,round(iw*factor)),max(1,round(ih*factor)); image=image.resize((iw,ih),Image.Resampling.BILINEAR)
                    image=chroma(color(image,c.get('effects',{})),c.get('chromaKey'))
                    if c.get('background',{}).get('type')=='blur' and not c.get('fill'):
                        from PIL import ImageFilter
                        bgfactor=max(w/iw,h/ih); bw,bh=max(w,round(iw*bgfactor)),max(h,round(ih*bgfactor)); bg=image.resize((bw,bh),Image.Resampling.BILINEAR)
                        blur_scale=min(w/w0,h/h0)
                        bg=bg.crop(((bw-w)//2,(bh-h)//2,(bw+w)//2,(bh+h)//2)).filter(ImageFilter.BoxBlur(radius=max(1,min(50,float(c['background'].get('amount',12))*blur_scale))))
                        surface=bg.convert('RGBA')
                    else:surface=Image.new('RGBA',(w,h))
                    surface.alpha_composite(image,(round((w-iw)/2),round((h-ih)/2)))
                    sw,sh=max(1,round(w*motion['scale'])),max(1,round(h*motion['scale']))
                    image=surface.resize((sw,sh),Image.Resampling.BILINEAR)
                    if motion['rotation']: image=image.rotate(-motion['rotation'],resample=Image.Resampling.BILINEAR,expand=True); sw,sh=image.size
                    opacity=max(0,min(1,motion['opacity']*envelope(c,self.position-c['start'])))
                    transition=c.get('transition',{}); td=max(.001,float(transition.get('duration',0)))
                    if transition:
                        progress=max(0,min(1,(self.position-c['start'])/td)); kind=transition.get('type','Dissolvenza al nero')
                        if kind in ('Dissolvenza al nero','Wipe','Sfocatura','Zoom'):opacity*=progress
                        if kind=='Sfocatura':
                            from PIL import ImageFilter
                            image=image.filter(ImageFilter.BoxBlur(max(1,round(10*min(w/w0,h/h0)))))
                        if kind.startswith('Scorrimento'):
                            delta=(1-progress)*w if 'sinistra' in kind else -(1-progress)*w if 'destra' in kind else 0
                            dy=(1-progress)*h if 'su' in kind else -(1-progress)*h if 'giù' in kind else 0
                            motion['x']+=delta/w; motion['y']+=dy/h
                    if opacity<1: image.putalpha(image.getchannel('A').point(lambda x:int(x*opacity)))
                    canvas.alpha_composite(image,(round((w-sw)/2+motion['x']*w),round((h-sh)/2+motion['y']*h)))
            if warning:
                from PIL import ImageDraw
                ImageDraw.Draw(canvas).text((10,12),'Media unavailable: see the status bar',fill='#ffcb65')
            if not tracks.get('captionsHidden',False):
                from captions import draw
                canvas=draw(canvas,self.project.data.get('captions',[]),self.project.data.get('captionStyle',{}),self.position)
            raw=canvas.tobytes('raw','RGBA'); qimage=QImage(raw,w,h,w*4,QImage.Format.Format_RGBA8888).copy(); pixmap=QPixmap.fromImage(qimage)
            box=QSize(max(100,self.viewer.width()-8),max(100,self.viewer.height()-8))
            if w<box.width() and h<box.height():
                # Rendered at the preview quality (360/720/960), shown filling the viewer.
                pixmap=pixmap.scaled(box,Qt.AspectRatioMode.KeepAspectRatio,Qt.TransformationMode.SmoothTransformation)
            self.viewer.setPixmap(pixmap)
            self.update_clock()
        def zoom(self,factor):
            self.timeline.zoom=max(2,min(500,self.timeline.zoom*factor)); self.timeline.refresh()
            self.zoom_slider.blockSignals(True); self.zoom_slider.setValue(round(self.timeline.zoom)); self.zoom_slider.blockSignals(False)
        def fit(self):
            self.timeline.zoom=max(2,min(500,(self.scroll.width()-70)/max(1,self.project.duration))); self.timeline.refresh()
            self.zoom_slider.blockSignals(True); self.zoom_slider.setValue(round(self.timeline.zoom)); self.zoom_slider.blockSignals(False)
        def keyPressEvent(self,event):
            if isinstance(QApplication.focusWidget(),(QLineEdit,QTextEdit,QAbstractSpinBox)): super().keyPressEvent(event); return
            key=event.key(); shift=bool(event.modifiers()&Qt.KeyboardModifier.ShiftModifier)
            alt=bool(event.modifiers()&Qt.KeyboardModifier.AltModifier)
            if key==Qt.Key.Key_M and shift: self.marker_step(-1 if event.modifiers()&Qt.KeyboardModifier.ControlModifier else 1)
            elif key==Qt.Key.Key_M: self.add_marker()
            elif key==Qt.Key.Key_R and event.modifiers()&Qt.KeyboardModifier.ControlModifier: self.speed_dialog()
            elif key==Qt.Key.Key_F and shift: self.freeze_frame()
            elif key==Qt.Key.Key_A: self.select_right_of_playhead()
            elif key==Qt.Key.Key_Comma: self.nudge_selected(-1)
            elif key==Qt.Key.Key_Period: self.nudge_selected(1)
            elif alt and key in (Qt.Key.Key_Left,Qt.Key.Key_Right): self.nudge_selected(-1 if key==Qt.Key.Key_Left else 1)
            elif key==Qt.Key.Key_E and shift and event.modifiers()&Qt.KeyboardModifier.ControlModifier: self.snapshot_frame()
            elif key==Qt.Key.Key_Space: self.toggle()
            elif key==Qt.Key.Key_K: self.pause()
            elif key==Qt.Key.Key_L: self.shuttle(1)
            elif key==Qt.Key.Key_J: self.shuttle(-1)
            elif key==Qt.Key.Key_Q: self.ripple_trim(True)
            elif key==Qt.Key.Key_W: self.ripple_trim(False)
            elif key==Qt.Key.Key_Home: self.pause(); self.seek(0)
            elif key==Qt.Key.Key_End: self.pause(); self.seek(self.project.duration)
            elif key==Qt.Key.Key_Escape: self.select(None)
            elif key==Qt.Key.Key_Left: self.pause(); self.seek(self.position-(5 if shift else 1)/self.project.settings['fps'])
            elif key==Qt.Key.Key_Right: self.pause(); self.seek(self.position+(5 if shift else 1)/self.project.settings['fps'])
            elif key in [Qt.Key.Key_Delete,Qt.Key.Key_Backspace]:
                if not self.delete_marker():self.delete(shift)
            elif key==Qt.Key.Key_C and not (event.modifiers() & (Qt.KeyboardModifier.ControlModifier|Qt.KeyboardModifier.MetaModifier)): self.choose_tool(True)
            elif key==Qt.Key.Key_V and not (event.modifiers() & (Qt.KeyboardModifier.ControlModifier|Qt.KeyboardModifier.MetaModifier)): self.razor=False; self.choose_tool(False)
            elif key==Qt.Key.Key_S: self.snap_box.setChecked(not self.snap_box.isChecked())
            elif key in [Qt.Key.Key_Plus,Qt.Key.Key_Equal]: self.zoom(1.3)
            elif key==Qt.Key.Key_Minus: self.zoom(1/1.3)
            elif key==Qt.Key.Key_Backslash: self.fit()
            elif key in [Qt.Key.Key_Up,Qt.Key.Key_Down]:
                points=sorted(set([0,self.project.duration]+[v for c in self.project.clips for v in (c['start'],c['start']+c['duration'])]))
                candidates=[t for t in points if t<self.position-.001] if key==Qt.Key.Key_Up else [t for t in points if t>self.position+.001]
                if candidates: self.pause(); self.seek(candidates[-1] if key==Qt.Key.Key_Up else candidates[0])
            else: super().keyPressEvent(event)

        def add_marker(self):
            self.checkpoint(); markers=self.project.data.setdefault('markers',[])
            markers.append(dict(t=round(self.position*self.project.settings['fps'])/self.project.settings['fps'],name='',color='#e4ca4a'))
            self.changed()
        def edit_marker(self,marker):
            from PySide6.QtWidgets import QInputDialog,QColorDialog,QMenu
            from PySide6.QtGui import QCursor
            menu=QMenu(self); rename=menu.addAction('Rinomina'); color=menu.addAction('Colore…'); delete=menu.addAction('Elimina'); chosen=menu.exec(QCursor.pos())
            if chosen is delete:
                self.checkpoint(); self.project.data['markers'].remove(marker); self.changed(); return
            if chosen is rename:
                name,ok=QInputDialog.getText(self,'Marker','Nome',text=marker.get('name',''))
                if ok:self.checkpoint(); marker['name']=name; self.changed()
            if chosen is color:
                value=QColorDialog.getColor(QColor(marker.get('color','#e4ca4a')),self,'Colore marker')
                if value.isValid():self.checkpoint(); marker['color']=value.name(); self.changed()
        def delete_marker(self):
            markers=self.project.data.get('markers',[])
            marker=min(markers,key=lambda m:abs(m.get('t',m.get('time',0))-self.position),default=None)
            if marker and abs(marker.get('t',marker.get('time',0))-self.position)<=1/self.project.settings['fps']:
                self.checkpoint(); markers.remove(marker); self.changed(); return True
            return False
        def marker_step(self,direction):
            markers=sorted(self.project.data.get('markers',[]),key=lambda m:m.get('t',m.get('time',0)))
            if not markers:return
            t=self.position; times=[m.get('t',m.get('time',0)) for m in markers]
            target=next((x for x in (times if direction>0 else reversed(times)) if x>t+.001),None) if direction>0 else next((x for x in reversed(times) if x<t-.001),None)
            if target is not None:self.seek(target)
        def speed_dialog(self):
            from PySide6.QtWidgets import QDialog,QFormLayout,QDoubleSpinBox,QCheckBox,QComboBox,QDialogButtonBox,QLabel
            c=self.selected_clip()
            if not c:return
            dialog=QDialog(self); dialog.setWindowTitle('Velocità / Durata'); form=QFormLayout(dialog)
            speed=QDoubleSpinBox(); speed.setRange(10,1600); speed.setValue(c.get('speed',1)*100); speed.setSuffix(' %'); form.addRow('Velocità',speed)
            duration=QLabel(f'{c["duration"]:.3f} s'); form.addRow('Nuova durata',duration)
            source_length=c['duration']*c.get('speed',1)
            speed.valueChanged.connect(lambda value:duration.setText(f'{source_length/(value/100):.3f} s'))
            keep=QCheckBox('Mantieni intonazione'); keep.setChecked(True); form.addRow(keep)
            ripple=QCheckBox('Sposta le clip successive'); ripple.setChecked(True); form.addRow(ripple)
            preset=QComboBox(); preset.addItems(['Costante','Montagna','Bullet','Ingresso veloce','Uscita veloce']); form.addRow('Curva',preset)
            buttons=QDialogButtonBox(QDialogButtonBox.StandardButton.Ok|QDialogButtonBox.StandardButton.Cancel); form.addRow(buttons); buttons.accepted.connect(dialog.accept); buttons.rejected.connect(dialog.reject)
            if dialog.exec()!=QDialog.DialogCode.Accepted:return
            value=speed.value()/100
            self.checkpoint()
            selected=preset.currentText()
            if selected!='Costante':
                from editing import apply_speed_ramp
                segments=apply_speed_ramp(self.project,c,value,selected,ripple=ripple.isChecked())
                for part in segments:part['pitch']=keep.isChecked()
            else:
                from editing import change_speed
                change_speed(self.project,c,value,ripple=ripple.isChecked()); c['pitch']=keep.isChecked(); c.pop('speedRamp',None)
            self.changed()
        def apply_transition(self):
            from PySide6.QtWidgets import QInputDialog
            c=self.selected_clip()
            if not c or 'title' in c:return
            names=['Dissolvenza al nero','Scorrimento sinistra','Scorrimento destra','Scorrimento su','Scorrimento giù','Zoom','Wipe','Sfocatura']
            name,ok=QInputDialog.getItem(self,'Transizioni','Transizione in entrata',names,0,False)
            if not ok:return
            sec,ok=QInputDialog.getDouble(self,'Transizioni','Durata (secondi)',.5,.05,min(5,c['duration']),2)
            if not ok:return
            self.checkpoint(); c['transition']={'type':name,'duration':sec}; self.changed()
        def set_title_animation(self,which,name):
            c=self.selected_clip()
            if not c or 'title' not in c:return
            self.checkpoint(); c['title'][which]=name; self.changed()
        def edit_title_motion(self):
            from PySide6.QtWidgets import QInputDialog
            c=self.selected_clip()
            if not c or 'title' not in c:return
            names=['Nessuna','Dissolvenza','Scorri su','Pop/Scala','Macchina da scrivere']
            incoming,ok=QInputDialog.getItem(self,'Animazione testo','Entrata',names,names.index(c['title'].get('animationIn','Nessuna')) if c['title'].get('animationIn','Nessuna') in names else 0,False)
            if not ok:return
            outgoing,ok=QInputDialog.getItem(self,'Animazione testo','Uscita',names[:4],0,False)
            if not ok:return
            styles=['Normale','Contorno','Ombra','Sfondo box']; style,ok=QInputDialog.getItem(self,'Stile testo','Preset',styles,0,False)
            if ok:self.checkpoint(); c['title'].update(animationIn=incoming,animationOut=outgoing,stylePreset=style); self.changed()
        def chroma_dialog(self):
            from PySide6.QtWidgets import QColorDialog,QInputDialog
            from PySide6.QtGui import QColor
            c=self.selected_clip()
            if not c:return
            old=c.get('chromaKey',{}); color=QColorDialog.getColor(QColor(old.get('color','#00ff00')),self,'Colore da rimuovere')
            if not color.isValid():return
            tolerance,ok=QInputDialog.getDouble(self,'Chroma key','Tolleranza',float(old.get('tolerance',.12)),.01,.5,2)
            if not ok:return
            softness,ok=QInputDialog.getDouble(self,'Chroma key','Morbidezza',float(old.get('softness',.08)),.001,.5,3)
            if ok:self.checkpoint(); c['chromaKey']={'color':color.name(),'tolerance':tolerance,'softness':softness}; self.changed()
        def toggle_noise_reduction(self):
            c=self.selected_clip()
            if not c:return
            self.checkpoint(); c['noiseReduction']=not c.get('noiseReduction',False); self.changed()
        def detach_audio(self):
            c=self.selected_clip(); m=self.project.item(c) if c else None
            if not c or not m or not m.get('hasAudio'):return
            self.checkpoint(); audio=copy.deepcopy(m); audio.update(id=uid(),name=m['name']+' · audio',hasVideo=False,hasAudio=True,still=False)
            self.project.media.append(audio); clip=copy.deepcopy(c); clip.update(id=uid(),media=audio['id'],track=min(c['track'],len(self.project.data['tracks']['audioMuted'])-1),audioDetached=True); c['audioDisabled']=True
            self.project.clips.append(clip); self.select(clip['id']); self.changed()
        def duck_music(self):
            selected=self.selected_clip(); target_track=selected['track'] if selected else 0
            voice=[c for c in self.project.clips if c['track']!=target_track and self.project.item(c) and self.project.item(c).get('hasAudio') and not c.get('audioDisabled')]
            music=[c for c in self.project.clips if c['track']==target_track and self.project.item(c) and self.project.item(c).get('hasAudio')]
            if not voice or not music:return
            self.checkpoint()
            for c in music:
                peaks=self.visuals.peaks.get(self.project.item(c)['id']); keys=[]
                if peaks is None:continue
                stride=max(20,int(c['duration']*100/800))
                for i in range(0,min(len(peaks),int(c['duration']*100)),stride):
                    local=i/100; t=c['start']+local; active=False
                    for v in voice:
                        if v['start']<=t<v['start']+v['duration']:
                            vp=self.visuals.peaks.get(self.project.item(v)['id']); src=int((v.get('in',0)+(t-v['start'])*v.get('speed',1))*100)
                            if vp is not None and 0<=src<len(vp) and vp[src]>.08:active=True; break
                    keys.append(dict(t=c.get('in',0)+local*c.get('speed',1),volume=c.get('volume',1)*(.28 if active else 1)))
                c.setdefault('effects',{})['keys']=keys
            self.changed()
        def select_right_of_playhead(self):
            ids={c['id'] for c in self.project.clips if c['start']>=self.position-1e-6}
            self.selection=ids; self.selected=next(iter(ids),None); self.selected_caption=None; self.update_inspector(); self.timeline.update()
        def nudge_selected(self,direction):
            clips=self.selected_clips()
            if not clips:return
            amount=direction/self.project.settings['fps']; self.checkpoint()
            for c in clips:c['start']=max(0,c['start']+amount)
            self.changed()
        def close_gaps(self):
            lane=self.selected_clip()['track'] if self.selected_clip() else 0
            self.checkpoint(); cursor=0
            for c in sorted((v for v in self.project.clips if v['track']==lane),key=lambda v:v['start']):
                if c['start']>cursor:c['start']=cursor
                cursor=max(cursor,c['start']+c['duration'])
            self.changed()
        def snapshot_frame(self):
            from PySide6.QtWidgets import QFileDialog
            path,_=QFileDialog.getSaveFileName(self,'Esporta fotogramma','fotogramma.png','PNG (*.png)')
            if not path:return
            if not path.lower().endswith('.png'):path+='.png'
            # Render through the normal export graph, then sample the exact sequence frame.
            from core import Project,export_frame
            project=Project(); project.data=self.snapshot()
            try:
                export_frame(project,self.position,path)
            except Exception as exc:self.error(str(exc))
        def freeze_frame(self):
            c=next((v for v in self.project.clips if v['start']<=self.position<v['start']+v['duration'] and self.project.item(v) and self.project.item(v).get('hasVideo')),None)
            if not c:return
            from core import tool,CREATE_FLAGS,probe,uid
            import hashlib
            from storage import fingerprint
            m=self.project.item(c); source_t=c.get('in',0)+(self.position-c['start'])*c.get('speed',1)
            cache=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows'/'freeze'; cache.mkdir(parents=True,exist_ok=True)
            png=cache/(hashlib.sha1(f'{fingerprint(m["path"])}:{source_t:.5f}'.encode()).hexdigest()+'.png')
            if not png.exists():
                result=__import__('subprocess').run([tool('ffmpeg'),'-v','error','-y','-ss',f'{source_t:.6f}','-i',m['path'],'-frames:v','1',str(png)],capture_output=True,creationflags=CREATE_FLAGS)
                if result.returncode: self.error(result.stderr.decode(errors='replace')[-1200:]); return
            self.checkpoint()
            for crossing in list(self.project.clips):
                if crossing['start']+.001<self.position<crossing['start']+crossing['duration']-.001:self.project.split(crossing['id'],self.position)
            for later in self.project.clips:
                if later['start']>=self.position-.0001:later['start']+=2
            from captions import retime
            for cap in self.project.data.get('captions',[]):
                if cap['start']>=self.position-.0001:retime(cap,cap['start']+2,cap['end']+2)
                elif cap['end']>self.position:retime(cap,cap['start'],cap['end']+2)
            still=probe(png); still.update(id=uid(),path=str(png),duration=2,still=True,hasAudio=False); self.project.media.append(still)
            self.project.add_clip(still['id'],c['track'],self.position); frozen=self.project.clips[-1]; frozen['duration']=2; frozen['freezeFrame']=True; frozen['freezeSource']={'media':m['id'],'time':source_t}; self.changed()
        def reverse_clip(self):
            c=self.selected_clip()
            if not c or not self.project.item(c) or not self.project.item(c).get('hasVideo'):return
            from core import tool,CREATE_FLAGS,probe,uid
            import hashlib,subprocess
            from storage import fingerprint
            m=self.project.item(c); span=c['duration']*c.get('speed',1)
            key=hashlib.sha1(f'{fingerprint(m["path"])}:{c.get("in",0):.6f}:{span:.6f}'.encode()).hexdigest()
            cache=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows'/'reverse'; cache.mkdir(parents=True,exist_ok=True)
            target=cache/(key+'.mp4')
            if not target.exists():
                command=[tool('ffmpeg'),'-v','error','-y','-ss',f'{c.get("in",0):.6f}','-t',f'{span:.6f}','-i',m['path'],'-vf','reverse']
                if m.get('hasAudio'):command+=['-af','areverse']
                command+=['-threads','2','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p']
                if m.get('hasAudio'):command+=['-c:a','aac']
                command.append(str(target)); result=subprocess.run(command,capture_output=True,creationflags=CREATE_FLAGS)
                if result.returncode:self.error(result.stderr.decode(errors='replace')[-1500:]);return
            self.checkpoint(); reversed_media=probe(target); reversed_media.update(id=uid(),path=str(target),reversed=True); self.project.media.append(reversed_media)
            c.update(media=reversed_media['id'],**{'in':0},reversed=True,reverseSource={'media':m['id'],'in':c.get('in',0),'duration':span}); self.changed()
        def resizeEvent(self,event):
            super().resizeEvent(event)
            if hasattr(self,'timeline'): QTimer.singleShot(0,self.render_preview)
        def dragEnterEvent(self,event):
            if event.mimeData().hasUrls(): event.acceptProposedAction()
        def dropEvent(self,event):
            paths=[u.toLocalFile() for u in event.mimeData().urls()]
            if len(paths)==1 and Path(paths[0]).suffix.lower() in ['.elitestudio','.json']: self.open_path(paths[0])
            else: self.import_paths(paths)
        def closeEvent(self,event):
            if self.exporting or self.pending: self.error('Wait for the current operation to finish.'); event.ignore(); return
            if not self.confirm_leave(): event.ignore(); return
            from storage import discard_recovery
            discard_recovery()
            if hasattr(self,'proxy_cancel'): self.proxy_cancel.set()
            self.pause()
            for state in self.audio: state[0].stop(); state[0].setSource(QUrl()); state[2]=None
            for cap in self.captures.values(): cap.release()
            for renderer in self.pano_renderers.values(): renderer.close()
            self.visuals.close()
            self.sequence_preview.close()
            event.accept()

    app=QApplication(sys.argv); app.setApplicationName('Elite Studio Windows'); app.setOrganizationName('Coppa Elite'); app.setStyle('Fusion')
    from interface import STYLE
    app.setStyleSheet(STYLE)
    editor=Editor(); editor.show()
    return app.exec()

if __name__=='__main__':
    try:
        sys.exit(cli())
    except Exception:
        import traceback
        log=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows'/'error.log'
        log.parent.mkdir(parents=True,exist_ok=True)
        log.write_text(traceback.format_exc(),encoding='utf-8')
        if sys.stderr is not None: traceback.print_exc()
        if os.name=='nt':
            import ctypes
            ctypes.windll.user32.MessageBoxW(None,f'Elite Studio could not start. Details: {log}', 'Elite Studio',16)
        sys.exit(1)
