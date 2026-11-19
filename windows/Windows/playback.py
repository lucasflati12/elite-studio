"""Native Qt preview of a pre-rendered sequence MP4 (video + audio from one file)."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path

from PySide6.QtCore import QEvent, QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget

IGNORED_MEDIA_KEYS = {'proxyPath', 'proxyFingerprint', '_probed'}
READY = (QMediaPlayer.MediaStatus.LoadedMedia, QMediaPlayer.MediaStatus.BufferedMedia, QMediaPlayer.MediaStatus.BufferingMedia)


def _stat(path):
    try:
        s = os.stat(path)
        return [s.st_size, s.st_mtime_ns]
    except OSError:
        return None


def preview_signature(project):
    """SHA256 over everything that changes rendered content (not preview, review, markers, proxies)."""
    base = Path(project.path).parent if project.path else Path.cwd()
    media = []
    for m in project.media:
        item = {k: v for k, v in m.items() if k not in IGNORED_MEDIA_KEYS}
        full = os.path.normpath(os.path.join(base, os.path.expanduser(str(m.get('path', '')))))
        item['path'] = os.path.normcase(full)
        item['file'] = _stat(full)
        media.append(item)
    payload = {'settings': project.settings, 'tracks': project.data.get('tracks', {}), 'clips': project.clips, 'media': media,
               'captions':project.data.get('captions',[]),'captionStyle':project.data.get('captionStyle',{})}
    text = json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False, default=str)
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


class SequencePreview(QObject):
    ended = Signal()
    failed = Signal(str)

    def __init__(self, viewer_widget, parent=None):
        super().__init__(parent or viewer_widget)
        self.viewer = viewer_widget
        self.valid = False
        self._key = None
        self._pending = None  # (seconds, play) applied once the media is loaded
        self.video_widget = QVideoWidget(viewer_widget)
        self.video_widget.setAspectRatioMode(Qt.AspectRatioMode.KeepAspectRatio)
        self.video_widget.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.video_widget.setStyleSheet('background:black')
        self.video_widget.setGeometry(viewer_widget.rect())
        self.video_widget.hide()
        self.player = QMediaPlayer(self)
        self.output = QAudioOutput(self)
        self.player.setAudioOutput(self.output)
        self.player.setVideoOutput(self.video_widget)
        self.player.mediaStatusChanged.connect(self._status)
        self.player.errorOccurred.connect(self._error)
        viewer_widget.installEventFilter(self)

    def eventFilter(self, obj, event):
        if obj is self.viewer and event.type() == QEvent.Type.Resize:
            self.video_widget.setGeometry(self.viewer.rect())
        return False

    def configure(self, project):
        """Enable only when the preview file exists and its fingerprint matches the project."""
        info = project.data.get('preview')
        try:
            if not isinstance(info, dict) or not info.get('path'):
                raise ValueError('no preview')
            path = Path(os.path.expanduser(str(info['path'])))
            if not path.is_absolute():
                if not project.path: raise ValueError('relative preview without project')
                path = Path(project.path).parent / path
            path = path.resolve()
            stat = _stat(path)
            if not stat or not stat[0] or info.get('fingerprint') != preview_signature(project):
                raise ValueError('stale preview')
        except Exception:
            self.invalidate()
            return False
        key = (str(path), *stat, info['fingerprint'])
        if not (self.valid and key == self._key):
            self.invalidate()
            self._key = key
            self.valid = True
            self.player.setSource(QUrl.fromLocalFile(str(path)))
        self.video_widget.setGeometry(self.viewer.rect())
        self.video_widget.show()
        return True

    def invalidate(self):
        self._pending = None
        self._key = None
        self.valid = False
        self.video_widget.hide()
        self.player.pause()
        self.player.setSource(QUrl())

    def _loaded(self):
        return self.player.mediaStatus() in READY or self.player.mediaStatus() == QMediaPlayer.MediaStatus.EndOfMedia

    def _go(self, seconds, play):
        ms = max(0, int(round(seconds * 1000)))
        duration = self.player.duration()
        if duration > 0 and ms >= duration:  # at the end play() would restart from 0
            self.player.pause()
            self.player.setPosition(duration)
            if play:
                QTimer.singleShot(0, self.ended.emit)
            return
        self.player.setPosition(ms)
        if play:
            self.player.play()

    def _request(self, seconds, play):
        if not self.valid:
            return
        self.video_widget.show()
        if self._loaded():
            self._pending = None
            self._go(seconds, play)
        else:
            self._pending = (seconds, play)

    def play(self, position_seconds=0.0):
        self._request(position_seconds, True)

    def seek(self, seconds):
        playing = self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState
        self._request(seconds, playing or bool(self._pending and self._pending[1]))

    def pause(self):
        if self._pending:
            self._pending = (self._pending[0], False)
        self.player.pause()

    def position(self):
        if self._pending:
            return self._pending[0]
        return self.player.position() / 1000.0

    def close(self):
        self.invalidate()
        self.viewer.removeEventFilter(self)
        self.video_widget.deleteLater()

    def _status(self, status):
        if status in READY and self._pending:
            seconds, play = self._pending
            self._pending = None
            self._go(seconds, play)
        elif status == QMediaPlayer.MediaStatus.EndOfMedia and self.valid:
            self.ended.emit()
        elif status == QMediaPlayer.MediaStatus.InvalidMedia and self.valid:
            self._error(self.player.error(), self.player.errorString() or 'Invalid preview media')

    def _error(self, error, message=''):
        if not self.valid:
            return
        text = message or self.player.errorString() or 'Preview playback failed'
        self.invalidate()
        self.failed.emit(text)
