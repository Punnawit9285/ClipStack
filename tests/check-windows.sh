#!/bin/bash
# Static checks for the Windows version that run on any OS:
#   - windows/ClipStack.ps1 parses (needs pwsh)
#   - it is pure ASCII, since Windows PowerShell 5.1 reads BOM-less scripts as ANSI
#   - its C# compiles as C# 5 against .NET Framework 4.8 (needs the dotnet SDK)
# Set PWSH / DOTNET to point at binaries that aren't on PATH.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS1="$ROOT/windows/ClipStack.ps1"
PWSH="${PWSH:-$(command -v pwsh || true)}"
DOTNET="${DOTNET:-$(command -v dotnet || true)}"
FAIL=0

if perl -ne 'print "  $.: $_" if /[^\x00-\x7F]/' "$PS1" | grep .; then
    echo "  FAIL  ClipStack.ps1 has non-ASCII characters (above)"; FAIL=1
else echo "  ok    ClipStack.ps1 is pure ASCII"; fi

if [ -n "$PWSH" ]; then
    for f in "$PS1"; do
        errs="$("$PWSH" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$f',[ref]\$null,[ref]\$e); \$e | % { \$_.ToString() }")"
        if [ -z "$errs" ]; then echo "  ok    $(basename "$f") parses"; else echo "  FAIL  $(basename "$f"): $errs"; FAIL=1; fi
    done
else echo "  skip  PowerShell parse (no pwsh)"; fi

if [ -n "$DOTNET" ]; then
    WORK="$(mktemp -d -t clipstack-wincheck)"
    trap 'rm -rf "$WORK"' EXIT
    cp "$ROOT/tests/windows/ClipStackCheck.csproj" "$WORK/"
    awk "/^\\\$source = @'/{f=1;next} /^'@/{f=0} f" "$PS1" > "$WORK/ClipStack.cs"
    if out="$(DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build -nologo -v q "$WORK/ClipStackCheck.csproj" 2>&1)"; then
        echo "  ok    C# compiles (C# 5, .NET Framework 4.8, warnings as errors)"
    else
        echo "  FAIL  C# does not compile:"; echo "$out" | grep -E "error|warning" | sort -u; FAIL=1
    fi
else echo "  skip  C# compile (no dotnet SDK)"; fi

exit $FAIL
