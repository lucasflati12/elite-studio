"""Compact export presets and optional hardware encode, without bundling extra codecs."""
from functools import lru_cache
import subprocess


@lru_cache(maxsize=4)
def encoder(hevc=False,hardware=False):
    from core import tool,CREATE_FLAGS
    if hardware:
        for candidate in (['hevc_nvenc','hevc_qsv','hevc_amf'] if hevc else ['h264_nvenc','h264_qsv','h264_amf']):
            try:
                result=subprocess.run([tool('ffmpeg'),'-v','error','-f','lavfi','-i','color=s=128x128:r=30','-frames:v','1','-c:v',candidate,'-f','null','-'],capture_output=True,timeout=6,creationflags=CREATE_FLAGS)
                if not result.returncode: return candidate
            except (OSError,subprocess.TimeoutExpired): pass
    return 'libx265' if hevc else 'libx264'


def codec_args(name,quality='balanced',bitrate=0):
    args=['-c:v',name]
    if name.startswith('libx'): args+=['-preset','fast','-crf','18' if quality=='high' else '23' if quality=='small' else '20']
    elif 'nvenc' in name: args+=['-preset','fast','-b:v',str(bitrate or 12_000_000)]
    else: args+=['-b:v',str(bitrate or 12_000_000)]
    if bitrate and name.startswith('libx'): args+=['-b:v',str(bitrate),'-maxrate',str(bitrate),'-bufsize',str(bitrate*2)]
    return args+['-pix_fmt','yuv420p']


def choose(editor):
    from PySide6.QtWidgets import QDialog,QVBoxLayout,QFormLayout,QComboBox,QCheckBox,QDialogButtonBox,QLabel
    dialog=QDialog(editor); dialog.setWindowTitle('Esporta video'); layout=QVBoxLayout(dialog); form=QFormLayout(); layout.addLayout(form)
    preset=QComboBox(); preset.addItems(['Formato della sequenza','Verticale · 1080×1920','Orizzontale · 1920×1080','Quadrato · 1080×1080','Anteprima · lato lungo 720']); form.addRow('Formato',preset)
    codec=QComboBox(); codec.addItems(['H.264 · compatibilità','HEVC · file più piccolo']); form.addRow('Codec',codec)
    quality=QComboBox(); quality.addItems(['Bilanciata','Alta','File più piccolo']); form.addRow('Qualità',quality)
    bitrate=QComboBox(); bitrate.addItems(['Automatico','6 Mbps','10 Mbps','20 Mbps']); form.addRow('Bitrate',bitrate)
    hardware=QCheckBox('Usa codifica hardware se disponibile'); hardware.setChecked(True); layout.addWidget(hardware)
    layout.addWidget(QLabel('La sequenza di montaggio resta invariata. Vengono usati i file originali.'))
    buttons=QDialogButtonBox(QDialogButtonBox.StandardButton.Ok|QDialogButtonBox.StandardButton.Cancel); buttons.accepted.connect(dialog.accept); buttons.rejected.connect(dialog.reject); layout.addWidget(buttons)
    if dialog.exec()!=QDialog.DialogCode.Accepted: return None
    return dict(preset=preset.currentIndex(),hevc=bool(codec.currentIndex()),quality=['balanced','high','small'][quality.currentIndex()],hardware=hardware.isChecked(),bitrate=[0,6_000_000,10_000_000,20_000_000][bitrate.currentIndex()])


def apply_preset(project,index):
    sizes={1:(1080,1920),2:(1920,1080),3:(1080,1080)}
    if index in sizes: project.settings.update(zip(('width','height'),sizes[index]))
    elif index==4:
        factor=min(1,720/max(project.settings['width'],project.settings['height']))
        for key in ('width','height'): project.settings[key]=max(2,round(project.settings[key]*factor/2)*2)
