<#
.SYNOPSIS
  agent-devbox one-click bootstrap for Windows (WSL2).

.DESCRIPTION
  Self-elevating bootstrap for the raw web entry: the script is fetched and
  executed in memory by the PowerShell host. Prefer `install.cmd` (a local
  bootstrapper) or the Release zip's `.bat` launchers for local runs.

  It:
    1. re-launches itself elevated (one UAC prompt);
    2. fetches the installer scripts (wsl-ensure.ps1, wsl-ensure-downloads.ps1,
       install-agent-devbox.ps1) from the project SOURCE (main), not the Release;
    3. runs the WSL preflight (install WSL + mirrored networking);
    4. runs the installer (which pulls the rootfs from the Release), then always
       deletes its scratch directory.

  For a local run use install.cmd (the recommended bootstrapper) or the .bat
  launchers from the Release zip instead.

.NOTES
  ENCODING: this file is deliberately UTF-8 WITHOUT a BOM. An in-memory fetch
  returns the body as a string with the BOM surviving as U+FEFF, which breaks
  parsing of `[CmdletBinding()]` on PowerShell 5.1 (the CI ps-lint step enforces
  this). The other windows/*.ps1 files ARE BOM-encoded because they are read
  from disk via -File, where PowerShell 5.1 would otherwise decode them as ANSI
  and garble the Chinese text. $PSCommandPath is only used behind a guard.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('agents', 'core')] [string] $Variant = 'agents',
  [string] $ReleaseTag = 'latest',
  [string] $LogPath = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Ask which release to install when run interactively without -ReleaseTag.
if (-not $PSBoundParameters.ContainsKey('ReleaseTag') -and [Environment]::UserInteractive) {
  $sel = Read-Host '选择版本 [回车 = 正式版(latest)，b = beta 测试版，或输入版本号，例如 build-20261018.0731]'
  if ([string]::IsNullOrWhiteSpace($sel)) { $ReleaseTag = 'latest' }
  else                                    { $ReleaseTag = $sel.Trim() }
}

# Ask which image to install when run interactively without -Variant.
if (-not $PSBoundParameters.ContainsKey('Variant') -and [Environment]::UserInteractive) {
  $vsel = Read-Host '选择镜像 [回车 = 完整版（多助手 agents），c = 精简版（core）]'
  if (-not [string]::IsNullOrWhiteSpace($vsel) -and $vsel.Trim() -match '^(?i:c|core)$') { $Variant = 'core' }
  else { $Variant = 'agents' }
}

$SelfUrl = 'https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1'
$Repo    = 'sfhgknsdfksdlf/agent-devbox'
# 发行版名随镜像变体变化（core = agent-devbox-core，agents = agent-devbox）。
$Distro  = if ($Variant -eq 'core') { 'agent-devbox-core' } else { 'agent-devbox' }

# Beta resolution: `b`/`beta` -> the newest `beta-*` prerelease (same logic in every script).
$relApi = "https://api.github.com/repos/$Repo/releases"
$hdr    = @{ 'User-Agent' = 'agent-devbox' }
if ($ReleaseTag -match '^(b|beta)$') {
  $rels = Invoke-RestMethod "${relApi}?per_page=100" -Headers $hdr
  $beta = $rels | Where-Object { $_.prerelease -eq $true -and $_.tag_name -like 'beta-*' } | Select-Object -First 1
  if (-not $beta) { throw '未找到 beta 预发布版本。' }
  $ReleaseTag = $beta.tag_name
}
if ($ReleaseTag -match '^\d{8}\.\d{4}$') { $ReleaseTag = "build-$ReleaseTag" }
# `latest`: prefer the non-prerelease release; if none exists yet, use the newest release.
if ($ReleaseTag -eq 'latest') {
  try { $ReleaseTag = (Invoke-RestMethod "$relApi/latest" -Headers $hdr).tag_name }
  catch {
    $first = @(Invoke-RestMethod "${relApi}?per_page=1" -Headers $hdr | Select-Object -First 1)
    if ($first.Count -ge 1 -and $first[0].tag_name) { $ReleaseTag = $first[0].tag_name }
    else { throw '未找到任何 Release。' }
  }
}

# The installer scripts are fetched from the SOURCE tree (this entry is served
# from `main` too), NOT from the Release zip. The zip is built per-Release and
# lags behind `main`, so fetching scripts from it made every script fix invisible
# until a new Release was cut. The Release is only used for the rootfs parts.
$ScriptsBase = "https://raw.githubusercontent.com/$Repo/main/windows"

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Scratch dir (cleaned by every path that creates it) -------------------
$scratch = Join-Path $env:LOCALAPPDATA 'agent-devbox'
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$work = Join-Path $scratch ('run-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- Non-elevated: hand off to an elevated copy of this script --------------
if (-not (Test-IsAdmin)) {
  # The installer writes its full transcript to this log; we echo it into THIS
  # (original) window after the elevated window closes, so the result is visible.
  $log = Join-Path $scratch ('install-' + [System.IO.Path]::GetRandomFileName() + '.log')
  try {
    $scriptToRun = Join-Path $work 'install.ps1'
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
      $text = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
    } else {
      $text = Invoke-RestMethod -Uri $SelfUrl -Headers @{ 'User-Agent' = 'agent-devbox' }
    }
    # The elevated copy is re-read with `-File`: write it as UTF-8 WITH a BOM so
    # PowerShell 5.1 does not decode its Chinese text as ANSI. install.ps1 ITSELF
    # stays BOM-less for the in-memory web entry.
    [System.IO.File]::WriteAllText($scriptToRun, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host '正在请求管理员权限（会弹一次 UAC）…'
    # The elevated copy is freshly written by us (no Mark-of-the-Web), so
    # RemoteSigned is sufficient and avoids the stronger Bypass signal.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$scriptToRun`"",
      '-ReleaseTag', $ReleaseTag, '-Variant', $Variant, '-LogPath', "`"$log`"")
    $p = $null
    try {
      $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru -ErrorAction Stop
    } catch {
      Write-Host '已取消管理员授权；未做任何更改。' -ForegroundColor Yellow
      return
    }
    if (Test-Path -LiteralPath $log) {
      Write-Host ''
      Write-Host '===== 安装输出 =====' -ForegroundColor Cyan
      Get-Content -LiteralPath $log | Write-Host
      Write-Host '====================' -ForegroundColor Cyan
    }
    $rc = 0
    if (Test-Path -LiteralPath "$log.rc") { $rc = [int](Get-Content -LiteralPath "$log.rc") }
    elseif ($p -and $null -ne $p.ExitCode) { $rc = [int]$p.ExitCode }
    if ($rc -eq 3010) {
      Write-Host 'WSL 已安装，但需要重启 Windows。请重启后重新运行本脚本。' -ForegroundColor Yellow
    } elseif ($rc -ne 0) {
      Write-Host "安装失败（退出码 $rc）。" -ForegroundColor Red
    } else {
      # 从当前（非提权）用户角度确认发行版可见（WSL 发行版按用户注册）。
      try {
        $names = @((& wsl.exe -l -q 2> $null) | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
        if ($names -notcontains $Distro) {
          Write-Host "注意：当前（非提权）用户看不到发行版 '$Distro'。WSL 发行版按用户注册；若 UAC 用了另一个管理员帐户，发行版会落在那个帐户下。" -ForegroundColor Yellow
        }
      } catch {}
    }
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$log.rc" -Force -ErrorAction SilentlyContinue
  }
  # `return` (not `exit`) so an in-memory invocation does not close the caller's shell.
  return
}

# --- Elevated: fetch the installer scripts from SOURCE, preflight, install ---
# Fetch the sibling scripts from the same SOURCE tree as this entry (not the
# Release zip, which lags behind `main`). Byte-for-byte download (-OutFile) so
# each script keeps its encoding/BOM exactly as in the repo.
try {
  $dest = Join-Path $work 'win'
  New-Item -ItemType Directory -Path $dest -Force | Out-Null

  Write-Host '正在获取安装脚本（来自源码 main 分支）…'
  foreach ($name in @('wsl-ensure.ps1', 'wsl-ensure-downloads.ps1', 'install-agent-devbox.ps1', 'mount-datadisk.ps1', 'mount-datadisk.cmd', 'unmount-datadisk.ps1', 'unmount-datadisk.cmd')) {
    $url = "$ScriptsBase/$name"
    $out = Join-Path $dest $name
    $got = $false
    for ($i = 1; $i -le 4 -and -not $got; $i++) {
      try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop; $got = $true }
      catch { Write-Warning "获取 $name 中断，重试 $i/4…"; Start-Sleep -Seconds (3 * $i) }
    }
    if (-not $got) { throw "获取安装脚本失败：$url" }
  }

  $ensure = Join-Path $dest 'wsl-ensure.ps1'
  if (Test-Path -LiteralPath $ensure) {
    . $ensure
    $r = Ensure-Wsl
    if ($r -eq 'reboot-required') {
      Write-Host 'WSL 已安装，但需要重启 Windows。请重启后重新运行本脚本。'
      if ($LogPath) { try { [System.IO.File]::WriteAllText("$LogPath.rc", '3010') } catch {} }
      return
    }
    if (-not (Test-WslInstalled)) { throw 'WSL 仍不可用；安装未能完成。' }
    Set-MirroredNetworking
  } else {
    Write-Warning '压缩包中缺少 wsl-ensure.ps1；跳过 WSL / 网络预检查。'
  }

  $installer = Join-Path $dest 'install-agent-devbox.ps1'
  if (-not (Test-Path -LiteralPath $installer)) { throw '压缩包中缺少 install-agent-devbox.ps1；无法继续。' }

  Write-Host '正在启动 agent-devbox 安装器…'
  $installerArgs = @{ Variant = $Variant; ReleaseTag = $ReleaseTag }
  if ($LogPath) { $installerArgs['LogPath'] = $LogPath }
  & $installer @installerArgs
} catch {
  # A failure BEFORE the installer runs (download/expand/preflight) never writes
  # the .rc, which would look like success to the parent. Record it here.
  Write-Host $_ -ForegroundColor Red
  if ($LogPath) { try { [System.IO.File]::WriteAllText("$LogPath.rc", '1') } catch {} }
  throw
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
