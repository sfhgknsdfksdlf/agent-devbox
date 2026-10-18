<#
.SYNOPSIS
  Docker-free import path: reassemble the released rootfs parts and run
  `wsl --import` only. It does NOT create or attach a data disk.

  Use this if you want to manage the VHDX yourself, or if you already ran the
  main installer and only need the distro imported. For the full experience use
  install-agent-devbox.ps1 (or the .bat launchers).

  Import is tiered: stream the parts into `wsl --import -` first, then merge +
  import by file, then (last resort) decompress to .tar with zstd.exe.
#>
[CmdletBinding()]
param(
  [ValidateSet('agents', 'core')] [string] $Variant = 'agents',
  [string] $Distro = '',
  [string] $InstallDir = '',
  [string] $ReleaseTag = 'latest',
  [string] $Repo = 'sfhgknsdfksdlf/agent-devbox'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$env:WSL_UTF8 = '1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Shared helpers (disk check / streaming import / zstd fallback).
$__ensure = Join-Path $PSScriptRoot 'wsl-ensure.ps1'
if (-not (Test-Path -LiteralPath $__ensure)) { throw '缺少 wsl-ensure.ps1；请从 Release 压缩包中完整解压所有脚本。' }
. $__ensure

# 变体 -> 发行版名/安装目录 的默认映射；显式传入的 -Distro/-InstallDir 仍然优先。
$distroMap = @{
  agents = [pscustomobject]@{ Distro = 'agent-devbox';      InstallDir = 'D:\WSL\agent-devbox' }
  core   = [pscustomobject]@{ Distro = 'agent-devbox-core'; InstallDir = 'D:\WSL\agent-devbox-core' }
}
if (-not $Distro)     { $Distro     = $distroMap[$Variant].Distro }
if (-not $InstallDir) { $InstallDir = $distroMap[$Variant].InstallDir }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Beta resolution: `b`/`beta` -> the newest `beta-*` prerelease.
$ReleaseTag = Normalize-ReleaseTag $ReleaseTag
$hdr = @{ 'User-Agent' = 'agent-devbox-import' }
$relBase = "https://api.github.com/repos/$Repo/releases"
if ($ReleaseTag -eq 'beta') {
  $rels = Invoke-RestMethod "${relBase}?per_page=100" -Headers $hdr
  $beta = $rels | Where-Object { $_.prerelease -eq $true -and $_.tag_name -like 'beta-*' } | Select-Object -First 1
  if (-not $beta) { throw '未找到 beta 预发布版本。' }
  $ReleaseTag = $beta.tag_name
}
if ($ReleaseTag -eq 'latest') {
  # 优先正式 Release；若当前只有预发布（beta）Release，则退回最新的一个。
  try { $ReleaseTag = (Invoke-RestMethod "$relBase/latest" -Headers $hdr).tag_name }
  catch {
    $first = @(Invoke-RestMethod "${relBase}?per_page=1" -Headers $hdr | Select-Object -First 1)
    if ($first.Count -ge 1 -and $first[0].tag_name) { $ReleaseTag = $first[0].tag_name }
    else { throw '未找到任何 Release。' }
  }
}

$stzName = "rootfs-$Variant-amd64.tar.zst"
$stz = Join-Path $InstallDir $stzName
$tar = Join-Path $InstallDir "rootfs-$Variant-amd64.tar"

$relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
$rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-import' }
$parts = @($rel.assets | Where-Object { $_.name -like "$stzName.part-*" } | Sort-Object name)
if ($parts.Count -eq 0) { throw "在 $Repo 的 '$ReleaseTag' 发布中未找到 '$stzName.part-*' 资源。" }

# --- 磁盘预检（下载前）----------------------------------------------------
$compressed = [long](($parts | Measure-Object -Property size -Sum).Sum)
$uncomp = [long](Get-ZstdUncompressedSizeFromUrl $parts[0].browser_download_url)
if ($uncomp -le 0) { $uncomp = 0 }
Assert-DiskSpace -Path $InstallDir -RequiredBytes (Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Stream')

$local = @()
foreach ($p in $parts) {
  $dest = Join-Path $InstallDir $p.name
  if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq [long]$p.size)) {
    Write-Host "已存在且完整，跳过：$($p.name)"
  } else {
    Write-Host "正在下载 $($p.name)…"
    Save-Download -Url $p.browser_download_url -Dest $dest
  }
  $local += $dest
}

$imported = $false
try {
  # Tier 1: stream the parts straight into `wsl --import -`.
  Write-Host '正在流式导入（Tier 1）…'
  try {
    $code = Invoke-WslImportStream -Parts @($local) -Distro $Distro -InstallDir $InstallDir
    if ($code -eq 0) { $imported = $true } else { Write-Warning "流式导入返回 $code。" }
  } catch { Write-Warning "流式导入异常：$($_.Exception.Message)" }
  if (-not $imported) { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null }

  # Tier 2: merge the parts, then import the .tar.zst by file path.
  if (-not $imported) {
    Write-Warning '回退 Tier 2：合并分片后按文件导入。'
    Assert-DiskSpace -Path $InstallDir -RequiredBytes (Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Merge')
    Join-Parts -Parts @($local) -Dest $stz
    Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $stz) | Out-Null
    if ($script:NativeExit -eq 0) { $imported = $true } else { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null }
  }

  # Tier 3: last resort - decompress with zstd.exe to .tar, then import.
  if (-not $imported) {
    Write-Warning '回退 Tier 3：解压为 .tar 再导入。'
    Assert-DiskSpace -Path $InstallDir -RequiredBytes (Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Legacy')
    $zstdExe = Get-ZstdExe -InstallDir $InstallDir
    Join-Parts -Parts @($local) -Dest $stz
    Invoke-Native $zstdExe @('-d', '-f', '-o', $tar, $stz) | Out-Null
    if ($script:NativeExit -ne 0) { throw "zstd 解压失败（$script:NativeExit）" }
    Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $tar) | Out-Null
    if ($script:NativeExit -ne 0) { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null; throw "wsl --import 失败（$script:NativeExit）" }
    $imported = $true
  }
} finally {
  # 成功或失败都清理下载的分片与中间文件。
  Remove-Item -LiteralPath $stz -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
  foreach ($lp in $local) { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue }
}

# Verify the registration (import-only -> no boot, so no MAINTENANCE MOTD).
Assert-DistroReady -Distro $Distro -InstallDir $InstallDir -NoLaunch -UnregisterOnFail
Write-Host '完成（此方式不配置持久化数据盘）。'
