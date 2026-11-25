"""Automatic colour grading: per-clip analysis + creative looks baked into one 3D LUT.

Shared with mac/Sources/EliteStudio/Grading.swift: same JSON (`effects.grade`), same maths,
so a project graded on one platform looks the same on the other.

    grade = {'look': 'alpine', 'amount': 1.0, 'correct': True,
             'auto': {'black': .06, 'white': .86, 'gamma': .9, 'wb': [1.02, 1, .97], 'flat': True}}

The LUT is a pure function of `grade`: preview (PIL Color3DLUT) and export (FFmpeg lut3d)
use the very same table.
"""
from __future__ import annotations
import hashlib
import json
import math
import os
import re
import warnings
from functools import lru_cache
from pathlib import Path

import numpy as np

SIZE = 33
LUMA = np.array([.2126, .7152, .0722])

# Each look: contrast (S-curve slope at the pivot), pivot, sat, vibrance, warmth (-1..1),
# lift (matte blacks), shadows/highlights tint (RGB offsets, luma-neutral), bands = hue-selective
# tweaks [centre°, width°, hue shift°, sat ×, value ×].
LOOKS = {
    'natural': dict(name='Naturale cinematico', contrast=1.10, pivot=.45, sat=1.0, vibrance=.10, warmth=.03, lift=.008,
                    shadows=[-.008, .002, .010], highlights=[.010, .004, -.008],
                    bands=[[35, 32, 0, 1.04, 1.0], [212, 40, 2, 1.06, .97]]),
    'alpine': dict(name='Alpino cinematico', contrast=1.24, pivot=.43, sat=1.04, vibrance=.18, warmth=.06, lift=.012,
                   shadows=[-.018, .004, .022], highlights=[.020, .008, -.018],
                   bands=[[35, 32, -2, 1.12, 1.02], [95, 45, -12, .90, .96], [212, 40, 4, 1.10, .92]]),
    'golden': dict(name='Golden hour', contrast=1.22, pivot=.45, sat=1.10, vibrance=.25, warmth=.38, lift=.02,
                   shadows=[.010, -.004, -.014], highlights=[.045, .018, -.040],
                   bands=[[35, 35, -2, 1.30, 1.06], [100, 45, -28, .80, .96], [215, 40, 0, .95, .96]]),
    'moody': dict(name='Moody nordico', contrast=1.30, pivot=.45, sat=.72, vibrance=0, warmth=-.22, lift=.045,
                  shadows=[-.022, .004, .028], highlights=[-.006, .004, .010],
                  bands=[[35, 35, 6, .70, .95], [100, 50, 18, .55, .90], [210, 45, 4, 1.10, .82]]),
    'vivid': dict(name='Naturale vivido', contrast=1.18, pivot=.45, sat=1.18, vibrance=.40, warmth=.04, lift=0,
                  shadows=[0, 0, 0], highlights=[0, 0, 0],
                  bands=[[215, 40, 0, 1.15, .94]]),
    'film': dict(name='Pellicola vintage', contrast=1.16, pivot=.45, sat=.86, vibrance=.10, warmth=.18, lift=.07,
                 shadows=[-.010, .022, .012], highlights=[.030, .016, -.026],
                 bands=[[35, 35, 4, 1.10, 1.0], [100, 45, 14, .80, .95], [210, 45, -10, .80, .95]]),
    'bw': dict(name='Bianco e nero drammatico', contrast=1.50, pivot=.42, sat=0, vibrance=0, warmth=0, lift=.01,
               shadows=[0, 0, 0], highlights=[0, 0, 0],
               bands=[[215, 50, 0, 1.0, .60], [35, 40, 0, 1.0, 1.12]]),
}
DEFAULT_LOOK = 'natural'
NEUTRAL_AUTO = dict(black=0., white=1., gamma=1., wb=[1., 1., 1.], flat=False)


def normalized(grade):
    """Validated copy with every field present (missing or broken values fall back to neutral)."""
    if not isinstance(grade, dict): return None
    look = grade.get('look', DEFAULT_LOOK)
    if look not in LOOKS and look != 'none': look = DEFAULT_LOOK
    def num(v, lo, hi, fallback):
        try: v = float(v)
        except (TypeError, ValueError): return fallback
        return min(hi, max(lo, v)) if math.isfinite(v) else fallback
    a = grade.get('auto') if isinstance(grade.get('auto'), dict) else {}
    wb = a.get('wb', [1, 1, 1])
    wb = [num(x, .8, 1.25, 1.) for x in wb] if isinstance(wb, list) and len(wb) == 3 else [1., 1., 1.]
    auto = dict(black=num(a.get('black'), 0, .4, 0.), white=num(a.get('white'), .5, 1.1, 1.), gamma=num(a.get('gamma'), .5, 2, 1.),
                wb=wb, flat=bool(a.get('flat', False)))
    wheels = grade.get('wheels') if isinstance(grade.get('wheels'), dict) else {}
    wheel = lambda k: [num(x, -.25, .25, 0.) for x in wheels.get(k, [0, 0, 0])] if isinstance(wheels.get(k, [0, 0, 0]), list) and len(wheels.get(k, [0, 0, 0])) == 3 else [0., 0., 0.]
    basic = grade.get('basic') if isinstance(grade.get('basic'), dict) else {}
    curves = grade.get('curves') if isinstance(grade.get('curves'), dict) else {}
    hue = grade.get('hue') if isinstance(grade.get('hue'), dict) else {}
    def points(src, periodic=False, shift=False, monotone=False):
        out=[]
        if isinstance(src,list):
            for p in src:
                if isinstance(p,(list,tuple)) and len(p)==2:
                    try:
                        x,y=map(float,p)
                        if math.isfinite(x) and math.isfinite(y): out.append([x%360 if periodic else min(1,max(0,x)), min(180,max(-180,y)) if shift else min(1,max(0,y)) if monotone else min(2,max(0,y))])
                    except (TypeError,ValueError): pass
        out=sorted(out)
        if monotone:
            for i in range(1,len(out)):out[i][1]=max(out[i][1],out[i-1][1])
        return out
    luts={}
    for name in ('inputLut','creativeLut'):
        v=grade.get(name) if isinstance(grade.get(name),dict) else {}
        luts[name]=dict(path=str(v.get('path','')),amount=num(v.get('amount',0),0,1,0))
    return dict(look=look, amount=num(grade.get('amount', 1), 0, 1.5, 1.), correct=bool(grade.get('correct', True)), auto=auto,
                wheels={k: wheel(k) for k in ('lift', 'gamma', 'gain', 'offset')},
                basic={k: num(basic.get(k, d), lo, hi, d) for k, d, lo, hi in (
                    ('temperature', 0., -1., 1.), ('tint', 0., -1., 1.), ('exposure', 0., -5., 5.),
                    ('contrast', 1., 0., 2.), ('pivot', .5, .05, .95), ('highlights', 0., -1., 1.),
                    ('shadows', 0., -1., 1.), ('whites', 0., -1., 1.), ('blacks', 0., -1., 1.),
                    ('saturation', 1., 0., 2.), ('vibrance', 0., -1., 1.))},
                curves={k: points(curves.get(k, []),monotone=True) for k in ('master','r','g','b')},
                hue={k: points(hue.get(k, []), k!='lumsat',k=='hue') for k in ('sat','hue','lum','lumsat')}, **luts)


def _mono_curve(x, pts):
    """Fritsch-Carlson monotone cubic, implicit fixed endpoints."""
    if not pts:return x
    p=sorted([[0.,0.],*pts,[1.,1.]])
    clean=[]
    for a,b in p:
        if clean and a<=clean[-1][0]+1e-8: continue
        clean.append([a,min(1,max(0,b))])
    if len(clean)<2:return x
    xx=np.array([p[0] for p in clean]); yy=np.array([p[1] for p in clean]); d=np.diff(yy)/np.maximum(1e-9,np.diff(xx))
    m=np.zeros_like(yy); m[0]=d[0]; m[-1]=d[-1]
    for i in range(1,len(yy)-1): m[i]=0 if d[i-1]*d[i]<=0 else 2*d[i-1]*d[i]/(d[i-1]+d[i])
    for i,di in enumerate(d):
        if di==0:m[i]=m[i+1]=0
        else:
            a=m[i]/di;b=m[i+1]/di;s=a*a+b*b
            if s>9:t=3/math.sqrt(s);m[i]=t*a*di;m[i+1]=t*b*di
    z=np.clip(x,xx[0],xx[-1]); j=np.clip(np.searchsorted(xx,z,side='right')-1,0,len(xx)-2); h=xx[j+1]-xx[j]; t=(z-xx[j])/h
    return (2*t**3-3*t**2+1)*yy[j]+(t**3-2*t**2+t)*h*m[j]+(-2*t**3+3*t**2)*yy[j+1]+(t**3-t**2)*h*m[j+1]

def _periodic(x, pts, neutral):
    if not pts:return np.full_like(x,neutral,dtype=float)
    pp=sorted(pts); xx=np.array([p[0] for p in pp]); yy=np.array([p[1] for p in pp]); xp=np.concatenate((xx[-1:]-360,xx,xx[:1]+360)); yp=np.concatenate((yy[-1:],yy,yy[:1])); return np.interp(x%360,xp,yp)

@lru_cache(maxsize=64)
def load_cube(path, mtime):
    size1=size3=None; lo=np.zeros(3); hi=np.ones(3); rows=[]
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        line=line.split('#',1)[0].strip()
        if not line or line.startswith('TITLE'):continue
        a=line.split()
        if a[0]=='LUT_1D_SIZE':size1=int(a[1])
        elif a[0]=='LUT_3D_SIZE':size3=int(a[1])
        elif a[0]=='DOMAIN_MIN':lo=np.array(list(map(float,a[1:4])))
        elif a[0]=='DOMAIN_MAX':hi=np.array(list(map(float,a[1:4])))
        elif len(a)>=3:
            try: rows.append(list(map(float,a[:3])))
            except ValueError: pass
    if size3 and len(rows)>=size3**3: return (size3,np.asarray(rows[-size3**3:],dtype=np.float32),lo,hi,3)
    if size1 and len(rows)>=size1: return (size1,np.asarray(rows[-size1:],dtype=np.float32),lo,hi,1)
    raise ValueError(f'LUT .cube non valido: {path}')

def user_lut(rgb, spec):
    path=spec.get('path',''); amount=spec.get('amount',0)
    if not path or amount<=0:return rgb
    try: st=os.stat(path); n,data,lo,hi,dim=load_cube(path,st.st_mtime_ns)
    except OSError as e: warnings.warn(f'LUT mancante: {path} ({e})'); return rgb
    except Exception as e: warnings.warn(f'LUT non valida: {path} ({e})'); return rgb
    q=np.clip((rgb-lo)/np.maximum(1e-9,hi-lo),0,1)
    if dim==1:
        ix=q*(n-1); j=np.minimum(ix.astype(int),n-2); f=ix-j; out=np.stack([np.interp(ix[...,c],np.arange(n),data[:,c]) for c in range(3)],-1)
    else:
        ix=q*(n-1); j=np.minimum(ix.astype(int),n-2); f=ix-j; out=np.zeros_like(rgb)
        for a in (0,1):
          for b in (0,1):
           for c in (0,1):
            w=(f[...,0] if a else 1-f[...,0])*(f[...,1] if b else 1-f[...,1])*(f[...,2] if c else 1-f[...,2]); idx=(j[...,2]+c)*n*n+(j[...,1]+b)*n+j[...,0]+a; out+=data[idx]*w[...,None]
    return np.clip(rgb+(out-rgb)*amount,0,1)


def _rgb_to_hsv(rgb):
    mx = rgb.max(-1); mn = rgb.min(-1); d = mx - mn
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    safe = np.where(d > 1e-9, d, 1)
    h = np.where(mx == r, ((g - b) / safe) % 6, np.where(mx == g, (b - r) / safe + 2, (r - g) / safe + 4)) * 60
    h = np.where(d > 1e-9, h, 0)
    s = np.where(mx > 1e-9, d / np.where(mx > 1e-9, mx, 1), 0)
    return h, s, mx


def _hsv_to_rgb(h, s, v):
    h = (h % 360) / 60; c = v * s; x = c * (1 - np.abs(h % 2 - 1)); m = v - c
    z = np.zeros_like(h); i = np.floor(h).astype(int) % 6
    r = np.choose(i, [c, x, z, z, x, c]); g = np.choose(i, [x, c, c, x, z, z]); b = np.choose(i, [z, z, x, c, c, x])
    return np.stack([r + m, g + m, b + m], -1)


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def _curve(x, a, p):
    """Per-channel S-curve: slope a at pivot p, fixed 0 and 1, monotonic."""
    x = np.clip(x, 0, 1)
    lo = p * np.power(np.clip(x / p, 0, None), a)
    hi = 1 - (1 - p) * np.power(np.clip((1 - x) / (1 - p), 0, None), a)
    return np.where(x < p, lo, hi)


def _saturate(rgb, factor):
    l = (rgb @ LUMA)[..., None]
    return l + (rgb - l) * factor


def correct(rgb, auto):
    """Stage 1: levels, white balance, exposure (gamma) and, for flat profiles (D-Cinelike), a base contrast."""
    rgb = (rgb - auto['black']) / max(.05, auto['white'] - auto['black'])
    rgb = np.clip(rgb * np.array(auto['wb']), 0, 1)
    rgb = np.power(rgb, auto['gamma'])
    if auto['flat']:
        rgb = _saturate(_curve(rgb, 1.18, .45), 1.22)
    return np.clip(rgb, 0, 1)


def look(rgb, L):
    """Stage 2: creative look."""
    w = L['warmth']
    rgb = rgb * np.array([1 + .10 * w, 1 + .01 * w, 1 - .10 * w])
    rgb = _curve(rgb, L['contrast'], L['pivot'])
    h, s, v = _rgb_to_hsv(np.clip(rgb, 0, 1))
    if L['bands']:
        chroma = _smooth(.04, .22, s)
        for centre, width, shift, satx, valx in L['bands']:
            d = np.abs((h - centre + 180) % 360 - 180)
            k = _smooth(0, 1, 1 - d / width) * chroma
            h = h + shift * k; s = s * (1 + (satx - 1) * k); v = v * (1 + (valx - 1) * k)
        rgb = _hsv_to_rgb(h, np.clip(s, 0, 1), np.clip(v, 0, 1))
    l = (rgb @ LUMA)[..., None]
    sh = np.array(L['shadows']); hi = np.array(L['highlights'])
    sh = sh - sh @ LUMA; hi = hi - hi @ LUMA
    rgb = rgb + (1 - l) ** 2 * sh + l ** 2 * hi
    chroma = (rgb.max(-1) - rgb.min(-1))[..., None]
    rgb = _saturate(rgb, L['sat'] * (1 + L['vibrance'] * np.clip(1 - chroma * 2.5, 0, 1)))
    rgb = L['lift'] + (1 - L['lift']) * rgb
    return np.clip(rgb, 0, 1)


def apply(rgb, grade):
    """rgb: float array [..., 3] in 0..1."""
    g = normalized(grade)
    if g is None: return rgb
    base = correct(rgb, g['auto']) if g['correct'] else np.clip(rgb, 0, 1)
    base=user_lut(base,g['inputLut'])
    b = g['basic']
    if b != dict(temperature=0., tint=0., exposure=0., contrast=1., pivot=.5, highlights=0., shadows=0., whites=0., blacks=0., saturation=1., vibrance=0.) or any(any(v) for v in g['wheels'].values()):
        base = base * (2 ** b['exposure'])
        base = (base - b['pivot']) * b['contrast'] + b['pivot']
        lum = base @ LUMA
        base += (b['shadows'] * (1 - np.clip(lum, 0, 1)) ** 2 + b['highlights'] * np.clip(lum, 0, 1) ** 2)[..., None]
        base += (b['blacks'] * (1 - np.clip(lum * 4, 0, 1)) + b['whites'] * np.clip((lum - .75) * 4, 0, 1))[..., None]
        base *= np.array([1 + .12 * b['temperature'], 1 + .08 * b['tint'], 1 - .12 * b['temperature']])
        base = _saturate(base, (b['saturation'] * (1 + b['vibrance'] * np.clip(1 - (base.max(-1)-base.min(-1))*2.5, 0, 1)))[..., None])
        lum = np.clip(base @ LUMA, 0, 1)
        # Wheel offsets: x + lift + gamma*(1-Y) + gain*Y + offset; all vectors are RGB.
        for k, scale in (('lift', np.ones_like(lum)), ('gamma', 1. - lum), ('gain', lum)):
            base += np.asarray(g['wheels'][k]) * scale[..., None]
        base += np.asarray(g['wheels']['offset'])
        base = np.clip(base, 0, 1)
    if any(g['curves'].values()):
        base=_mono_curve(base,g['curves']['master'])
        for c,k in enumerate(('r','g','b')): base[...,c]=_mono_curve(base[...,c],g['curves'][k])
    if any(g['hue'].values()):
        h,s,v=_rgb_to_hsv(np.clip(base,0,1)); chroma=_smooth(.04,.22,s)
        sat=_periodic(h,g['hue']['sat'],1); shift=_periodic(h,g['hue']['hue'],0); lum=_periodic(h,g['hue']['lum'],1)
        ls=_periodic((base@LUMA),g['hue']['lumsat'],1)
        h=h+shift*chroma; s=np.clip(s*(1+(sat-1)*chroma)*(1+(ls-1)*chroma),0,1); v=np.clip(v*(1+(lum-1)*chroma),0,1)
        base=_hsv_to_rgb(h,s,v)
    if g['look'] != 'none' and g['amount'] > 0:
        out = look(base, LOOKS[g['look']]); base=np.clip(base + (out - base) * g['amount'], 0, 1)
    return user_lut(base,g['creativeLut'])


def key(grade):
    return json.dumps(normalized(grade), sort_keys=True, separators=(',', ':'))


@lru_cache(maxsize=32)
def _table(grade_key):
    i = np.linspace(0, 1, SIZE)
    b, g, r = np.meshgrid(i, i, i, indexing='ij')        # red varies fastest (.cube and PIL order)
    grid = np.stack([r, g, b], -1).reshape(-1, 3)
    return np.ascontiguousarray(apply(grid, json.loads(grade_key)), dtype=np.float32)


def table(grade):
    return _table(key(grade))


def active(e):
    return isinstance(e, dict) and isinstance(e.get('grade'), dict)


def pil(image, grade):
    """Preview: same LUT through PIL (RGBA in, RGBA out, alpha kept)."""
    from PIL import ImageFilter
    lut = _pil_filter(key(grade))
    alpha = image.getchannel('A'); rgb = image.convert('RGB').filter(lut)
    out = rgb.convert('RGBA'); out.putalpha(alpha); return out


@lru_cache(maxsize=16)
def _pil_filter(grade_key):
    from PIL import ImageFilter
    return ImageFilter.Color3DLUT(SIZE, _table(grade_key).reshape(-1).tolist())


def cube_dir():
    base = Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'EliteStudioWindows' / 'cache' / 'luts'
    base.mkdir(parents=True, exist_ok=True); return base


def cube(grade, folder=None):
    """Writes (once) the .cube for this grade and returns its path."""
    k = key(grade); path = Path(folder or cube_dir()) / f'grade-{hashlib.sha256(k.encode()).hexdigest()[:16]}.cube'
    if not path.is_file():
        rows = '\n'.join(f'{r:.6f} {g:.6f} {b:.6f}' for r, g, b in _table(k))
        tmp = path.with_suffix('.tmp'); tmp.write_text(f'TITLE "Elite Studio grade"\nLUT_3D_SIZE {SIZE}\n{rows}\n', encoding='ascii'); os.replace(tmp, path)
    return path


def ffmpeg_filter(grade, folder=None):
    p = str(cube(grade, folder)).replace('\\', '/').replace(':', r'\:')
    return f"lut3d=file='{p}':interp=tetrahedral"


# ---------- analysis ----------

def srt_profile(path):
    """DJI sidecar: [color_md : d_cinlike] marks the flat D-Cinelike profile."""
    srt = Path(path).with_suffix('.SRT')
    if not srt.is_file(): srt = Path(path).with_suffix('.srt')
    try:
        with open(srt, encoding='utf-8', errors='ignore') as f: head = f.read(4000)
    except OSError: return None
    m = re.search(r'color_md\s*:\s*([\w-]+)', head)
    return m.group(1).lower() if m else None


def stats(frames):
    """frames: list of RGB float arrays (small). Returns the 'auto' block."""
    px = np.concatenate([f.reshape(-1, 3) for f in frames])
    l = px @ LUMA
    black = float(np.percentile(l, .4)); white = float(np.percentile(l, 99.7))
    black = min(black, .25); white = max(white, black + .70)          # never more than ~1.4x gain
    n = np.clip((px - black) / (white - black), 0, 1); ln = n @ LUMA
    mid = (ln > .15) & (ln < .85)
    sel = n[mid] if mid.sum() > 100 else n
    means = sel.mean(0); target = float(means @ LUMA)
    wb = np.clip(target / np.maximum(means, 1e-4), .94, 1.06)
    wb = 1 + (wb - 1) * .6                                    # gentle: keep the light's character
    wb = wb / float(wb @ LUMA)
    median = float(np.median(np.clip(n * wb, 0, 1) @ LUMA))
    white = black + (white - black) / .97                     # a little headroom for skies and snow
    sat = float(np.mean(px.max(1) - px.min(1)))
    flat = bool(black > .035 and white < .93 and sat < .2)
    return dict(black=round(black, 4), white=round(white, 4), gamma=round(exposure_gamma(median), 4), wb=[round(float(x), 4) for x in wb],
                flat=flat, median=round(median, 4))


def exposure_gamma(median, target=.38, strength=.6):
    g = math.log(target) / math.log(min(.95, max(.05, median)))
    return float(np.clip(1 + (g - 1) * strength, .8, 1.12))


def match(autos):
    """Shot matching: every clip aims at the same middle grey (the group's average), so cuts don't jump."""
    medians = [a['median'] for a in autos if 'median' in a]
    if len(medians) < 2: return autos
    target = float(np.clip(np.mean(medians), .30, .45))
    return [dict(a, gamma=round(exposure_gamma(a['median'], target, .85), 4)) if 'median' in a else a for a in autos]


def analyze(path, samples=8, still=False):
    import cv2
    frames = []
    if still:
        from PIL import Image
        with Image.open(path) as im: frames.append(np.asarray(im.convert('RGB').resize((320, 180)), dtype=np.float32) / 255)
    else:
        cap = cv2.VideoCapture(str(path))
        try:
            n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
            for i in range(samples):
                if n > 1: cap.set(cv2.CAP_PROP_POS_FRAMES, int((i + .5) * n / samples))
                ok, bgr = cap.read()
                if not ok: continue
                frames.append(cv2.cvtColor(cv2.resize(bgr, (320, 180), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB).astype(np.float32) / 255)
        finally: cap.release()
    if not frames: raise ValueError(f'Impossibile leggere {Path(path).name}')
    auto = stats(frames)
    profile = srt_profile(path)
    if profile: auto['flat'] = profile in ('d_cinlike', 'd-cinelike', 'dlog', 'd_log', 'dlog_m', 'hlg') or auto['flat']
    return auto
