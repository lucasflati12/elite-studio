"""Read actual decoded PCM through Qt's existing audio output, without another decoder."""
import math
import time
import numpy as np
from PySide6.QtCore import QTimer
from PySide6.QtMultimedia import QAudioBufferOutput,QAudioFormat


def attach(editor,player,output):
    if not hasattr(editor,'meter_levels'):
        editor.meter_levels={}
        timer=QTimer(editor); timer.setInterval(100)
        def update():
            levels=[peak for peak,stamp in editor.meter_levels.values() if time.monotonic()-stamp<.25] if editor.playing else []
            peak=sum(levels); db=max(-60,min(6,20*math.log10(max(.000001,peak))))
            editor.audio_meter.setValue(max(0,min(60,round(db+60))))
            editor.audio_meter.setFormat(f'{db:.0f} dBFS' if levels else 'Audio')
        timer.timeout.connect(update); timer.start(); editor.meter_timer=timer
    buffer_output=QAudioBufferOutput(editor)
    formats={QAudioFormat.SampleFormat.Float:('float32',1),QAudioFormat.SampleFormat.Int16:('int16',32768),QAudioFormat.SampleFormat.Int32:('int32',2147483648),QAudioFormat.SampleFormat.UInt8:('uint8',128)}
    def received(buffer):
        info=formats.get(buffer.format().sampleFormat())
        if not info or not buffer.byteCount(): return
        samples=np.frombuffer(buffer.constData(),dtype=info[0])
        if not samples.size: return
        # Signed conversion prevents abs(-32768) overflow; uint8 has a midpoint of 128.
        values=samples.astype(np.float32)
        if info[0]=='uint8': values-=128
        peak=float(np.max(np.abs(values)))/info[1]*output.volume()
        editor.meter_levels[id(player)]=(peak,time.monotonic())
    buffer_output.audioBufferReceived.connect(received); player.setAudioBufferOutput(buffer_output)
