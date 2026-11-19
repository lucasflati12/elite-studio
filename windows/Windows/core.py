"""Portable Elite Studio project model and FFmpeg renderer."""
from __future__ import annotations
import copy
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
CREATE_FLAGS = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
VIDEO = {'.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm', '.3gp', '.insv'}
AUDIO = {'.wav', '.mp3', '.m4a', '.aac', '.flac', '.ogg', '.aiff', '.aif', '.caf'}
IMAGES = {'.png', '.jpg', '.jpeg', '.webp', '.heic', '.heif', '.bmp', '.tif', '.tiff'}


def uid():
    return uuid.uuid4().hex[:8]


def tool(name):
    path = shutil.which(name)
    if not path:
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'ffmpeg/bin' / (name + '.exe')
        if candidate.exists():
            path = str(candidate)
    if not path:
        raise RuntimeError(f'{name} is missing. Install FFmpeg and add its bin folder to PATH.')
    return path


def probe(path):
    from pano import primary
    path = primary(path)
    if not path.is_file():
        raise FileNotFoundError(f'Media file missing: {path}')
    result = subprocess.run([tool('ffprobe'), '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(path)], capture_output=True, text=True, creationflags=CREATE_FLAGS)
    if result.returncode:
        raise ValueError(f'{path.name}: {result.stderr.strip()}')
    data = json.loads(result.stdout)
    videos = [s for s in data['streams'] if s['codec_type'] == 'video' and not s.get('disposition', {}).get('attached_pic')]
    audios = [s for s in data['streams'] if s['codec_type'] == 'audio']
    still = path.suffix.lower() in IMAGES
    if not videos and not audios:
        raise ValueError(f'{path.name}: no supported audio or video stream')
    duration = 5 if still else float(data.get('format', {}).get('duration', 0))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError(f'{path.name}: cannot determine duration')
    v = videos[0] if videos else {}
    w, h = int(v.get('width', 0)), int(v.get('height', 0))
    rotation = float(v.get('tags', {}).get('rotate', 0))
    for side in v.get('side_data_list', []):
        rotation = float(side.get('rotation', rotation))
    if int(abs(rotation)) % 180 == 90:
        w, h = h, w
    return dict(id=uid(), path=str(path.resolve()), name=path.name, duration=duration,
                hasVideo=bool(videos), hasAudio=bool(audios), width=w, height=h, still=still, pano=path.suffix.lower() == '.insv')


class Project:
    def __init__(self):
        self.data = {'format': 'elitestudio/1', 'settings': {'width': 1080, 'height': 1920, 'fps': 30, 'showLogo': False},
                     'tracks': {'videoHidden': [False, False], 'audioMuted': [False, False], 'titlesHidden': False}, 'media': [], 'clips': []}
        self.path = None
        self.missing = []
        from captions import DEFAULT_STYLE
        self.data.update(captions=[],captionStyle=copy.deepcopy(DEFAULT_STYLE))
        self.data['tracks']['captionsHidden']=False

    @property
    def clips(self):
        return self.data['clips']

    @property
    def media(self):
        return self.data['media']

    @property
    def settings(self):
        return self.data['settings']

    @property
    def duration(self):
        return max((c['start'] + c['duration'] for c in self.clips), default=0)

    def item(self, clip):
        return next((m for m in self.media if m['id'] == clip.get('media')), None)

    @property
    def lanes(self):
        return [i for i in range(len(self.data['tracks']['videoHidden'])) if i!=2]

    @staticmethod
    def track_label(lane): return 'Titoli' if lane==2 else f'V{lane+1 if lane<2 else lane} / A{lane+1 if lane<2 else lane}'

    def ensure_tracks(self):
        tracks=self.data['tracks']; count=min(9,max(2,len(tracks.get('videoHidden',[])),len(tracks.get('audioMuted',[])),max((c['track']+1 for c in self.clips if c['track']!=2),default=2)))
        for key in ('videoHidden','audioMuted'): tracks[key]=(list(tracks.get(key,[]))+[False]*count)[:count]

    @classmethod
    def load(cls, path):
        p = cls()
        p.path = Path(path).resolve()
        raw = json.loads(p.path.read_text(encoding='utf-8-sig'))
        if not isinstance(raw, dict) or not isinstance(raw.get('clips', []), list):
            raise ValueError('Invalid Elite Studio project: expected an object with a clips array')
        p.data.update(raw)
        settings = cls().settings
        settings.update(raw.get('settings', {}))
        p.data['settings'] = settings
        tracks = cls().data['tracks']
        tracks.update(raw.get('tracks', {}))
        for key in ('videoHidden','audioMuted'):
            values=tracks.get(key,[])
            tracks[key]=(list(values)+[False,False])[:max(2,min(9,len(values)))] if isinstance(values,list) else [False,False]
        p.data['tracks'] = tracks
        media = copy.deepcopy(raw.get('media', []))
        by_id, by_path = {}, {}
        def resolve(value):
            candidate = Path(os.path.expanduser(value))
            return str((candidate if candidate.is_absolute() else p.path.parent / candidate).resolve())
        for m in media:
            m.setdefault('id', uid())
            m['path'] = resolve(m['path'])
            m.setdefault('name', Path(m['path']).name)
            by_id[m['id']] = m
            by_path[m['path']] = m
        clips, ends = [], {}
        for original in raw.get('clips', []):
            c = copy.deepcopy(original)
            c.setdefault('id', uid())
            is_title = c.get('title') is not None
            if is_title:
                c['track'] = 2
                if isinstance(c['title'].get('names'), list):
                    c['title']['names'] = '\n'.join(c['title']['names'])
            elif c.get('media'):
                ref = c['media']
                m = by_id.get(ref)
                if m is None:
                    full = resolve(ref)
                    m = by_path.get(full)
                    if m is None:
                        m = dict(id=uid(), path=full, name=Path(full).name)
                        media.append(m)
                        by_id[m['id']] = m
                        by_path[full] = m
                c['media'] = m['id']
                c['track'] = min(8, max(0, int(c.get('track', 0))))
                if c['track']==2: c['track']=0
            else:
                continue
            c['in'] = max(0, float(c.get('in', 0)))
            c['speed'] = min(16, max(.1, float(c.get('speed', 1))))
            c['start'] = max(0, float(c.get('start', ends.get(c['track'], 0))))
            if not is_title:
                m = by_id[c['media']]
                if not m.get('_probed') and Path(m['path']).is_file():
                    info = probe(m['path'])
                    m.update({k: v for k, v in info.items() if k not in {'id', 'name'}})
                    m['_probed'] = True
                elif not Path(m['path']).is_file() and m['path'] not in p.missing:
                    p.missing.append(m['path'])
            if 'duration' not in c:
                if 'out' in c:
                    c['duration'] = (float(c['out']) - c['in']) / c['speed']
                elif is_title:
                    c['duration'] = 3
                else:
                    c['duration'] = max(0, (by_id[c['media']].get('duration', 0) - c['in']) / c['speed'])
            c['duration'] = max(0, float(c['duration']))
            from effects import validate
            validate(c.get('effects',{}))
            for key in ['in', 'speed', 'start', 'duration', 'volume', 'opacity', 'scale', 'x', 'y']:
                if key in c and not math.isfinite(float(c[key])):
                    raise ValueError(f'Invalid {key} in clip {c["id"]}')
            clips.append(c)
            ends[c['track']] = c['start'] + c['duration']
        for m in media:
            m.pop('_probed', None)
            if m.get('proxyPath'):
                from storage import fingerprint
                source=Path(m['path'])
                if not Path(m['proxyPath']).is_file() or (source.is_file() and m.get('proxyFingerprint') and fingerprint(source)!=m['proxyFingerprint']):
                    m.pop('proxyPath',None); m.pop('proxyFingerprint',None)
        p.data['media'], p.data['clips'] = media, clips
        p.ensure_tracks()
        from captions import normalize,DEFAULT_STYLE
        p.data['captions']=normalize(p.data.get('captions',[]))
        p.data['captionStyle']={**DEFAULT_STYLE,**p.data.get('captionStyle',{})}
        for key in ('width', 'height', 'fps'):
            if not 1 <= float(p.settings[key]) <= (120 if key == 'fps' else 8192):
                raise ValueError(f'Invalid sequence {key}')
        return p

    def save(self, path=None):
        target = Path(path or self.path).resolve()
        raw = copy.deepcopy(self.data)
        for m in raw['media']:
            try:
                m['path'] = Path(m['path']).resolve().relative_to(target.parent).as_posix()
            except ValueError:
                pass
        target.parent.mkdir(parents=True, exist_ok=True)
        fd,temporary=tempfile.mkstemp(prefix='.elite-save-',suffix='.tmp',dir=target.parent)
        try:
            with os.fdopen(fd,'w',encoding='utf-8') as stream:
                json.dump(raw,stream,indent=2,ensure_ascii=False,allow_nan=False)
                stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        self.path = target

    def add_media(self, path):
        full = str(Path(path).resolve())
        old = next((m for m in self.media if m['path'] == full), None)
        if old:
            return old
        item = probe(full)
        self.media.append(item)
        if len(self.media) == 1 and not self.clips and item['hasVideo'] and not self.settings.get('customized',False):
            w, h = item['width'], item['height']
            self.settings.update(width=1080 if h > w else 1920, height=1920 if h > w else 1080)
        return item

    def add_clip(self, media_id, track=0, start=None):
        m = next(m for m in self.media if m['id'] == media_id)
        if start is None:
            start = max((c['start'] + c['duration'] for c in self.clips if c['track'] == track), default=0)
        c = dict(id=uid(), media=media_id, track=track, start=max(0, start), duration=m.get('duration', 5), **{'in': 0, 'speed': 1})
        self.clips.append(c)
        return c

    def split(self, clip_id, t):
        c = next((c for c in self.clips if c['id'] == clip_id), None)
        if c is None or not c['start'] + .001 < t < c['start'] + c['duration'] - .001:
            return False
        right = copy.deepcopy(c)
        right.update(id=uid(), start=t, duration=c['start'] + c['duration'] - t)
        right['in'] = c.get('in', 0) + (t - c['start']) * c.get('speed', 1)
        c['duration'] = t - c['start']
        self.clips.append(right)
        return True


def title_image(title, size):
    from PIL import Image, ImageDraw, ImageFont
    w, h = size
    image = Image.new('RGBA', size)
    draw = ImageDraw.Draw(image)
    factor = w / 1080 * float(title.get('size', 1))
    def font(px, bold=False):
        from captions import font_path
        try:
            return ImageFont.truetype(font_path('ArchivoBlack' if bold else 'Archivo700'), max(1, int(px*factor)))
        except OSError:
            return ImageFont.load_default()
    if title.get('style')=='cinematic':
        text=str(title.get('names','REVERIE')).upper()
        font_path=Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts'/'segoeuil.ttf'
        f=ImageFont.truetype(str(font_path),max(12,round(float(title.get('fontSize',64))*w/1920)))
        spacing=float(title.get('tracking',14))*w/1920
        widths=[draw.textlength(letter,font=f) for letter in text]
        total=sum(widths)+spacing*max(0,len(text)-1)
        x=(w-total)/2; y=float(title.get('y',.43))*h
        for letter,width in zip(text,widths):
            draw.text((x,y),letter,font=f,fill=title.get('color','white'),stroke_width=0)
            x+=width+spacing
        subtitle=title.get('subtitle','')
        if subtitle:
            sf=ImageFont.truetype(str(font_path),max(9,round(20*w/1920)))
            sw=draw.textlength(subtitle,font=sf); draw.text(((w-sw)/2,y+round(90*w/1920)),subtitle,font=sf,fill=(230,234,239,230))
        return image
    from branding import card
    return card(title,size)


def atempo(speed):
    result=[]
    while speed > 2.0:
        result.append('atempo=2'); speed/=2
    while speed < .5:
        result.append('atempo=0.5'); speed*=2
    result.append(f'atempo={speed:.8f}')
    return ','.join(result)


def export(project, output, progress=lambda value: None, cancel=None, hevc=False, hardware=False, quality='balanced',bitrate=0):
    try:
        return _export(project,output,progress,cancel,hevc,hardware,quality,bitrate)
    except RuntimeError:
        if not hardware or (cancel is not None and cancel.is_set()): raise
        # Some drivers initialize successfully but reject the actual sequence format.
        return _export(project,output,progress,cancel,hevc,False,quality,bitrate)


def _export(project, output, progress=lambda value: None, cancel=None, hevc=False, hardware=False, quality='balanced',bitrate=0):
    """Render tracks with original positions, gaps, titles, speeds and mixed audio."""
    if cancel is not None and cancel.is_set():
        raise RuntimeError('Export cancelled')
    if project.duration <= 0:
        raise ValueError('The timeline is empty')
    output=Path(output).resolve()
    if output.suffix.lower() != '.mp4':
        raise ValueError('Choose an .mp4 output file')
    for m in project.media:
        if Path(m['path']).resolve() == output:
            raise ValueError('Export cannot overwrite source media')
    used=[c for c in project.clips if project.item(c)]
    for c in used:
        m=project.item(c)
        if not Path(m['path']).is_file():
            raise FileNotFoundError(f'Media file missing: {m["path"]}. Use Relink media first.')
    w,h=int(project.settings['width']),int(project.settings['height'])
    w+=w%2; h+=h%2
    fps=float(project.settings.get('fps',30))
    duration=project.duration
    tracks=project.data['tracks']
    from export_options import encoder,codec_args
    encode_args=codec_args(encoder(hevc,hardware),quality,bitrate)
    burn_captions=bool(project.data.get('captions')) and not tracks.get('captionsHidden',False)
    final_progress=progress
    if burn_captions: progress=lambda value:final_progress(value*.75)
    with tempfile.TemporaryDirectory(prefix='elite-render-') as tmp:
        pano_clips=[c for c in used if project.item(c).get('pano') or 'pano' in c]
        if pano_clips:
            from pano import render_clip
            project=copy.deepcopy(project)
            emit=progress
            for n,original in enumerate(pano_clips):
                c=next(c for c in project.clips if c['id']==original['id'])
                m=project.item(c)
                rendered=Path(tmp)/f'pano-{n}.mp4'
                render_clip(m,c,rendered,(w,h),fps,tool,CREATE_FLAGS,
                            lambda f,n=n:emit(.65*(n+f)/len(pano_clips)),cancel)
                generated=copy.deepcopy(m)
                generated.update(id=uid(),path=str(rendered),pano=False,still=False,width=w,height=h,duration=c['duration'])
                project.media.append(generated)
                for key in c.get('effects',{}).get('keys',[]): key['t']=(key['t']-c.get('in',0))/c.get('speed',1)
                c.update(media=generated['id'],speed=1,**{'in':0})
                c.pop('pano',None)
            progress=lambda value:emit(.65+.35*value)
        args=[tool('ffmpeg'),'-hide_banner','-loglevel','error','-y','-filter_complex_threads','1',
              '-f','lavfi','-i',f'color=c=black:s={w}x{h}:r={fps}:d={duration}',
              '-t',str(duration),'-f','lavfi','-i','anullsrc=r=48000:cl=stereo']
        graph=['[0:v]format=rgba[base]']
        audio=['[1:a]']
        previous='base'; index=2
        for c in sorted(project.clips,key=lambda c:(99 if 'title' in c else c['track'],c['start'])):
            if c['duration'] <= 0:
                continue
            m=project.item(c)
            title=c.get('title')
            if title is not None:
                if tracks.get('titlesHidden',False):
                    continue
                path=Path(tmp)/f'title-{index}.png'
                title_image(title,(w,h)).save(path)
                args+=['-loop','1','-framerate',str(fps),'-t',str(c['duration']),'-i',str(path)]
            elif m:
                if m.get('still'):
                    args+=['-loop','1','-framerate',str(fps),'-t',str(c['duration']*c.get('speed',1)),'-i',m['path']]
                else:
                    args+=['-ss',str(c.get('in',0)),'-t',str(c['duration']*c.get('speed',1)),'-i',m['path']]
            else:
                continue
            speed=c.get('speed',1)
            track=c['track']
            video=title is not None or m.get('hasVideo',True)
            hidden=title is None and tracks.get('videoHidden',[False,False])[track]
            if video and not hidden:
                chain=f'[{index}:v]setpts=(PTS-STARTPTS)/{speed},fps={fps},format=rgba'
                if title is None:
                    # Fit/fill to a sequence-sized transparent surface before scale/position.
                    fill=c.get('fill',False)
                    mode='increase' if fill else 'decrease'
                    chain+=f',scale={w}:{h}:force_original_aspect_ratio={mode}'
                    chain+=f',crop={w}:{h}' if fill else f',pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=black@0'
                    from effects import video_filters
                    chain+=','+video_filters({**c,'_renderFPS':fps},w,h)
                else:
                    fade=max(0,min(float(title.get('fade',.4)),c['duration']/2))
                    if fade:
                        chain+=f',fade=t=in:st=0:d={fade}:alpha=1,fade=t=out:st={c["duration"]-fade}:d={fade}:alpha=1'
                chain+=f',setpts=PTS+{c["start"]}/TB[v{index}]'
                graph.append(chain)
                from effects import expression
                local_time=f't-{c["start"]}'
                x='0' if title is not None else f"({expression(c,'x',local_time)})*{w}"
                y='0' if title is not None else f"({expression(c,'y',local_time)})*{h}"
                from effects import warp_motion
                if title is None and warp_motion(c): x=y='0'
                graph.append(f'[{previous}][v{index}]overlay=x=\'(W-w)/2+{x}\':y=\'(H-h)/2+{y}\':eof_action=pass:repeatlast=0:enable=\'between(t,{c["start"]},{c["start"]+c["duration"]})\'[o{index}]')
                previous=f'o{index}'
            if m and m.get('hasAudio') and not tracks.get('audioMuted',[False,False])[track]:
                delay=round(c['start']*1000)
                from effects import audio_filters
                graph.append(f'[{index}:a]asetpts=PTS-STARTPTS,{atempo(speed)},atrim=duration={c["duration"]},{audio_filters(c)},aresample=48000,aformat=channel_layouts=stereo,adelay={delay}|{delay},apad,atrim=duration={duration}[a{index}]')
                audio.append(f'[a{index}]')
            index+=1
        if project.settings.get('showLogo'):
            logo=ROOT/'Resources/coppa-elite-logo.png'
            args+=['-loop','1','-i',str(logo)]
            lw=max(1,round(float(project.settings.get('logoSize',190))*w/1080))
            ly=round(float(project.settings.get('logoY',320))*h/1920)
            lx=f'W-w-{round(40*w/1080)}' if project.settings.get('logoRight',True) else str(round(40*w/1080))
            graph+=[f'[{index}:v]scale={lw}:-1[logo]',f'[{previous}][logo]overlay=x={lx}:y={ly}:shortest=1[branded]']
            previous='branded'
        graph.append(''.join(audio)+f'amix=inputs={len(audio)}:duration=first:dropout_transition=0,volume={len(audio)},alimiter=limit=0.95[audio]')
        partial=Path(tmp)/'render.mp4'
        filter_file=Path(tmp)/'filters.txt'; filter_file.write_text(';'.join(graph),encoding='utf-8')
        args+=['-filter_complex_script',str(filter_file),'-map',f'[{previous}]','-map','[audio]','-t',str(duration),
               *encode_args,
               '-c:a','aac','-b:a','192k','-movflags','+faststart','-progress','pipe:1','-nostats',str(partial)]
        log=Path(tmp)/'ffmpeg.log'
        with log.open('w+',encoding='utf-8') as err:
            bounded=[]
            for argument in args:
                if argument=='-i': bounded+=['-threads','1']
                bounded.append(argument)
            proc=subprocess.Popen(bounded,stdout=subprocess.PIPE,stderr=err,text=True,creationflags=CREATE_FLAGS)
            try:
                for line in proc.stdout:
                    if cancel is not None and cancel.is_set():
                        proc.terminate()
                        raise RuntimeError('Export cancelled')
                    if line.startswith('out_time_us='):
                        try: progress(min(.99,int(line.split('=',1)[1])/1_000_000/duration))
                        except ValueError: pass
                code=proc.wait()
                if code:
                    err.seek(0)
                    raise RuntimeError('FFmpeg export failed:\n'+err.read()[-6000:])
            finally:
                proc.stdout.close()
                if proc.poll() is None:
                    proc.terminate(); proc.wait()
            output.parent.mkdir(parents=True,exist_ok=True)
            if burn_captions:
                from captions import burn
                subtitled=Path(tmp)/'subtitled.mp4'
                burn(partial,subtitled,project,lambda value:final_progress(.75+value*.25),cancel,hevc,encode_args)
                partial=subtitled
            # Copy to the target volume then atomically publish, preserving any previous export on failure.
            fd, staging=tempfile.mkstemp(prefix='.elite-export-',suffix='.mp4',dir=output.parent)
            os.close(fd)
            try:
                shutil.copyfile(partial,staging)
                os.replace(staging,output)
            finally:
                if os.path.exists(staging): os.unlink(staging)
        final_progress(1)
