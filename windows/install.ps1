<#
.SYNOPSIS
  agent-devbox one-click bootstrap for Windows (WSL2).

.DESCRIPTION
  Self-elevating bootstrap for the `irm | iex` web path:

      irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex

  It:
    1. re-launches itself elevated (one UAC prompt);
    2. downloads the matching `agent-devbox-windows.zip` Release asset;
    3. extracts it and runs the WSL preflight (install WSL + mirrored networking);
    4. runs the bundled installer, then always deletes the temp directory.

  For a local run use the .bat launchers from the Release zip instead.

.NOTES
  ENCODING: this file is deliberately UTF-8 WITHOUT a BOM. `irm` returns the
  body as a string with the BOM surviving as U+FEFF, which makes `iex` fail to
  parse `[CmdletBinding()]` on PowerShell 5.1 (the CI ps-lint step enforces
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

# Beta resolution: `b`/`beta` -> the newest `beta-*` prerelease (same logic in every script).
if ($ReleaseTag -match '^(b|beta)$') {
  $rels = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers @{ 'User-Agent' = 'agent-devbox' }
  $beta = $rels | Where-Object { $_.prerelease -eq $true -and $_.tag_name -like 'beta-*' } | Select-Object -First 1
  if (-not $beta) { throw '未找到 beta 预发布版本。' }
  $ReleaseTag = $beta.tag_name
}
if ($ReleaseTag -match '^\d{8}\.\d{4}$') { $ReleaseTag = "build-$ReleaseTag" }

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
  # The installer writes its full transcript to this log; we echo it into THIS
  # (original) window after the elevated window closes, so the result is visible.
  $log = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-devbox-install-' + [System.IO.Path]::GetRandomFileName() + '.log')
  try {
    $scriptToRun = Join-Path $work 'install.ps1'
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
      $text = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
    } else {
      $text = Invoke-RestMethod -Uri $SelfUrl -Headers @{ 'User-Agent' = 'agent-devbox' }
    }
    # The elevated copy is re-read with `-File`: write it as UTF-8 WITH a BOM so
    # PowerShell 5.1 does not decode its Chinese text as ANSI. install.ps1 ITSELF
    # stays BOM-less for the `irm | iex` path.
    [System.IO.File]::WriteAllText($scriptToRun, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host '正在请求管理员权限（会弹一次 UAC）…'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptToRun`"",
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
        if ($names -notcontains 'agent-devbox') {
          Write-Host "注意：当前（非提权）用户看不到发行版 'agent-devbox'。WSL 发行版按用户注册；若 UAC 用了另一个管理员帐户，发行版会落在那个帐户下。" -ForegroundColor Yellow
        }
      } catch {}
    }
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$log.rc" -Force -ErrorAction SilentlyContinue
  }
  # `return` (not `exit`) so a piped `irm | iex` does not close the caller's shell.
  return
}

# --- Elevated: download, extract, preflight, install ------------------------
try {
  $zipPath = Join-Path $work 'agent-devbox-windows.zip'
  $dest    = Join-Path $work 'win'

  Write-Host '正在下载 agent-devbox-windows.zip…'
  $gotZip = $false
  for ($i = 1; $i -le 4 -and -not $gotZip; $i++) {
    try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop; $gotZip = $true }
    catch { Write-Warning "下载中断，重试 $i/4…"; Start-Sleep -Seconds (3 * $i) }
  }
  if (-not $gotZip) { throw "下载 agent-devbox-windows.zip 失败：$ZipUrl" }
  Write-Host '正在解压安装包…'
  Expand-Archive -Path $zipPath -DestinationPath $dest -Force

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
