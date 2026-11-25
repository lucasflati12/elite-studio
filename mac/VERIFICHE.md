# Verifiche macOS — Colore — da verificare sul Mac

- [ ] Compilare l'app e controllare eventuali diagnostiche SwiftUI/AppKit.
- [ ] Confrontare la stessa immagine e lo stesso grade con Windows: curve Master/R/G/B, curve HSL, look e ordine dei controlli.
- [ ] Importare LUT `.cube` 1D e 3D con `TITLE`, commenti e domain personalizzato; verificare intensità, file mancante e ricarica dopo modifica dell'mtime.
- [ ] Provare i quattro wheel e il master, i reset per scheda e un singolo Annulla dopo ciascun trascinamento.
- [ ] Verificare waveform, parade, vectorscope e istogramma durante bypass e grading.
- [ ] Provare copia/incolla da Colore e Cmd+Shift+C/V; controllare che l'incolla conservi l'`auto` di ogni clip.
- [ ] Applicare a tutte le clip e alla traccia selezionata; verificare undo.
- [ ] Salvare, caricare ed eliminare preset nella cartella grades; confermare che il JSON non contenga `auto`.
- [ ] Aprire un progetto con grade precedente e confrontare la tabella/anteprima con il riferimento Windows.

## Montaggio condiviso Round 3c — verifiche da fare su Mac

- [ ] Compilare su macOS 26+ con Xcode e controllare diagnostiche Swift e Metal; il port non è stato compilato in questo ambiente Windows.
- [ ] Aprire e risalvare progetti Round 3a/3b: confrontare `markers`, `speed`, `pitch`, `speedRamp`, `freezeFrame`, `freezeSource`, `reversed`, `reverseSource`, `crop`, `flipH`, `flipV`, `background`, `transition`, titolo, audio e chroma key nel JSON.
- [ ] Verificare M / Shift+M / Cmd+Shift+M, disegno dei marker, Cmd+R, Shift+F, Cmd+Shift+E, A, virgola e punto; verificare undo e redo delle modifiche.
- [ ] Verificare velocità e rampe con clip di durata nota, tagli sorgente, spostamento delle clip successive e keyframe dei sottotitoli; confrontare audio a pitch conservato e ricampionato.
- [ ] Verificare fermo immagine di 2 s su playhead dentro clip, split delle clip attraversate, spostamento delle successive e collegamento `freezeSource`.
- [ ] Verificare inversione video e audio con file sorgente sintetico e cache persistente; la generazione del file invertito non è ancora implementata nel port Mac.
- [ ] Confrontare crop, flip, canvas blur (bande e `fill`), chroma key e transizioni nella preview e nell'export GPU; provare trasparenza e compositing su più tracce.
- [ ] Verificare titoli animati e preset di stile in preview ed export, incluso il comportamento semplificato di Macchina da scrivere.
- [ ] Verificare volume da 0 a 4, ducking tramite `effects.keys[].volume`, separazione audio e `audioDisabled`; confermare che `noiseReduction` resta nel JSON e mostri “solo export Windows”.
- [ ] Esportare un PNG a risoluzione di sequenza con più tracce, titoli, chroma key e grading; confrontarlo con il frame esportato dal video.
- [ ] Verificare il comportamento di `pitch: false`: al momento il flag è conservato nel JSON, ma AVFoundation usa l'algoritmo pitch-preserving per l'intera traccia.
