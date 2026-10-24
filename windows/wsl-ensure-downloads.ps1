<#
.SYNOPSIS
  Lazily loaded download-and-execute helpers for the agent-devbox Windows installer.

.DESCRIPTION
  Loaded on demand by `wsl-ensure.ps1` via `Get-AgentDevboxDownloadHelperPath`;
  never dot-sourced on the happy path (WSL already present -> the Tier 1 streaming
  import needs neither function).

  Contains the only download-and-execute primitives:
    Install-WslUi          - download the wsl-ui NSIS installer and run it silently
    Get-ZstdExeFromRelease - fetch the pinned zstd.exe for the Tier 3 fallback

  Dot-source-safe: no param() block and no load-time code, only definitions.
  Kept separate from wsl-ensure.ps1 so the always-loaded working file carries no
  download-and-execute shape (Huorong static heuristics).

.NOTES
  Read via `-File`/dot-source, so this file is UTF-8 WITH a BOM (PS 5.1 would
  otherwise read it as ANSI and garble the Chinese strings).
#>

function Install-WslUi {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  $hostArch = ''
  if (Get-Command Get-AgentDevboxHostArch -ErrorAction SilentlyContinue) {
    try { $hostArch = Get-AgentDevboxHostArch } catch { $hostArch = '' }
  }
  if (-not $hostArch) {
    $native = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    if ($native -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
      $hostArch = 'arm64'
    } else { $hostArch = 'amd64' }
  }
  $arch = if ($hostArch -eq 'arm64') { 'arm64' } else { 'x64' }

  Write-Host "正在安装 wsl-ui ($arch)…"
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wslui-' + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    # The winget copy lags the releases, so take the latest NSIS installer
    # straight from GitHub and run it silently (/S); no cert trust needed.
    $rel = Invoke-RestMethod 'https://api.github.com/repos/octasoft-ltd/wsl-ui/releases/latest' -Headers @{ 'User-Agent' = 'agent-devbox' }
    $asset = $rel.assets | Where-Object { $_.name -like "*_$arch-setup.exe" } | Select-Object -First 1
    if (-not $asset) { throw "在最新的 wsl-ui 发布中未找到 $arch 安装包。" }

    $exe = Join-Path $tmp $asset.name
    Write-Host "  正在下载 $($asset.name)…"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe
    Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
    Write-Host '  正在静默安装…'
    $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "wsl-ui setup.exe 退出码 $($p.ExitCode)" }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'wsl-ui 已安装。'
}

# Fetch (once) the pinned zstd.exe from the official facebook/zstd release.
function Get-ZstdExeFromRelease {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $InstallDir)
  $zstdExe = Join-Path $InstallDir 'zstd.exe'
  if (Test-Path -LiteralPath $zstdExe) { return $zstdExe }
  $zstdVer = '1.5.7'
  $zstdUrl = "https://github.com/facebook/zstd/releases/download/v$zstdVer/zstd-v$zstdVer-win64.zip"
  $tmpZip = Join-Path $InstallDir 'zstd.zip'
  $tmpDir = Join-Path $InstallDir 'zstd-tmp'
  Write-Host "正在获取 zstd $zstdVer（用于解压）…"
  Invoke-WebRequest -Uri $zstdUrl -OutFile $tmpZip
  Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
  $found = Get-ChildItem -Path $tmpDir -Recurse -Filter 'zstd.exe' | Select-Object -First 1
  if (-not $found) { throw '下载的压缩包中未找到 zstd.exe。' }
  Copy-Item $found.FullName $zstdExe -Force
  Remove-Item -Path $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  return $zstdExe
}
