#!/bin/bash
# Builds dist/ClipStack.exe from the C# in windows/ClipStack.ps1 and windows/app/.
# Needs the .NET SDK (any OS). Set DOTNET if it isn't on PATH.
#
#   ./windows/build-exe.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(cat "$ROOT/VERSION")}"
DOTNET="${DOTNET:-$(command -v dotnet)}"
WORK="$(mktemp -d -t clipstack-exe)"
trap 'rm -rf "$WORK"' EXIT

cp "$ROOT"/windows/app/{ClipStack.App.csproj,Main.cs,ClipStack.ico,app.manifest} "$WORK/"
awk "/^\\\$source = @'/{f=1;next} /^'@/{f=0} f" "$ROOT/windows/ClipStack.ps1" | tr -d '\r' > "$WORK/ClipStack.cs"
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build "$WORK/ClipStack.App.csproj" -c Release -nologo -v q \
    -p:ClipStackVersion="$VERSION" -o "$WORK/out" | grep -E "error|warning" || true
mkdir -p "$ROOT/dist"
cp "$WORK/out/ClipStack.exe" "$ROOT/dist/ClipStack.exe"
ls -lh "$ROOT/dist/ClipStack.exe" | awk '{print "    " $5 "  " $9}'
