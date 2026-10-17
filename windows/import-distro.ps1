<#
.SYNOPSIS
  Docker-free import path: reassemble the released rootfs parts and run
  `wsl --import` only. It does NOT create or attach a data disk.

  Use this if you want to manage the VHDX yourself, or if you already ran the
  main installer and only need the distro imported. For the full experience use
  install-agent-devbox.ps1 (or the .bat launchers).
#>
[CmdletBinding()]
param(
  [ValidateSet('agents', 'core')] [string] $Variant = 'agents',
  [string] $Distro = 'agent-devbox',
  [string] $InstallDir = 'D:\WSL\agent-devbox',
  [string] $Repo = 'sfhgknsdfksdlf/agent-devbox'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$stzName = "rootfs-$Variant-amd64.tar.zst"
$stz = Join-Path $InstallDir $stzName
$tar = Join-Path $InstallDir "rootfs-$Variant-amd64.tar"

$rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'agent-devbox-import' }
$parts = $rel.assets | Where-Object { $_.name -like "$stzName.part-*" } | Sort-Object name
if (-not $parts) { throw "No '$stzName.part-*' assets in the latest release of $Repo." }

$local = @()
foreach ($p in $parts) {
  $dest = Join-Path $InstallDir $p.name
  Write-Host "Downloading $($p.name)"
  Invoke-WebRequest -Uri $p.browser_download_url -OutFile $dest
  $local += $dest
}

Write-Host 'Reassembling...'
$joined = ($local -join '+')
cmd /c "copy /b `"$($joined -replace '\+','"+'`"`" `"$stz`" >nul" | Out-Null

# Windows 10 has no built-in zstd, so use the zstd.exe shipped with the Release.
$zstdExe = Join-Path $InstallDir 'zstd.exe'
if (-not (Test-Path $zstdExe)) {
  $z = $rel.assets | Where-Object { $_.name -eq 'zstd.exe' } | Select-Object -First 1
  if (-not $z) { throw "No 'zstd.exe' asset in the latest release of $Repo." }
  Invoke-WebRequest -Uri $z.browser_download_url -OutFile $zstdExe
}

Write-Host 'Decompressing (zstd)...'
& $zstdExe -d -f $stz
if ($LASTEXITCODE -ne 0) { throw "zstd decompress failed ($LASTEXITCODE)" }

Write-Host "Importing distro '$Distro'..."
wsl.exe --import $Distro $InstallDir $tar
Write-Host "Done. Note: this path does NOT set up the persistent data disk."
