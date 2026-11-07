@echo off
setlocal
set "EMUDHROLL_BAT=%~f0"
set "EMUDHROLL_OPTION=%~1"
powershell.exe -NoLogo -NoProfile -Command "$parts = [IO.File]::ReadAllText($env:EMUDHROLL_BAT) -split '(?m)^# POWERSHELL\r?$', 2; & ([scriptblock]::Create($parts[1]))"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
# POWERSHELL
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$port = 8080
$ruleName = 'Emudhroll-Proxy-LAN'

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Echec de $([IO.Path]::GetFileName($Executable)) (code $LASTEXITCODE)."
    }
}

function Invoke-FirewallCommand([string]$Command) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $result = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs `
        -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -Wait -PassThru
    if ($result.ExitCode -ne 0) { throw 'La modification du pare-feu a echoue.' }
}

try {
    if ($env:EMUDHROLL_OPTION -eq '--retirer-pare-feu') {
        Invoke-FirewallCommand "Get-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop"
        Write-Host 'Regle de pare-feu Emudhroll retiree.'
        exit 0
    }

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    $build = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' CurrentBuildNumber)
    if ($build -lt 10240 -or ($arch -ne 'AMD64' -and !($arch -eq 'ARM64' -and $build -ge 22000))) {
        throw 'Windows 10/11 x64 ou Windows 11 ARM64 avec emulation x64 requis.'
    }

    if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {
        throw "Le port $port est deja occupe. Fermez le programme qui utilise ce port, puis relancez."
    }

    $appDir = Join-Path $env:LOCALAPPDATA 'EmudhrollProxy'
    $uvVersion = '0.13.7'
    $uvDir = Join-Path $appDir "uv-$uvVersion"
    $uv = Join-Path $uvDir 'uv.exe'
    $revision = '6ba401359e1d415b524adf33eb20f40f1402b931'
    $repo = Join-Path $appDir "Emudhroll-$revision"
    $venv = Join-Path $appDir '.venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null

    if (!(Test-Path -LiteralPath $uv)) {
        Write-Host 'Telechargement du gestionnaire Python uv...'
        $zip = Join-Path $appDir 'uv.zip'
        $asset = 'uv-x86_64-pc-windows-msvc.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/astral-sh/uv/releases/download/$uvVersion/$asset" -OutFile $zip
        $expected = '0cdc5b38fe5a8168ed6a25814f5ba43c21d313dd3187314fccb37b7cec46e021'
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
            throw 'Le fichier uv telecharge ne correspond pas a la somme SHA-256 attendue.'
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $uvDir -Force
        Remove-Item -LiteralPath $zip
    }

    $sourceReady = Join-Path $repo '.extraction-complete'
    if (!(Test-Path -LiteralPath $sourceReady)) {
        Write-Host 'Telechargement de la version Emudhroll du tutoriel...'
        $zip = Join-Path $appDir 'emudhroll.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/SPIRAME/Emudhroll/zip/$revision" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $appDir -Force
        New-Item -ItemType File -Path $sourceReady -Force | Out-Null
        Remove-Item -LiteralPath $zip
    }

    $env:UV_PYTHON_INSTALL_DIR = Join-Path $appDir 'python'
    $env:UV_CACHE_DIR = Join-Path $appDir 'cache'
    if (!(Test-Path -LiteralPath $python)) {
        Write-Host 'Installation de Python 3.13 dans le dossier du proxy...'
        Invoke-Checked $uv @('--no-config', 'venv', '--managed-python', '--python', 'cpython-3.13-windows-x86_64-none', $venv)
    }

    Write-Host 'Verification des dependances du proxy...'
    Invoke-Checked $uv @('--no-config', 'pip', 'install', '--python', $python, '-r', (Join-Path $repo 'requirements.txt'), 'mitmproxy==12.3.1', 'protobuf==7.36.2', 'requests==2.34.2')

    if (!(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
        $answer = Read-Host 'Autoriser le proxy depuis le reseau local dans le pare-feu Windows ? [O/n]'
        if ($answer -eq '' -or $answer -match '^(o|oui|y|yes)$') {
            $pythonBase = & $python -c 'import sys; print(sys._base_executable)'
            if ($LASTEXITCODE -ne 0) { throw 'Impossible de trouver le chemin de Python.' }
            try {
                $command = @"
`$ErrorActionPreference = 'Stop'
if (!(Get-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name '$ruleName' -DisplayName 'Emudhroll - proxy reseau local' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Program '$($pythonBase.Replace("'", "''"))' | Out-Null
}
"@
                Invoke-FirewallCommand $command
            } catch {
                Write-Warning 'Regle non ajoutee. Si Windows demande une autorisation reseau pour Python, acceptez-la sur votre reseau.'
            }
        }
    }

    Write-Host "`nSur le Chromebook, configurez un proxy manuel sur le port $port."
    Write-Host 'Cochez Utiliser le meme proxy pour tous les protocoles.'
    Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
        $alias = $_.InterfaceAlias
        foreach ($address in $_.IPv4Address) {
            if ($address.IPAddress -and $address.IPAddress -notlike '169.254.*') {
                Write-Host "  $alias : $($address.IPAddress):$port"
            }
        }
    }
    Write-Host "Choisissez l'adresse de l'interface reliee au meme reseau que le Chromebook."
    Write-Host "Laissez cette fenetre ouverte. Pour arreter le proxy, faites Ctrl+C.`n"
    $configDir = Join-Path $appDir 'mitmproxy'
    $startProxy = "import runpy, sys; from mitmproxy import options; options.CONF_DIR = sys.argv.pop(1); runpy.run_path('main.py', run_name='__main__')"
    Push-Location -LiteralPath $repo
    try {
        Invoke-Checked $python @('-u', '-c', $startProxy, $configDir, '--port', "$port")
    } finally {
        Pop-Location
    }
    exit 0
} catch {
    Write-Host "`nErreur : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
