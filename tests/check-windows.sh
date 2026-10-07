#!/bin/bash
# Static checks for the Windows version that run on any OS:
#   - windows/ClipStack.ps1 parses (needs pwsh)
#   - it is pure ASCII, since Windows PowerShell 5.1 reads BOM-less scripts as ANSI
#   - its C# compiles as C# 5 against .NET Framework 4.8, its history logic passes
#     unit tests, and ClipStack.exe builds (all need the dotnet SDK)
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

    # The history, image and queue logic, run for real (it needs no Windows APIs).
    mkdir -p "$WORK/unit"
    cp "$ROOT/tests/windows/StoreTests.csproj" "$ROOT/tests/windows/StoreTests.cs" "$WORK/unit/"
    { printf 'using System;\nusing System.Collections.Generic;\nusing System.IO;\nusing System.Linq;\n'
      printf 'using System.Security.Cryptography;\nusing System.Text;\nnamespace ClipStack {\n'
      awk '/^public class Clip \{/{f=1} /^public static class Recorder/{f=0} f' "$WORK/ClipStack.cs" | grep -v '^///'
      printf '}\n'; } > "$WORK/unit/Store.cs"
    if out="$(DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" run --project "$WORK/unit/StoreTests.csproj" 2>&1)"; then
        echo "$out" | grep -E "^  (ok|FAIL)" | sed 's/^/  /'
        echo "  ok    unit tests: $(echo "$out" | tail -1)"
    else
        echo "$out" | grep -E "FAIL|expected|got:|error" | sed 's/^/  /'
        echo "  FAIL  unit tests: $(echo "$out" | tail -1)"; FAIL=1
    fi

    # ClipStack.exe: the same C# plus its installer entry point (windows/app/).
    if out="$(DOTNET="$DOTNET" "$ROOT/windows/build-exe.sh" 2>&1)" && [ -f "$ROOT/dist/ClipStack.exe" ]; then
        echo "  ok    ClipStack.exe builds ($(echo "$out" | awk '{print $1}' | tail -1))"
    else
        echo "  FAIL  ClipStack.exe does not build:"; echo "$out" | grep -E "error|warning" | sort -u; FAIL=1
    fi
else echo "  skip  C# compile, unit tests and ClipStack.exe (no dotnet SDK)"; fi

exit $FAIL
