# Elite Studio per Windows

Avvio normale: **Elite Studio.exe** o collegamento Desktop. `Installa Elite Studio.bat` prepara runtime e associazione `.elitestudio`. L'eseguibile è un piccolo avviatore .NET Framework che richiede la cartella completa e il runtime Python/Qt esterno.

L'aggiornamento include fino a otto tracce, colore, dissolvenze audio/video, transizioni, keyframe (scala/posizione/rotazione/opacità/volume), testo libero, ricerca media, analisi del volume, proxy e anteprima preparata. I controlli sono divisi in Clip/Effetti/Sottotitoli. L'export propone formato/codec/qualità/bitrate e può usare una GPU disponibile, con ripiego CPU in caso di errore del driver. Il formato progetto rimane `elitestudio/1`: `effects` è facoltativo e i vecchi progetti mantengono il comportamento precedente.

Le cartelle cache/history/recovery risiedono in `%LOCALAPPDATA%\EliteStudioWindows`. La cache video è limitata a 1 GB (512 MB per singolo file); la cronologia conserva dieci copie per progetto, al massimo una al minuto. I dati di recupero includono anche progetti ancora senza nome.

Per i test aggiunti: `python -m unittest -v test_windows test_parity test_essentials` e `python test_essentials_ui.py`. L'anteprima preparata e il volume della clip si verificano anche nell'interfaccia reale.

Doppio clic su **Elite Studio - Windows** sul Desktop oppure **Start Elite Studio.bat** nella cartella principale. La guida completa e `../LEGGIMI - Avvio e comandi.txt`, disponibile dal menu Aiuto.

L'interfaccia segue la versione Mac: progetto, viewer, ispettore e tracce T/V2/V1/A1/A2/CC. Include selezione multipla/rettangolare, trascinamento e copia/incolla di gruppi, rifilatura Q/W, ripple delete, chiusura degli spazi, J/K/L, titoli e logo configurabili, Insta360 e sottotitoli modificabili.

I sottotitoli condividono JSON e stili con Mac: Negativo, Bianco, Oro, animazione pop e tempi per parola. Viewer ed export usano la stessa funzione di disegno. La trascrizione locale usa [faster-whisper](https://github.com/SYSTRAN/faster-whisper), modello base CPU int8. Scarica il modello al primo uso, poi funziona senza connessione.

## Installazione

`Ripara Elite Studio.bat` installa requirements.txt nel runtime `%LOCALAPPDATA%\EliteStudioWindows\venv` e aggiorna il collegamento Desktop. Servono Python 3.10+ e FFmpeg/ffprobe. `Diagnostica Elite Studio.bat` controlla runtime e log.

## CLI

```powershell
$python = "$env:LOCALAPPDATA\EliteStudioWindows\venv\Scripts\python.exe"
& $python .\Windows\app.py --check .\project.elitestudio
& $python .\Windows\app.py --export .\project.elitestudio .\output.mp4
& $python .\Windows\app.py --captions .\project.elitestudio --lang it-IT --words 3
```

## Verifica

Dalla cartella Windows, con il Python del runtime:

```
python -m unittest -v test_windows test_parity
python test_windows.py --ui
python test_parity_ui.py
```

`ELITE_TEST_INSV` abilita il test opzionale su riprese reali; `ELITE_TEST_SPEECH` indica un file audio per testare la trascrizione nella GUI.

## Differenze residue

Windows usa Qt/FFmpeg, Mac SwiftUI/AVFoundation/Metal. Palette e risorse Archivo sono condivise; controlli nativi e animazioni dei titoli possono differire. Apple Speech e faster-whisper possono produrre testi diversi. L'export sottotitoli Windows usa un secondo passaggio, il 360 puo essere lento, l'audio inverso e disattivato e il volume anteprima e limitato al 100% (export 200%). HEIC dipende dai decoder. Le estensioni JSON specifiche di Windows non sono tutte gestite dal Mac. I sorgenti Mac non sono compilabili su Windows: su Mac usare Avvia Elite Studio.command (macOS 26+, strumenti Xcode).
