"""Mac-compatible captions, local speech recognition, and shared preview/export drawing."""
from __future__ import annotations
import copy
import math
import os
from pathlib import Path
import subprocess
import tempfile
from functools import lru_cache

DEFAULT_STYLE = dict(look='negativo', y=.62, size=1., uppercase=True, pop=True, maxWords=3, language='it-IT')


def set_text(c, text):
    tokens = text.split()
    old = c.get('words', [])
    if len(tokens) == len(old):
        for word, token in zip(old, tokens): word['w'] = token
    else:
        d = max(.01, c['end'] - c['start']) / max(1, len(tokens))
        c['words'] = [dict(w=w, s=c['start']+i*d, e=c['start']+(i+1)*d) for i,w in enumerate(tokens)]
    c['text'] = ' '.join(tokens)


def retime(c, start, end):
    old, duration = c['start'], max(.001, c['end']-c['start'])
    for w in c.get('words', []):
        for key in ('s','e'): w[key] = start + (w[key]-old)/duration*(end-start)
    c.update(start=start, end=end)


def normalize(captions):
    from core import uid
    out=[]
    for original in captions:
        c=copy.deepcopy(original); c.setdefault('id',uid()); c['start']=max(0,float(c.get('start',0)))
        c['end']=float(c.get('end',c['start']+c.get('duration',1.5)))
        if not all(math.isfinite(c[k]) for k in ('start','end')): raise ValueError('Tempi dei sottotitoli non validi')
        if c['end']<=c['start']: continue
        c.setdefault('words',[])
        set_text(c,c.get('text',' '.join(w['w'] for w in c['words'])))
        out.append(c)
    return sorted(out,key=lambda c:c['start'])


def chunks(words, max_words=3):
    from core import uid
    out=[]; current=[]
    def flush():
        if current:
            out.append(dict(id=uid(), start=current[0]['s'],end=current[-1]['e'],
                            words=copy.deepcopy(current),text=' '.join(w['w'] for w in current)))
            current.clear()
    for raw in sorted(words,key=lambda w:w['s']):
        text=raw['w'].strip().rstrip(',.;:')
        if not text: continue
        if current and (len(current)>=max_words or sum(len(w['w'])+1 for w in current)+len(text)>20 or raw['s']-current[-1]['e']>.6): flush()
        current.append(dict(w=text,s=raw['s'],e=max(raw['e'],raw['s']+.05)))
        if raw['w'].strip().endswith(('.','?','!')) or (len(current)>=2 and raw['w'].strip().endswith((',',';',':'))): flush()
    flush()
    for i,c in enumerate(out):
        nxt=out[i+1]['start'] if i+1<len(out) else float('inf')
        hold=nxt if nxt-c['end']<.5 else min(c['end']+.3,nxt)
        c['end']=min(max(c['start']+.25,hold),nxt)
    return out


def extract(captions,a,b):
    """Remove timeline interval, keeping word times aligned after ripple edits."""
    out=[]; d=b-a
    for original in captions:
        c=copy.deepcopy(original)
        if c['end']<=a: out.append(c); continue
        if c['start']>=b: retime(c,c['start']-d,c['end']-d); out.append(c); continue
        words=[]
        for w in c.get('words',[]):
            mid=(w['s']+w['e'])/2
            if mid<a: words.append(dict(w=w['w'],s=w['s'],e=min(w['e'],a)))
            elif mid>=b: words.append(dict(w=w['w'],s=max(w['s'],b)-d,e=w['e']-d))
        c.update(start=min(c['start'],a),end=c['end']-d if c['end']>b else a,words=words,text=' '.join(w['w'] for w in words))
        if words and c['end']-c['start']>.05: out.append(c)
    return out


@lru_cache(maxsize=16)
def font_path(name='ArchivoBlack'):
    from core import ROOT
    source=ROOT/'Resources'/f'{name}.woff'
    target=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows'/'fonts'/f'{name}.ttf'
    if source.exists():
        try:
            if not target.exists() or target.stat().st_mtime<source.stat().st_mtime:
                from fontTools.ttLib import TTFont
                target.parent.mkdir(parents=True,exist_ok=True)
                font=TTFont(source); font.flavor=None; font.save(target)
            return str(target)
        except (ImportError,OSError): pass
    return str(Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts/arialbd.ttf')


@lru_cache(maxsize=400)
def _bitmap(text,active,look,size,width,height):
    from PIL import Image,ImageDraw,ImageFont
    tokens=text.split(); fs=88*min(width,height)/1080*size
    if not tokens: return None
    for _ in range(40):
        font=ImageFont.truetype(font_path(),max(1,round(fs))); space=fs*.24
        widths=[font.getlength(w) for w in tokens]
        line_width=lambda line:sum(widths[i] for i in line)+space*max(0,len(line)-1)
        lines=[list(range(len(tokens)))]
        if line_width(lines[0])>width*.86 and len(tokens)>1:
            cut=min(range(1,len(tokens)),key=lambda i:max(line_width(range(i)),line_width(range(i,len(tokens)))))
            lines=[list(range(cut)),list(range(cut,len(tokens)))]
        if max(map(line_width,lines))<=width*.86: break
        fs*=.9
    outline=0 if look=='negativo' else max(1,round(fs*.11)); pad=math.ceil(outline+fs*.3); line_h=fs*1.06
    image=Image.new('RGBA',(max(1,math.ceil(max(map(line_width,lines))+pad*2)),max(1,math.ceil(line_h*len(lines)+pad*2))))
    draw=ImageDraw.Draw(image)
    for row,line in enumerate(lines):
        x=(image.width-line_width(line))/2
        for i in line:
            draw.text((x,pad+row*line_h),tokens[i],font=font,anchor='lt',fill='#ffd23f' if look=='oro' and i==active else 'white',stroke_width=outline,stroke_fill='black')
            x+=widths[i]+space
    return image


def draw(canvas,captions,style,t):
    from PIL import Image,ImageOps,ImageChops
    c=next((c for c in reversed(sorted(captions,key=lambda c:c['start'])) if c['start']<=t<c['end']),None)
    if not c: return canvas
    s={**DEFAULT_STYLE,**style}; text=' '.join(w['w'] for w in c.get('words',[])) or c.get('text','')
    if s['uppercase']: text=text.upper()
    active=max([i for i,w in enumerate(c.get('words',[])) if w['s']<=t+.02] or [0]) if s['look']=='oro' else -1
    bitmap=_bitmap(text,active,s['look'],float(s['size']),canvas.width,canvas.height)
    if bitmap is None: return canvas
    scale=alpha=1.
    if s['pop']:
        x=min(1,max(0,(t-c['start'])/.16)); back=1+2.70158*(x-1)**3+1.70158*(x-1)**2
        scale=.7+.3*back; alpha=min(1,max(0,(t-c['start'])/.05+.2))
    image=bitmap.resize((max(1,round(bitmap.width*scale)),max(1,round(bitmap.height*scale))),Image.Resampling.BILINEAR)
    x=round((canvas.width-image.width)/2); y=round(canvas.height*float(s['y'])-image.height/2)
    if s['look']=='negativo':
        mask=Image.new('L',canvas.size); mask.paste(image.getchannel('A'),(x,y))
        if alpha<1: mask=mask.point(lambda v:round(v*alpha))
        canvas=Image.composite(ImageOps.invert(canvas.convert('RGB')).convert('RGBA'),canvas,mask)
    else:
        if alpha<1: image.putalpha(image.getchannel('A').point(lambda v:round(v*alpha)))
        canvas.alpha_composite(image,(x,y))
    return canvas


def burn(source,target,project,progress,cancel=None,hevc=False,encode_args=None):
    """Use the same drawing routine as the viewer; preserve mixed audio."""
    import cv2
    from PIL import Image
    from core import tool,CREATE_FLAGS
    from export_options import codec_args
    encode_args=encode_args or codec_args('libx265' if hevc else 'libx264')
    cap=cv2.VideoCapture(str(source)); fps=float(project.settings['fps']); w=int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); h=int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    log=Path(target).with_suffix('.log'); proc=None
    try:
        with log.open('w+b') as err:
            proc=subprocess.Popen([tool('ffmpeg'),'-v','error','-y','-f','rawvideo','-pixel_format','rgb24','-video_size',f'{w}x{h}','-framerate',str(fps),'-i','pipe:0','-i',str(source),'-map','0:v','-map','1:a?',
                *encode_args,'-c:a','copy','-movflags','+faststart',str(target)],stdin=subprocess.PIPE,stderr=err,stdout=subprocess.DEVNULL,creationflags=CREATE_FLAGS)
            index=0
            while True:
                if cancel is not None and cancel.is_set(): raise RuntimeError('Export cancelled')
                ok,bgr=cap.read()
                if not ok: break
                im=Image.fromarray(cv2.cvtColor(bgr,cv2.COLOR_BGR2RGBA)); im=draw(im,project.data['captions'],project.data.get('captionStyle',{}),index/fps)
                proc.stdin.write(im.convert('RGB').tobytes()); index+=1
                progress(min(.99,index/fps/project.duration))
            proc.stdin.close()
            if not index: raise RuntimeError('Impossibile leggere il video per i sottotitoli')
            if proc.wait():
                err.seek(0); raise RuntimeError(err.read().decode('utf-8',errors='replace')[-3000:])
    finally:
        cap.release()
        if proc:
            if proc.poll() is None: proc.kill(); proc.wait()
            if proc.stdin and not proc.stdin.closed: proc.stdin.close()


def transcribe(project,status=lambda text:None):
    from core import tool,CREATE_FLAGS,atempo
    try: from faster_whisper import WhisperModel
    except ImportError: raise RuntimeError('Esegui Ripara Elite Studio.bat per installare il riconoscimento vocale.')
    audible=[c for c in project.clips if project.item(c) and project.item(c).get('hasAudio') and not project.data['tracks']['audioMuted'][c['track']] and max([c.get('volume',1)]+[k.get('volume',1) for k in c.get('effects',{}).get('keys',[])])>0]
    if not audible: raise ValueError("Nella timeline non c'è audio da trascrivere")
    with tempfile.TemporaryDirectory(prefix='elite-speech-') as tmp:
        wav=Path(tmp)/'audio.wav'; args=[tool('ffmpeg'),'-v','error','-y','-f','lavfi','-t',str(project.duration),'-i','anullsrc=r=16000:cl=mono']; graph=[]; labels=['[0:a]']
        for i,c in enumerate(audible,1):
            args+=['-ss',str(c.get('in',0)),'-t',str(c['duration']*c.get('speed',1)),'-i',project.item(c)['path']]
            from effects import audio_filters
            # Keep every mix input alive: otherwise amix raises the gain as short
            # clips end, and the fixed compensation clips later speech badly.
            graph.append(f'[{i}:a]asetpts=PTS-STARTPTS,{atempo(c.get("speed",1))},atrim=duration={c["duration"]},{audio_filters(c)},aresample=16000,aformat=channel_layouts=mono,adelay={round(c["start"]*1000)},apad,atrim=duration={project.duration}[a{i}]'); labels.append(f'[a{i}]')
        graph.append(''.join(labels)+f'amix=inputs={len(labels)}:duration=first:dropout_transition=0,volume={len(labels)},highpass=f=100,lowpass=f=6500,alimiter=limit=0.95[mix]')
        args+=['-filter_complex',';'.join(graph),'-map','[mix]','-ac','1','-ar','16000',str(wav)]
        status('Preparo l’audio della timeline…'); result=subprocess.run(args,capture_output=True,creationflags=CREATE_FLAGS)
        if result.returncode: raise RuntimeError(result.stderr.decode(errors='replace')[-3000:])
        status('Carico il riconoscimento vocale (primo utilizzo: download del modello)…')
        # Prefer the more accurate model if it is already installed. New machines
        # retain the small first-run download used by the original installer.
        model=None
        for name in ('medium','base'):
            try:
                model=WhisperModel(name,device='cpu',compute_type='int8',local_files_only=True)
                break
            except (OSError,ValueError,RuntimeError):
                continue
        if model is None:
            model=WhisperModel('base',device='cpu',compute_type='int8')
        language=project.data.get('captionStyle',{}).get('language','it-IT').split('-')[0]
        # Engine noise can make VAD discard entire spoken reactions. Whisper's
        # own no-speech detection still handles silent portions of the timeline.
        segments,_=model.transcribe(str(wav),language=language,word_timestamps=True,vad_filter=False,condition_on_previous_text=False)
        words=[]
        for segment in segments:
            words.extend(dict(w=w.word.strip(),s=w.start,e=w.end) for w in (segment.words or []))
            status(f'Trascrivo l’audio… {min(99,round(segment.end/project.duration*100))}%')
        return chunks(words,project.data.get('captionStyle',{}).get('maxWords',3))
