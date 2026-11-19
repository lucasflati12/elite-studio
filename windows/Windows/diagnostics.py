import importlib
import os
from pathlib import Path
import sys

print('Elite Studio - Diagnostica\nPython:',sys.version.split()[0])
print('Runtime:',sys.executable)
for name in ['PySide6','cv2','numpy','PIL','scipy','fontTools','faster_whisper']:
    try:
        module=importlib.import_module(name); print(name,': OK',getattr(module,'__version__',''))
    except Exception as e: print(name,': ERRORE',e)
from core import tool
for name in ['ffmpeg','ffprobe']:
    try: print(name,': OK',tool(name))
    except Exception as e: print(name,': ERRORE',e)
log=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'EliteStudioWindows/error.log'
if log.exists(): print('\nUltimo errore registrato:\n'+log.read_text(encoding='utf-8'))
print('\nIn caso di dipendenze mancanti: esegui Ripara Elite Studio.bat.')
