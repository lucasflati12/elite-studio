"""Small, opt-in effects. Neutral clips take the original fast path."""
from __future__ import annotations
import copy
import math
from functools import lru_cache

DEFAULTS=dict(exposure=0.,contrast=1.,saturation=1.,temperature=0.,fadeIn=0.,fadeOut=0.,audioFadeIn=0.,audioFadeOut=0.,rotation=0.,ease='smooth',keys=[])
MOTION=dict(scale=1.,x=0.,y=0.,opacity=1.,rotation=0.,volume=1.)
RANGES=dict(exposure=(-3,3),contrast=(.2,2),saturation=(0,2),temperature=(-1,1),fadeIn=(0,30),fadeOut=(0,30),audioFadeIn=(0,30),audioFadeOut=(0,30),rotation=(-360,360),scale=(.05,8),x=(-2,2),y=(-2,2),opacity=(0,1),volume=(0,4))


def validate(e):
    if not isinstance(e,dict): raise ValueError('Effetti clip non validi')
    if 'grade' in e and not isinstance(e['grade'],dict): raise ValueError('Color grading non valido')
    for key,(lo,hi) in RANGES.items():
        if key in e and (not math.isfinite(float(e[key])) or not lo<=float(e[key])<=hi): raise ValueError(f'Effetto {key} fuori intervallo')
    keys=e.get('keys',[])
    if not isinstance(keys,list) or len(keys)>1000: raise ValueError('Troppi keyframe o keyframe non validi')
    for frame in keys:
        if not math.isfinite(float(frame.get('t',-1))) or float(frame.get('t',-1))<0: raise ValueError('Tempo keyframe non valido')
        for key,value in frame.items():
            if key in MOTION:
                lo,hi=RANGES[key]
                if not math.isfinite(float(value)) or not lo<=float(value)<=hi: raise ValueError(f'Keyframe {key} non valido')


def at(c,local):
    """Keys use media time, preserving animation across trimming, splits and speed changes."""
    e=c.get('effects',{}); result={k:float(e.get(k,v) if k=='rotation' else c.get(k,v)) for k,v in MOTION.items()}
    keys=sorted(e.get('keys',[]),key=lambda k:k['t'])
    if not keys: return result
    t=c.get('in',0)+local*c.get('speed',1)
    left=keys[0]; right=keys[-1]
    for key in keys:
        if key['t']<=t: left=key
        if key['t']>=t: right=key; break
    f=max(0,min(1,(t-left['t'])/max(.000001,right['t']-left['t'])))
    if e.get('ease','smooth')=='smooth': f=f*f*(3-2*f)
    for k in result: result[k]=left.get(k,result[k])+(right.get(k,result[k])-left.get(k,result[k]))*f
    return result


def envelope(c,local,audio=False):
    e=c.get('effects',{}); prefix='audioF' if audio else 'f'; a=min(c['duration'],float(e.get(prefix+'adeIn',0))); b=min(c['duration'],float(e.get(prefix+'adeOut',0)))
    return (max(0,min(1,local/a)) if a else 1)*(max(0,min(1,(c['duration']-local)/b)) if b else 1)


@lru_cache(maxsize=128)
def _lut(exposure,contrast,temperature):
    gain=2**exposure
    return [round(max(0,min(255,(v*gain*factor-127.5)*contrast+127.5))) for factor in (1+.15*temperature,1,1-.15*temperature) for v in range(256)]


def color(image,e):
    from PIL import Image,ImageEnhance
    exposure=float(e.get('exposure',0)); contrast=float(e.get('contrast',1)); saturation=float(e.get('saturation',1)); temp=float(e.get('temperature',0))
    import grading
    if grading.active(e): image=grading.pil(image,e['grade'])
    if (exposure,contrast,saturation,temp)==(0.,1.,1.,0.): return image
    alpha=image.getchannel('A'); rgb=image.convert('RGB')
    if exposure or contrast!=1 or temp: rgb=rgb.point(_lut(exposure,contrast,temp))
    if saturation!=1: rgb=ImageEnhance.Color(rgb).enhance(saturation)
    result=rgb.convert('RGBA'); result.putalpha(alpha); return result


def expression(c,key,time='t'):
    """FFmpeg expression matching at(); time is local clip time before PTS shift."""
    base=at({**c,'effects':{k:v for k,v in c.get('effects',{}).items() if k!='keys'}},0)[key]
    keys=sorted(c.get('effects',{}).get('keys',[]),key=lambda k:k['t'])
    if not keys: return f'{base:.8f}'
    if all(abs(k.get(key,base)-keys[0].get(key,base))<1e-7 for k in keys): return f'{keys[0].get(key,base):.8f}'
    result=f'{keys[-1].get(key,base):.8f}'
    mt=f'({c.get("in",0):.8f}+({time})*{c.get("speed",1):.8f})'
    for a,b in reversed(list(zip(keys,keys[1:]))):
        av,bv=a.get(key,base),b.get(key,base); f=f'clip(({mt}-{a["t"]:.8f})/{max(.000001,b["t"]-a["t"]):.8f},0,1)'
        if c.get('effects',{}).get('ease','smooth')=='smooth': f=f'(({f})*({f})*(3-2*({f})))'
        value=f'({av:.8f}+({bv-av:.8f})*({f}))'
        result=f'if(lt({mt},{b["t"]:.8f}),{value},{result})'
    return result


def color_filters(e):
    import grading
    out=[grading.ffmpeg_filter(e['grade'])] if grading.active(e) else []; exp=float(e.get('exposure',0)); con=float(e.get('contrast',1)); temp=float(e.get('temperature',0)); sat=float(e.get('saturation',1))
    if exp or con!=1 or temp:
        expressions=[f"{ch}='clip((val*{2**exp*gain:.8f}-127.5)*{con:.8f}+127.5,0,255)'" for ch,gain in zip('rgb',(1+.15*temp,1,1-.15*temp))]
        out.append('lutrgb='+':'.join(expressions))
    if sat!=1:
        weights=(.299,.587,.114); channels='rgb'; matrix=[]
        for i,a in enumerate(channels):
            for j,b in enumerate(channels): matrix.append(f'{a}{b}={((1-sat)*weights[j]+(sat if i==j else 0)):.8f}')
        out.append('colorchannelmixer='+':'.join(matrix))
    return out


def video_filters(c,w,h):
    e=c.get('effects',{}); out=color_filters(e); motion=at(c,0)
    animated=lambda key:any(abs(k.get(key,motion[key])-motion[key])>1e-7 for k in e.get('keys',[]))
    if warp_motion(c):
        time=f'on/{float(c.get("_renderFPS",30)):.8f}'; scale=expression(c,'scale',time); rotation=expression(c,'rotation',time)
        x=expression(c,'x',time); y=expression(c,'y',time); angle=f'({rotation})*PI/180'; coords=[]
        pw,ph=w+4,h+4
        for i,(px,py) in enumerate(((-pw/2,-ph/2),(pw/2,-ph/2),(-pw/2,ph/2),(pw/2,ph/2))):
            coords += [f"x{i}='{pw/2}+({scale})*({px}*cos({angle})-{py}*sin({angle}))+({x})*{w}'",
                       f"y{i}='{ph/2}+({scale})*({px}*sin({angle})+{py}*cos({angle}))+({y})*{h}'"]
        # A transparent border prevents perspective's edge extension from painting outside the clip.
        out.append(f'pad={pw}:{ph}:2:2:color=black@0,perspective='+':'.join(coords)+f':sense=destination:eval=frame,crop={w}:{h}:2:2')
    else:
        scale=expression(c,'scale'); out.append(f"scale=w='max(2,trunc({w}*({scale})/2)*2)':h='max(2,trunc({h}*({scale})/2)*2)',setsar=1")
    if not warp_motion(c) and (motion['rotation'] or animated('rotation')):
        out.append(f"rotate=angle='({expression(c,'rotation')})*PI/180':ow='hypot(iw,ih)':oh='hypot(iw,ih)':c=black@0")
    if animated('opacity'):
        out.append(f"geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*({expression(c,'opacity','T')})'")
    elif motion['opacity']!=1: out.append(f'colorchannelmixer=aa={motion["opacity"]:.8f}')
    for key,kind in [('fadeIn','in'),('fadeOut','out')]:
        duration=min(float(e.get(key,0)),c['duration'])
        if duration: out.append(f'fade=t={kind}:st={0 if kind=="in" else c["duration"]-duration}:d={duration}:alpha=1')
    return ','.join(out)


def warp_motion(c):
    keys=c.get('effects',{}).get('keys',[])
    return any(len({round(k.get(field,c.get(field,0 if field=='rotation' else 1)),7) for k in keys})>1 for field in ('scale','rotation'))


def audio_filters(c):
    e=c.get('effects',{}); out=[f"volume='{expression(c,'volume')}':eval=frame"]
    if c.get('noiseReduction'): out.append('afftdn=nf=-25')
    for key,kind in [('audioFadeIn','in'),('audioFadeOut','out')]:
        duration=min(float(e.get(key,0)),c['duration'])
        if duration: out.append(f'afade=t={kind}:st={0 if kind=="in" else c["duration"]-duration}:d={duration}')
    return ','.join(out)


def chroma(image, settings):
    """Lightweight RGB key matching FFmpeg chromakey's spill-free alpha mask."""
    if not settings: return image
    import numpy as np
    from PIL import Image
    rgb=np.asarray(image.convert('RGB'),dtype=np.float32); key=np.array([int(settings.get('color','#00ff00')[i:i+2],16) for i in (1,3,5)],dtype=np.float32)
    distance=np.sqrt(((rgb-key)**2).sum(axis=2))/441.673
    tolerance=max(0,min(.5,float(settings.get('tolerance',.12)))); softness=max(.001,min(.5,float(settings.get('softness',.08))))
    alpha=np.clip((distance-tolerance)/softness,0,1)*255
    rgba=np.asarray(image.convert('RGBA')).copy(); rgba[:,:,3]=np.minimum(rgba[:,:,3],alpha.astype('uint8'))
    return Image.fromarray(rgba,'RGBA')


def crossfade(project,cid,duration=.35):
    """Overlap adjacent clips on two lanes without overwriting existing media."""
    from captions import retime
    b=next(c for c in project.clips if c['id']==cid)
    a=next((c for c in project.clips if c['id']!=cid and c['track']==b['track'] and abs(c['start']+c['duration']-b['start'])<.01 and 'title' not in c),None)
    if 'title' in b or a is None: raise ValueError('Seleziona la seconda di due clip video consecutive sulla stessa traccia.')
    if not all(project.item(c) and project.item(c).get('hasVideo') for c in (a,b)): raise ValueError('La transizione richiede due clip video.')
    d=min(duration,a['duration']/2,b['duration']/2); old=b['start']
    if d<1/project.settings['fps']: raise ValueError('Clip troppo brevi per questa transizione.')
    changes={c['id']:c['start']-d if c['start']>=old-.000001 else c['start'] for c in project.clips}
    def available(lane):
        return not any(c['id'] not in (a['id'],b['id']) and c['track']==lane and changes[c['id']]<old-d+b['duration']-1e-6
                       and changes[c['id']]+c['duration']>old-d+1e-6 for c in project.clips)
    destination=next((lane for lane in project.lanes if lane>b['track'] and available(lane)),None)
    if destination is None:
        if len(project.lanes)>=8: raise ValueError('Non ci sono tracce superiori libere per la transizione.')
        destination=max(project.lanes)+1
        if destination==2: destination=3
        for field in ('videoHidden','audioMuted'):
            project.data['tracks'][field]+=[False]*(destination+1-len(project.data['tracks'][field]))
    b['track']=destination
    for c in project.clips: c['start']=changes[c['id']]
    b.setdefault('effects',{}).update(fadeIn=d,audioFadeIn=d)
    a.setdefault('effects',{}).update(fadeOut=0,audioFadeOut=d)
    for c in project.data.get('captions',[]):
        if c['start']>=old: retime(c,max(0,c['start']-d),c['end']-d)
    return d
