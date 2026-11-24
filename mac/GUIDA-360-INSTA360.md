# Insta360 360° su Mac — gestire e reinquadrare i video

**Scarica tutto pronto (programma + guida):**
[Insta360-360-su-Mac.zip](https://github.com/lucasflati12/elite-studio/releases/latest/download/Insta360-360-su-Mac.zip)

Lo ZIP contiene la cartella `Elite Studio Mac` (gli stessi sorgenti di questa cartella `mac/`) e questa guida in formato testo.

## 1. Controlla prima il MacBook

Menu Apple > **Informazioni su questo Mac**:

- Chip: **Apple M1/M2/M3/M4…** (non Intel)
- macOS: **26 o successivo**

Se il Mac è Intel o ha un macOS più vecchio, Elite Studio non funziona: vai al [punto 7](#7-alternative-gratuite-mac-intel-o-macos-più-vecchio).

## 2. Installa Elite Studio (solo la prima volta)

1. Scarica lo ZIP dal link qui sopra. Safari lo estrae da solo in Download; altrimenti fai doppio clic sullo ZIP.
2. Apri **Terminale** e installa gli strumenti Apple per compilare:
   ```bash
   xcode-select --install
   ```
3. Nella cartella `Elite Studio Mac` fai doppio clic su **`Avvia Elite Studio.command`**. La prima volta compila (~20–60 s), poi apre il programma.
   - Se macOS lo blocca ("sviluppatore non identificato"): Impostazioni di Sistema > Privacy e sicurezza > **Apri comunque**.
   - Oppure, sempre funzionante, in Terminale:
     ```bash
     cd ~/Downloads/"Insta360 360 su Mac"/"Elite Studio Mac"
     bash "Avvia Elite Studio.command"
     ```
4. Le volte successive basta il doppio clic sul `.command`, oppure apri `Elite Studio.app` creato nella stessa cartella.

## 3. Copia i video dalla Insta360

Dalla scheda SD (`DCIM/Camera01`) copia sul Mac, **nella stessa cartella**:

| File | Cosa è |
|---|---|
| `VID_…_00_….insv` | lente 1 |
| `VID_…_10_….insv` | lente 2 — **indispensabile**, accanto al `_00_` |
| `LRV_…_11_….insv` | anteprima a bassa qualità, facoltativo |

Non rinominare i file e non passarli prima da altre app: servono i dati del giroscopio e della calibrazione scritti dalla camera in fondo al file. Testato con **Insta360 ONE R 360**; altri modelli non sono verificati.

## 4. Reinquadra in Elite Studio

1. **Cmd+I** (Importa media…) e scegli **solo** il file `_00_.insv`. La seconda lente viene presa da sola; gli LRV vengono nascosti.
2. Trascina la clip sulla timeline. Formato: 9:16 verticale (1080×1920) per i reel, oppure 16:9, 4:5, 1:1.
3. Seleziona la clip: nell'ispettore a destra c'è la sezione **360°**.
   - Trascina nel visore per scegliere dove guardare.
   - Direzione, Inclinazione, Rotazione, Campo visivo.
   - Prospettiva: Normale → Grandangolo → **Pianeta** (little planet).
   - **Stabilizzazione (giroscopio)**: lasciala accesa.
   - **Blocca direzione**: acceso = l'inquadratura resta ferma nel mondo anche se la camera gira; spento = segue la camera in modo morbido (**Morbidezza** = quanti secondi impiega a seguirla).
4. **Keyframe** (panoramiche automatiche): sposta il cursore e cambia l'inquadratura, si crea un keyframe ◆. Tra due keyframe il movimento è fluido. Ci sono anche "◆ Aggiungi", "Rimuovi", "Cancella tutti" e le frecce per il keyframe precedente/successivo.
5. Taglia, aggiungi titoli e sottotitoli come per i video normali.
6. **Cmd+E** (Esporta video…): scegli formato e qualità e salva l'MP4.

Spazio = play/stop, Cmd+S = salva il progetto `.elitestudio`.

## 5. Se qualcosa non va

- **Si vede solo mezza sfera**: il file `_10_` non è nella stessa cartella del `_00_`, oppure è stato rinominato.
- **"non è un file Insta360" / "metadati Insta360 mancanti" o "danneggiati"**: il file è stato riparato o convertito da un'altra app e ha perso i dati della camera. Ricopialo dalla scheda SD.
- **La compilazione fallisce**: controlla il punto 1 (Apple Silicon + macOS 26) e rifai `xcode-select --install`.
- I progetti `.elitestudio` si aprono anche su Windows: tieni i media accanto al progetto; se li hai spostati usa File > Ricollega file mancanti.

## 6. Novità (24/11/2026)

Corretto un tremolio residuo della stabilizzazione 360: il giroscopio ora viene letto all'istante esatto del fotogramma mostrato. È la stessa correzione della versione Windows, provata lì su riprese reali. Sul Mac la modifica (commit `c5c8f9a`) **non è ancora stata compilata**: se al primo avvio la compilazione dà errore e hai Claude Code, aprilo nella cartella `Elite Studio Mac`, incolla l'errore e chiedigli di sistemarlo.

## 7. Alternative gratuite (Mac Intel o macOS più vecchio)

- **Insta360 Studio** (app ufficiale, gratis): insta360.com > Supporto > Download > ONE R > Insta360 Studio per macOS. Ha la stabilizzazione FlowState, la reinquadratura con keyframe e l'export in 360° vero (per YouTube/VR).
- **App Insta360 sul telefono**: copia i file e reinquadra da lì.

Elite Studio non esporta ancora in 360° "sferico": per un video 360 da caricare su YouTube usa Insta360 Studio.
