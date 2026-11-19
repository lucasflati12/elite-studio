#!/bin/bash
set -e
cd "$(dirname "$0")"
BIN="Elite Studio.app/Contents/MacOS/EliteStudio"
SOURCE_KEY="$(find Sources -name '*.swift' -exec shasum -a 256 {} \; | sort | shasum -a 256 | cut -d ' ' -f 1)"
SAVED_KEY="$(cat .mac-build-key 2>/dev/null || true)"
if [ ! -f "$BIN" ] || [ "$SOURCE_KEY" != "$SAVED_KEY" ]; then
  echo "Compilo la versione Mac aggiornata…"
  if ! /bin/bash ./build.sh; then
    echo "Compilazione non riuscita. Servono macOS 26 e gli strumenti Xcode."
    echo "Per installare gli strumenti, apri Terminale ed esegui: xcode-select --install"
    read -r -p "Premi Invio per chiudere."
    exit 1
  fi
  printf '%s' "$SOURCE_KEY" > .mac-build-key
fi
open "Elite Studio.app" --args "$@"
