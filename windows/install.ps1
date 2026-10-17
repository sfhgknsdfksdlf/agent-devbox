<#
.SYNOPSIS
  agent-devbox one-click bootstrap for Windows (WSL2).

.DESCRIPTION
  Self-elevating bootstrap intended to be run either directly
  (`powershell -File windows\install.ps1`) or piped from the web:

      irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex

  It:
    1. re-launches itself elevated (one UAC prompt);
    2. downloads the latest `agent-devbox-windows.zip` Release asset;
    3. extracts it and runs the WSL preflight (install WSL + mirrored networking);
    4. runs the bundled installer, then always deletes the temp directory.

.NOTES
  Never references $PSScriptRoot/$PSCommandPath as if they are populated under
  `iex` - $PSCommandPath is only used behind an existence guard.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string] $ReleaseTag = 'latest'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Ask which release to install when run interactively without -ReleaseTag.
if (-not $PSBoundParameters.ContainsKey('ReleaseTag') -and [Environment]::UserInteractive) {
  $sel = Read-Host 'Release [Enter = stable (latest), b = beta test build, or a tag e.g. build-20261018.0731]'
  if ([string]::IsNullOrWhiteSpace($sel)) { $ReleaseTag = 'latest' }
  elseif ($sel -match '^(b|beta)$')       { $ReleaseTag = 'beta' }
  else                                    { $ReleaseTag = $sel.Trim() }
}
if ($ReleaseTag -match '^\d{8}\.\d{4}$') { $ReleaseTag = "build-$ReleaseTag" }

$SelfUrl = 'https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1'
$Repo    = 'sfhgknsdfksdlf/agent-devbox'
$ZipUrl  = if ($ReleaseTag -eq 'latest') { "https://github.com/$Repo/releases/latest/download/agent-devbox-windows.zip" } else { "https://github.com/$Repo/releases/download/$ReleaseTag/agent-devbox-windows.zip" }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Scratch dir (cleaned by every path that creates it) -------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-devbox-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- Non-elevated: hand off to an elevated copy of this script --------------
if (-not (Test-IsAdmin)) {
  try {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
      $scriptToRun = $PSCommandPath
    } else {
      # Piped from the web (`irm | iex`) - fetch a real file so it can be elevated.
      $scriptToRun = Join-Path $work 'install.ps1'
      Invoke-WebRequest -Uri $SelfUrl -OutFile $scriptToRun
    }

    Write-Host 'Requesting administrator privileges (one UAC prompt)...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptToRun`"", '-ReleaseTag', $ReleaseTag) -Wait | Out-Null
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
  exit 0
}

# --- Elevated: download, extract, preflight, install ------------------------
try {
  $zipPath = Join-Path $work 'agent-devbox-windows.zip'
  $dest    = Join-Path $work 'win'

  Write-Host 'Downloading agent-devbox-windows.zip (latest release)...'
  Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $dest -Force

  $ensure = Join-Path $dest 'wsl-ensure.ps1'
  if (Test-Path -LiteralPath $ensure) {
    . $ensure
    $r = Ensure-Wsl
    if ($r -eq 'reboot-required') {
      Write-Host 'WSL was installed but Windows needs a reboot. Please reboot and run this script again.'
      return
    }
    if (-not (Test-WslInstalled)) { throw 'WSL is still unavailable; setup did not complete.' }
    Set-MirroredNetworking
  } else {
    Write-Warning 'wsl-ensure.ps1 is not in the archive; skipping the WSL/network preflight.'
  }

  $installer = Join-Path $dest 'install-agent-devbox.ps1'
  if (-not (Test-Path -LiteralPath $installer)) { throw 'install-agent-devbox.ps1 is not in the archive; cannot continue.' }

  Write-Host 'Starting the agent-devbox installer...'
  & $installer -Variant agents -ReleaseTag $ReleaseTag
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
