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
  [string] $ReleaseTag = 'latest',
  [string] $Repo = 'sfhgknsdfksdlf/agent-devbox'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if ($ReleaseTag -match '^\d{8}\.\d{4}$') { $ReleaseTag = "build-$ReleaseTag" }

function Join-Parts {
  param([string[]] $Parts, [string] $Dest)
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
  $out = [System.IO.File]::Create($Dest)
  try {
    foreach ($p in $Parts) {
      $in = [System.IO.File]::OpenRead($p)
      try { $in.CopyTo($out) } finally { $in.Dispose() }
    }
  } finally { $out.Dispose() }
}

$stzName = "rootfs-$Variant-amd64.tar.zst"
$stz = Join-Path $InstallDir $stzName
$tar = Join-Path $InstallDir "rootfs-$Variant-amd64.tar"

$relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
$rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-import' }
$parts = $rel.assets | Where-Object { $_.name -like "$stzName.part-*" } | Sort-Object name
if (-not $parts) { throw "No '$stzName.part-*' assets in the '$ReleaseTag' release of $Repo." }

$local = @()
foreach ($p in $parts) {
  $dest = Join-Path $InstallDir $p.name
  Write-Host "Downloading $($p.name)"
  Invoke-WebRequest -Uri $p.browser_download_url -OutFile $dest
  $local += $dest
}

Write-Host 'Reassembling...'
Join-Parts -Parts $local -Dest $stz

# Windows 10 has no built-in zstd, so fetch a PINNED zstd.exe from the official project.
$zstdExe = Join-Path $InstallDir 'zstd.exe'
if (-not (Test-Path $zstdExe)) {
  $zstdVer = '1.5.7'
  $zstdUrl = "https://github.com/facebook/zstd/releases/download/v$zstdVer/zstd-v$zstdVer-win64.zip"
  $tmpZip = Join-Path $InstallDir 'zstd.zip'
  $tmpDir = Join-Path $InstallDir 'zstd-tmp'
  Write-Host "Fetching zstd $zstdVer (needed to decompress)..."
  Invoke-WebRequest -Uri $zstdUrl -OutFile $tmpZip
  Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
  $found = Get-ChildItem -Path $tmpDir -Recurse -Filter 'zstd.exe' | Select-Object -First 1
  if (-not $found) { throw 'zstd.exe not found in the downloaded archive.' }
  Copy-Item $found.FullName $zstdExe -Force
  Remove-Item -Path $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Decompressing (zstd)...'
& $zstdExe -d -f $stz
if ($LASTEXITCODE -ne 0) { throw "zstd decompress failed ($LASTEXITCODE)" }

Write-Host "Importing distro '$Distro'..."
wsl.exe --import $Distro $InstallDir $tar
Write-Host "Done. Note: this path does NOT set up the persistent data disk."
