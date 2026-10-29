#!/bin/sh
# TDfocus pour Linux : installation dans le dossier personnel, SANS droits root.
#   sh install-linux.sh [-NoAutostart] [-NoLaunch]
# Si PowerShell 7 n'est pas installé, une version portable est téléchargée dans
# ~/.local/share/TDfocus/pwsh (variable PWSH_VERSION pour choisir la version).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
PORTABLE="$DATA_HOME/TDfocus/pwsh"
PWSH_VERSION=${PWSH_VERSION:-7.6.0}

pwsh_major() {
    "$1" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null || echo 0
}

find_pwsh() {
    if command -v pwsh >/dev/null 2>&1 && [ "$(pwsh_major pwsh)" -ge 7 ] 2>/dev/null; then
        command -v pwsh
    elif [ -x "$PORTABLE/pwsh" ]; then
        echo "$PORTABLE/pwsh"
    fi
}

install_portable_pwsh() {
    case "$(uname -m)" in
        x86_64 | amd64) arch=x64 ;;
        aarch64 | arm64) arch=arm64 ;;
        armv7* | armhf) arch=arm32 ;;
        *) echo "Architecture non prise en charge : $(uname -m). Installe PowerShell 7 : https://aka.ms/powershell" >&2; exit 1 ;;
    esac
    if [ "$arch" = x64 ] && ldd --version 2>&1 | grep -qi musl; then arch=musl-x64; fi
    url="https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-linux-$arch.tar.gz"
    echo "  PowerShell 7 introuvable : téléchargement de la version portable $PWSH_VERSION ($arch), sans root..."
    archive=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar "$url" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$archive" "$url"
    else
        echo "Installe curl ou wget, ou PowerShell 7 : https://aka.ms/powershell" >&2
        exit 1
    fi
    rm -rf "$PORTABLE"
    mkdir -p "$PORTABLE"
    tar -xzf "$archive" -C "$PORTABLE"
    rm -f "$archive"
    chmod +x "$PORTABLE/pwsh"
}

echo ""
echo "  TDfocus - installation pour Linux (sans droits root)"
echo ""

PWSH=$(find_pwsh)
if [ -z "$PWSH" ]; then
    install_portable_pwsh
    PWSH="$PORTABLE/pwsh"
fi

# Sans la bibliothèque ICU, .NET doit fonctionner en mode « invariant ».
if ! "$PWSH" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
    if DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 "$PWSH" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
        export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
        set -- "$@" -InvariantGlobalization
    else
        echo "PowerShell ($PWSH) ne démarre pas. Voir https://aka.ms/powershell" >&2
        exit 1
    fi
fi

exec "$PWSH" -NoLogo -NoProfile -File "$HERE/Install-TDfocus.Linux.ps1" -PwshPath "$PWSH" "$@"
