"""Bounded disposable caches and small crash-recovery snapshots, outside the app folder."""
from __future__ import annotations
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

SUPPORT=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows'
CACHE=SUPPORT/'cache'
CACHE_LIMIT=1024**3


def fingerprint(path):
    p=Path(path).resolve(); stat=p.stat()
    return hashlib.sha256(f'{p}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()


def prune(limit=CACHE_LIMIT,protect=()):
    CACHE.mkdir(parents=True,exist_ok=True); protected={str(Path(p).resolve()) for p in protect}
    files=sorted((p for p in CACHE.iterdir() if p.is_file()),key=lambda p:p.stat().st_mtime)
    total=sum(p.stat().st_size for p in files)
    for p in files:
        if total<=limit: break
        if str(p.resolve()) in protected: continue
        try: size=p.stat().st_size; p.unlink(); total-=size
        except OSError: pass
    return total


def proxy(media,cancel=None):
    from core import tool,CREATE_FLAGS
    if not media.get('hasVideo') or media.get('still') or media.get('pano'): return None
    key=fingerprint(media['path']); CACHE.mkdir(parents=True,exist_ok=True); target=CACHE/f'proxy-{key}.mp4'
    if target.is_file(): return str(target),key
    part=target.with_suffix('.part.mp4'); prune()
    scale="scale=w='max(2,trunc(iw*min(1,960/max(iw,ih))/2)*2)':h='max(2,trunc(ih*min(1,960/max(iw,ih))/2)*2)'"
    with part.with_suffix('.log').open('w+b') as log:
        proc=subprocess.Popen([tool('ffmpeg'),'-v','error','-y','-i',media['path'],'-map','0:v:0','-vf',scale,
                               '-an','-c:v','libx264','-preset','veryfast','-crf','28','-pix_fmt','yuv420p',str(part)],stdout=subprocess.DEVNULL,stderr=log,creationflags=CREATE_FLAGS|getattr(subprocess,'BELOW_NORMAL_PRIORITY_CLASS',0))
        try:
            while proc.poll() is None:
                if cancel is not None and cancel.wait(.1): raise RuntimeError('Creazione proxy annullata')
                if cancel is None: time.sleep(.1)
                if part.exists() and part.stat().st_size>CACHE_LIMIT//2: raise RuntimeError('Video troppo lungo per la cache proxy limitata')
            if proc.returncode:
                log.seek(0); raise RuntimeError(log.read().decode(errors='replace')[-2000:])
            if part.stat().st_size>CACHE_LIMIT//2: raise RuntimeError('Proxy troppo grande per la cache limitata')
            os.replace(part,target); prune(protect=[target]); return str(target),key
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
            if part.exists(): part.unlink()


def recovery_path(): return SUPPORT/'recovery'/f'session-{os.getpid()}.elitestudio'


def recoverable():
    folder=SUPPORT/'recovery'
    def active(pid):
        import ctypes
        h=ctypes.windll.kernel32.OpenProcess(0x1000,False,pid)
        if not h: return False
        try:
            code=ctypes.c_ulong(); ctypes.windll.kernel32.GetExitCodeProcess(h,ctypes.byref(code)); return code.value==259
        finally: ctypes.windll.kernel32.CloseHandle(h)
    return sorted((p for p in folder.glob('session-*.elitestudio') if not active(int(p.stem.split('-')[-1]))),key=lambda p:p.stat().st_mtime,reverse=True) if folder.exists() else []


def snapshot(project):
    from core import Project
    p=Project(); p.data=copy.deepcopy(project.data)
    if project.path: p.data['_recoverySource']=str(project.path)
    p.save(recovery_path())
    snapshots=list(recovery_path().parent.glob('session-*.elitestudio'))
    if len(snapshots)>20:
        old=sorted(recoverable(),key=lambda f:f.stat().st_mtime)
        for path in old[:len(snapshots)-20]: path.unlink(missing_ok=True)


def discard_recovery():
    path=recovery_path()
    if path.exists(): path.unlink()


def backup(path):
    """At most ten compact project versions; create at most one per minute."""
    import shutil
    p=Path(path)
    if not p.is_file(): return
    key=hashlib.sha256(str(p.resolve()).encode()).hexdigest()[:16]; folder=SUPPORT/'history'/key; folder.mkdir(parents=True,exist_ok=True)
    files=sorted(folder.glob('*.elitestudio'),key=lambda f:f.stat().st_mtime)
    if files and time.time()-files[-1].stat().st_mtime<60: return
    target=folder/(time.strftime('%Y%m%d-%H%M%S')+'.elitestudio')
    # Store absolute paths so a snapshot can be restored from the history directory.
    raw=json.loads(p.read_text(encoding='utf-8-sig'))
    for m in raw.get('media',[]):
        media=Path(m['path']); m['path']=str(media if media.is_absolute() else (p.parent/media).resolve())
    target.write_text(json.dumps(raw,ensure_ascii=False),encoding='utf-8')
    for f in files[:-9]: f.unlink()


def history(path):
    if not path: return []
    key=hashlib.sha256(str(Path(path).resolve()).encode()).hexdigest()[:16]
    return sorted((SUPPORT/'history'/key).glob('*.elitestudio'),reverse=True)
