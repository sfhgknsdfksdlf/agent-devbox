<#
.SYNOPSIS
  Shared WSL preflight helpers for the agent-devbox Windows installers.

.DESCRIPTION
  Dot-source-safe: this file has NO param() block and runs NO code on load, so
  `. .\wsl-ensure.ps1` defines the functions without any side effects.

  Exposes:
    Test-WslInstalled    - is a functional WSL present? (no interactive block)
    Ensure-Wsl           - install WSL if missing (asks base-only vs base+wsl-ui)
    Install-WslUi        - install the wsl-ui GUI from its latest GitHub release
    Get-WslNetworkingMode- read the active networking mode
    Set-MirroredNetworking - switch .wslconfig [wsl2] networkingMode=mirrored

.NOTES
  Detection uses `wsl.exe --status` (fast, non-interactive). NEVER `wsl --version`
  (it blocks interactively when WSL is missing) and never `Get-Command wsl`
  (the System32 stub always exists even when WSL is not installed).
#>

function Test-WslInstalled {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  # UTF-8 output so we can parse wsl.exe reliably (avoids UTF-16).
  $env:WSL_UTF8 = '1'
  try {
    wsl.exe --status *> $null 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Ensure-Wsl {
  [CmdletBinding()]
  param([switch] $Yes)

  $ErrorActionPreference = 'Stop'

  # Idempotent: WSL already present -> do nothing, let the caller continue.
  if (Test-WslInstalled) { return 'ok' }

  # WSL is missing: base WSL only, or base WSL + the wsl-ui desktop GUI (default).
  $withUi = $true
  if (-not $Yes) {
    $sel = Read-Host 'WSL is not installed. Install [1] base WSL only, or [2] base WSL + wsl-ui GUI? [Enter = 2]'
    $withUi = -not ($sel -match '^\s*1\s*$')
  }

  Write-Host 'Installing WSL (a console window may appear, please wait)...'
  # NOTE: deliberately NO -NoNewWindow: wsl --install needs an interactive console.
  $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Wait -PassThru

  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1641) {
    throw "wsl --install failed (exit $($p.ExitCode))"
  }

  # wsl-ui only needs installing (not a booted WSL), so install it even when a
  # reboot is still pending; a failure here must not abort the whole install.
  if ($withUi) {
    try {
      Install-WslUi
    } catch {
      Write-Warning "wsl-ui was not installed: $($_.Exception.Message)"
      Write-Warning 'You can install it later from https://github.com/octasoft-ltd/wsl-ui/releases'
    }
  }

  if ($p.ExitCode -ne 0) {
    Write-Host 'A reboot is required. Please restart Windows and run again.'
    return 'reboot-required'
  }
  return 'ok'
}

function Install-WslUi {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

  Write-Host "Installing wsl-ui ($arch)..."
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wslui-' + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    # The winget copy lags the releases, so take the latest NSIS installer
    # straight from GitHub and run it silently (/S); no cert trust needed.
    $rel = Invoke-RestMethod 'https://api.github.com/repos/octasoft-ltd/wsl-ui/releases/latest' -Headers @{ 'User-Agent' = 'agent-devbox' }
    $asset = $rel.assets | Where-Object { $_.name -like "*_$arch-setup.exe" } | Select-Object -First 1
    if (-not $asset) { throw "no $arch installer found in the latest wsl-ui release." }

    $exe = Join-Path $tmp $asset.name
    Write-Host "  downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe
    Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
    Write-Host '  running the silent installer...'
    $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "wsl-ui setup.exe exited $($p.ExitCode)" }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'wsl-ui installed.'
}

function Get-WslNetworkingMode {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  $env:WSL_UTF8 = '1'
  try {
    $mode = (wsl.exe -e wslinfo --networking-mode 2> $null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mode)) { return 'unknown' }
    return $mode
  } catch {
    return 'unknown'
  }
}

function Set-MirroredNetworking {
  [CmdletBinding()]
  param([switch] $Yes)

  $ErrorActionPreference = 'Stop'

  $cfg = Join-Path $env:USERPROFILE '.wslconfig'

  # Already mirrored? Trust the live mode when a distro exists, else the config
  # file (wslinfo needs a distro, and right after installing WSL there is none).
  $mirrored = $false
  if ((Get-WslNetworkingMode) -eq 'mirrored') {
    $mirrored = $true
  } elseif (Test-Path -LiteralPath $cfg) {
    $inWsl2 = $false
    foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
      $t = $line.Trim()
      if ($t -match '^\[(.+)\]$') { $inWsl2 = ($Matches[1] -ieq 'wsl2') }
      elseif ($inWsl2 -and $t -match '^networkingMode\s*=\s*mirrored\s*$') { $mirrored = $true; break }
    }
  }
  if ($mirrored) {
    Write-Host 'Mirrored networking is already enabled.'
    return
  }

  if (-not $Yes) {
    $ans = Read-Host 'Recommended: switch to mirrored networking (better for VPN / phone access). Switch now? [Y/n] (Enter = yes):'
    if ($ans -match '^(n|no)$') {
      Write-Host 'Skipped.'
      return
    }
  }

  # Back up once (never overwrite an existing backup).
  if (Test-Path -LiteralPath $cfg) {
    $bak = "$cfg.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
      Copy-Item -LiteralPath $cfg -Destination $bak -Force
    }
  }

  $lines = @()
  if (Test-Path -LiteralPath $cfg) {
    $lines = @([System.IO.File]::ReadAllLines($cfg))
  }

  # Locate the [wsl2] section (case-insensitive), if any.
  $secStart = -1
  $secEnd = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -match '^\[wsl2\]$') {
      $secStart = $i
      for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j].Trim() -match '^\[') { $secEnd = $j; break }
      }
      break
    }
  }

  $out = New-Object System.Collections.Generic.List[string]
  $out.AddRange([string[]]$lines)

  if ($secStart -lt 0) {
    # No [wsl2] section: append one.
    if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
    $out.Add('[wsl2]')
    $out.Add('networkingMode=mirrored')
  } else {
    # Find an existing networkingMode= key inside [wsl2].
    $keyIdx = -1
    for ($k = $secStart + 1; $k -lt $secEnd; $k++) {
      if ($out[$k].Trim() -match '^networkingMode\s*=') { $keyIdx = $k; break }
    }
    if ($keyIdx -ge 0) {
      $out[$keyIdx] = 'networkingMode=mirrored'
    } else {
      $out.Insert($secEnd, 'networkingMode=mirrored')
    }
  }

  # UTF-8 without BOM; one line per element (preserves every other line's content).
  [System.IO.File]::WriteAllLines($cfg, $out, (New-Object System.Text.UTF8Encoding($false)))

  wsl.exe --shutdown | Out-Null
  Write-Host 'Switched to mirrored networking (ran wsl --shutdown). If you use a VPN, make sure the VPN allows local network access.'
}
