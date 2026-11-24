# Verifica della revisione essenziale

Verificato su questo PC Windows il 5 novembre 2026.

- 37 test automatici: 36 riusciti, uno escluso perché richiede riprese Insta360 reali (`ELITE_TEST_INSV`).
- Tre prove della GUI Qt: montaggio di base; selezione/gruppi/sottotitoli; nuove funzioni essenziali.
- Verificati fotogrammi esportati per colore, opacità, posizione, scala/rotazione, dissolvenze e transizioni; verificato l'audio per dissolvenze e keyframe di volume.
- Verificati tracce aggiuntive, salvataggio e ricaricamento, protezione dell'output su errore/annullamento, ripiego CPU su errore hardware, proxy e limite della cache, recupero e cronologia dei progetti.
- Provata la codifica H.264 hardware disponibile su questo PC (`h264_qsv`) anche con sottotitoli. La selezione dei driver è automatica; altri dispositivi richiedono la propria verifica.
- Verificato `Elite Studio.exe` con un progetto il cui percorso contiene spazi; collegamento Desktop aggiornato e associazione `.elitestudio` registrata per l'utente.

## Stabilizzazione 360 (24 novembre 2026)

- Corretto: il giroscopio ora viene letto all'istante del fotogramma decodificato, non all'istante della timeline. Prima i due differivano fino a mezzo fotogramma, e in modo variabile quando gli fps dell'export erano diversi da quelli della camera: ne risultava un tremolio residuo.
- Misurato su riprese reali Insta360 One R (movimento residuo con stabilizzazione e direzione bloccata, export a 30 fps): clip a 50 fps da 2,53 a 0,78 px/fotogramma; 25 fps da 8,81 a 4,43; 29,97 fps da 1,51 a 1,08 e da 2,51 a 2,24.
- Il giroscopio spiega circa il 90% della rotazione vista nell'immagine (assi e scala corretti, sincronizzazione ≈ 0 ms); il resto è soprattutto movimento reale e parallasse. Rolling shutter non ancora compensato.
- 41 test automatici riusciti, compreso quello con riprese reali (`ELITE_TEST_INSV`) e un nuovo test sul tempo del fotogramma; le due prove GUI Qt riuscite.

## Misurazione indicativa delle prestazioni

Esportazione di un video sintetico 1280×720, 30 fps, durata 3 secondi, senza effetti, su questo PC. Mediana di tre esecuzioni alternate dei sorgenti precedenti e aggiornati, stesso materiale e codifica CPU:

| Versione | Tempo mediano |
|---|---:|
| Precedente | 1,82 s |
| Aggiornata | 1,40 s |

È un controllo limitato della mancata regressione sul percorso normale, non una misura generale per tutti i codec o per video 4K/360. I tempi comprendono l'avvio di FFmpeg e risentono dei processi in esecuzione.

Nessuna nuova dipendenza o modello scaricato per questa revisione. La cartella del progetto è circa 5,3 MiB includendo il bytecode Python generato dai test. L'avviatore Windows occupa 112 KB. Il runtime Python/Qt esistente è esterno alla cartella (circa 483 MiB nel suo ambiente dedicato, oltre a eventuali librerie condivise); anche il modello vocale e le cache sono esterni. La cache video conserva fino a 1 GiB e le versioni salvate sono limitate a dieci per progetto.

## Mac

Aggiornati modello JSON, motore Metal, mix audio, ispettori, timeline, cronologia e preset di esportazione. I sorgenti **non sono stati compilati né eseguiti su macOS**: questa verifica rimane necessaria su un Mac con macOS 26 e strumenti Xcode. L'app precompilata inclusa resta quella dello ZIP originale fino alla ricompilazione con `Avvia Elite Studio.command`.

## Ripetere i controlli Windows

Dalla cartella `Windows`, usando il Python di `%LOCALAPPDATA%\EliteStudioWindows\venv\Scripts\python.exe`:

```text
python -m unittest -v test_windows test_parity test_essentials
python test_windows.py --ui
python test_parity_ui.py
python test_essentials_ui.py
```
