#!/bin/sh
# TDfocus pour Linux : désinstallation (sans droits root).
#   sh uninstall-linux.sh           retire l'application, garde tes tâches et réglages
#   sh uninstall-linux.sh --purge   supprime aussi les données
set -eu

DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA=${TDFOCUS_DATA:-"$CONFIG_HOME/TDfocus"}

rm -f "$HOME/.local/bin/tdfocus" \
      "$DATA_HOME/applications/tdfocus.desktop" \
      "$CONFIG_HOME/autostart/tdfocus.desktop"
# Application, PowerShell portable éventuel et sons préparés
rm -rf "$DATA_HOME/TDfocus"

echo "TDfocus est désinstallé (commande, menu, lancement automatique)."
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$DATA"
    echo "Données supprimées : $DATA"
else
    echo "Tes tâches et réglages sont conservés dans $DATA"
    echo "(sh uninstall-linux.sh --purge pour les supprimer aussi)."
fi
