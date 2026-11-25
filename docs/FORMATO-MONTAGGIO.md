# Campi di montaggio condivisi (Round 3a)

I campi sotto sono opzionali. Se mancano, il progetto conserva il comportamento storico. I valori temporali sono secondi; le velocità sono moltiplicatori (1 = velocità originale). I renderer devono ignorare i metadati sconosciuti.

## `markers` — array sul progetto

Ogni elemento ha `t` (number, predefinito `0`, tempo sequenza non negativo), `name` (string, predefinito `""`) e `color` (stringa CSS esadecimale, predefinito `"#e4ca4a"`). Il marker è disegnato sul righello alla posizione `t`, con triangolo e linea verticale del colore indicato; `name` è mostrato accanto al righello. I marker non alterano il rendering dei fotogrammi.

## Campi delle clip

| Campo | Tipo e default | Semantica e rendering |
|---|---|---|
| `speed` | number, `1` | Velocità di riproduzione; già supportata. La durata sequenza è la lunghezza sorgente divisa per questo valore. Preview ed export campionano lo stesso tempo sorgente. |
| `pitch` | boolean, `true` | Se `true`, l'audio usa `atempo` e conserva l'intonazione. Se `false`, cambia anche l'intonazione tramite ricampionamento. Senza il campo vale `true`. |
| `speedRamp` | oggetto opzionale | Metadato descrittivo per una sezione della curva: `preset` (stringa: `Montagna`, `Bullet`, `Ingresso veloce`, `Uscita veloce`), `segment` (intero 0–2), `points` (array di tre moltiplicatori numerici). La curva è materializzata in tre clip adiacenti con `speed` e intervalli `in` ordinari; la riproduzione/export usa quei campi `speed`. Il campo descrittivo non deve causare una seconda accelerazione. |
| `freezeFrame` | boolean, `false` | Indica una clip immagine ottenuta dal fotogramma scelto. La sua durata è `duration` (2 s per il comando Windows); preview ed export trattano la sorgente come immagine statica. I progetti che la omettono non cambiano. |
| `freezeSource` | oggetto opzionale | `{ "media": string, "time": number }`. `media` è l'ID della sorgente; `time` è il tempo in secondi nella sorgente. Riferimento per rigenerare il fotogramma quando il PNG di cache Windows non è disponibile. `freezeFrame` e `freezeSource` vengono salvati sul segmento immagine congelato. |
| `reversed` | boolean, `false` | Indica che la sorgente della clip è un file intermedio già invertito, con audio invertito se presente. Il renderer legge il file dall'inizio usando `in: 0`; non applica una seconda inversione. Windows produce e riusa il file in cache. |
| `reverseSource` | oggetto opzionale | `{ "media": string, "in": number, "duration": number }`. `media` è l'ID della sorgente originale; `in` e `duration` delimitano l'intervallo in secondi. Consente di rigenerare l'intermedio invertito se non esiste più. `duration` qui è la lunghezza dell'intervallo sorgente, quindi in Windows corrisponde a `clip.duration * clip.speed` al momento dell'inversione. |
| `crop` | oggetto opzionale | Frazioni normalizzate `left`, `right`, `top`, `bottom`, ciascuna number tra `0` e `0.85`, default `0`. Sono percentuali del bordo della sorgente rimosse prima del fit/fill; la somma dei due lati di un asse non supera `0.85`. |
| `flipH`, `flipV` | boolean, entrambi `false` | Specchia orizzontalmente o verticalmente il fotogramma ritagliato prima del fit. |
| `background` | oggetto opzionale | Per ora `{ "type": "blur", "amount": 12 }`. `amount` è un raggio positivo in pixel alla risoluzione della sequenza, ammesso tra 0 e 50. Quando la clip è adattata con bande, il renderer riempie la tela con una copia ingrandita e sfocata della clip, poi sovrappone la copia nitida adattata. `fill: true` mantiene il comportamento di riempimento esistente e non usa questo sfondo. |

## Equivalenza dei renderer

Windows applica crop/specchio/sfondo nella preview Pillow e nell'export FFmpeg. Lo sfondo usa box blur e centratura; la preview riduce il raggio in proporzione alla risoluzione della preview. Un port può usare un blur gaussiano nativo, mantenendo la stessa sorgente, ritaglio, ingrandimento, centratura e quantità relativa. I campi neutral (ritaglio zero, flip falso, nessun background, speed 1) devono restare sul percorso originale.

Il comando Speed/Duration può materializzare una curva in clip contigue. Un port deve rispettare `start`, `duration`, `in` e `speed` di ciascun segmento; questi campi sono la definizione di playback, mentre `speedRamp` è solo descrittivo.


## Campi aggiunti Round 3b (Windows; port Mac)

Tutti i campi seguenti sono opzionali. Se assenti, valgono i default indicati e il rendering storico resta invariato.

| Campo JSON | Posizione, tipo e default | Rendering |
|---|---|---|
| `transition` | Clip entrante; oggetto opzionale `{ "type": "Dissolvenza al nero", "duration": 0.5 }`. `type` stringa: `Dissolvenza al nero`, `Scorrimento sinistra`, `Scorrimento destra`, `Scorrimento su`, `Scorrimento giù`, `Zoom`, `Wipe`, `Sfocatura`; durata number in secondi, default `0.5`, minimo `0.05`. | Si applica all'inizio della clip selezionata e dura `duration`. Preview ed export implementano dissolve/slide/blur; `Zoom` e `Wipe` usano una dissolvenza alpha semplificata in Windows. La preview puo approssimare gli effetti FFmpeg. Nessun effetto se il campo manca. |
| `title.animationIn` | Oggetto `title`; stringa opzionale, default `Nessuna`. Valori `Nessuna`, `Dissolvenza`, `Scorri su`, `Pop/Scala`, `Macchina da scrivere`. | L'entrata dura al massimo 0.7 s. Scorri su e animato nella preview e nell'export; Pop/Scala usa una dissolvenza semplificata in entrambi. `Macchina da scrivere` e reso come entrata graduale, senza rivelazione lettera per lettera. |
| `title.animationOut` | Oggetto `title`; stringa opzionale, default `Nessuna`; valori `Nessuna`, `Dissolvenza`, `Scorri su`, `Pop/Scala`. | L'uscita e associata alla fine della clip titolo; Windows applica dissolvenza alpha per l'export. |
| `title.stylePreset` | Oggetto `title`; stringa opzionale, default `Normale`; valori `Normale`, `Contorno`, `Ombra`, `Sfondo box`. | Stile applicato alla bitmap titolo prima del compositing. Preview ed export Windows usano lo stesso PNG generato. |
| `volume` | Clip; number lineare, default `1`, ammesso `0` (meno infinito dB) fino a `4` (+12.04 dB). | `10^(dB/20)` e il guadagno mostrato dall'ispettore. Export usa il filtro volume FFmpeg; il campo e compatibile con i keyframe `effects.keys[].volume`. |
| `noiseReduction` | Clip audio; boolean, default `false`. | Se `true`, Windows export inserisce FFmpeg `afftdn` prima del mix. Windows preview non applica la riduzione. Il port Mac puo ignorare il campo, poiche AVAudioMix non offre qui un equivalente leggero; l'UI Mac deve segnalarlo come solo export Windows. |
| `chromaKey` | Clip video; oggetto opzionale `{ "color": "#00ff00", "tolerance": 0.12, "softness": 0.08 }`. `color` stringa esadecimale CSS, default verde; tolleranza e morbidezza number normalizzati in `[0.001, 0.5]` (tolleranza default `0.12`, morbidezza default `0.08`). | Rimuove il colore selezionato con alpha progressiva. Windows preview usa distanza RGB Pillow/numpy; export usa FFmpeg `chromakey`. Applica il key prima del fit e del compositing. |
| `audioDisabled` | Clip; boolean, default `false`. | Disattiva l'audio incorporato di quella clip, utile dopo averlo separato. Non cambia la traccia video. |
| `audioDetached` | Clip audio separata; boolean, default `false`. | Metadato descrittivo. La clip usa un media entry `hasVideo: false` e la normale traccia audio; il renderer la riproduce come audio autonomo. |

La riduzione musica sotto la voce Windows crea normali keyframe `effects.keys[].volume` sulla clip musica (valori media-time e guadagno lineare). Non introduce un campo proprietario e quindi la curva viene riutilizzata dai renderer che gia supportano i keyframe volume.
