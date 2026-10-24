<#
    Installs ClipStack for Windows with nothing to click through. Paste this
    into PowerShell, or into the Run box (Win+R) with "powershell -c" in front:

        irm https://raw.githubusercontent.com/Punnawit9285/ClipStack/main/windows/install.ps1 | iex

    It downloads ClipStack.exe from the latest release and runs it, and the exe
    installs itself just as when you double-click a download: per user, no
    admin rights, started with Windows. What PowerShell downloads isn't marked
    as coming from the internet, so neither the browser nor SmartScreen asks.
#>

& {   # a script block, so nothing here lingers in your PowerShell session
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell's progress bar slows downloads to a crawl
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $url = 'https://github.com/Punnawit9285/ClipStack/releases/latest/download/ClipStack.exe'
    $setup = Join-Path $env:TEMP 'ClipStack-setup.exe'
    Write-Host 'Downloading ClipStack...'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $setup

    # The exe copies itself into place, starts that copy and exits. (Start-Process
    # -Wait would wait for the copy it starts too, which keeps running.)
    $p = Start-Process -FilePath $setup -PassThru
    if ($p.WaitForExit(30000)) { Remove-Item $setup -ErrorAction SilentlyContinue }
    Write-Host 'ClipStack is installed. Press Ctrl+Shift+V to open your clipboard history.'
}
