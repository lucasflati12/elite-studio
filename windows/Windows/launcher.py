"""Double-click entry point with dependency check and a visible startup error."""
import ctypes
import importlib.util
import os
from pathlib import Path
import subprocess
import sys


def main():
    folder=Path(__file__).resolve().parent
    required=['PySide6','cv2','numpy','scipy','PIL','fontTools','faster_whisper']
    if any(importlib.util.find_spec(name) is None for name in required):
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(folder/'setup.ps1')])
        if result.returncode: raise RuntimeError('Installazione incompleta. Esegui Ripara Elite Studio.bat nella cartella del programma.')
    sys.path.insert(0,str(folder))
    from core import tool
    tool('ffmpeg'); tool('ffprobe')
    runtime=Path(sys.executable).with_name('pythonw.exe')
    subprocess.Popen([str(runtime),str(folder/'app.py'),*sys.argv[1:]],cwd=folder.parent,
                     creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))


if __name__=='__main__':
    try: main()
    except Exception as e:
        ctypes.windll.user32.MessageBoxW(None,str(e),'Elite Studio - Avvio',16)
        sys.exit(1)
