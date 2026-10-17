<#
.SYNOPSIS
  agent-devbox Windows 一键安装脚本（WSL2）。

.DESCRIPTION
  - 把发布好的镜像导入为名为 `agent-devbox` 的 WSL2 发行版。
  - 创建并挂载一块 32GB 动态 VHDX 数据磁盘并初始化。
  - 把数据磁盘接入发行版，使 /home、/root、/workspace 在镜像升级后依然保留。
  - 始终注册一个登录时自动重新挂载数据磁盘的计划任务（可用 -NoTask 跳过）。

  幂等：可重复运行；只创建缺失的部分（发行版 / 数据磁盘），并刷新启动配置；
  已存在的数据磁盘永远不会被重新格式化。

  导入采用三级回退：优先把下载的分片直接流式喂给 `wsl --import -`（不解压出
  中间文件），失败再合并后按文件导入，最后才用 zstd.exe 解压为 .tar 导入。

  交互 shell 用户是 root；paseo 后台服务以非 root 的 `paseo` 用户运行。

.NOTES
  需要 Windows 11（WSL2，支持 `wsl --mount --vhd`）。仅提权一次（UAC）。
  提权到新管理员窗口时，会把该窗口的输出写入 -LogPath，并在原窗口回显。
#>
[CmdletBinding()]
param(
  [ValidateSet('agents', 'core')] [string] $Variant = 'agents',
  [string] $InstallDir = '',
  [string] $ReleaseTag = '',
  [switch] $Yes,
  [switch] $Reinstall,
  [switch] $NoTask,
  [string] $LogPath = ''
)

# --- 控制台 UTF-8（尽力而为，失败也不影响运行）------------------------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$env:WSL_UTF8 = '1'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Distro   = 'agent-devbox'
$DiskName = 'agent-devbox-data'
$VhdxName = 'data.vhdx'
$Repo     = 'sfhgknsdfksdlf/agent-devbox'
$ConfPath = '/etc/agent-devbox.conf'
$TaskName = 'agent-devbox-mount-datadisk'

# --- 输出辅助：统一的进度 / 提示样式 ----------------------------------------
function Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host $m -ForegroundColor Green }
function Warn([string]$m) { Write-Host $m -ForegroundColor Yellow }
function Err([string]$m)  { Write-Host $m -ForegroundColor Red }

# Shared helpers live in wsl-ensure.ps1 (Invoke-Native, Quote-NativeArg, disk
# math, streaming import, distro verification). Dot-source early so EVERY code
# path can use them, including the non-admin parent that only waits and relays.
$__ensure = Join-Path $PSScriptRoot 'wsl-ensure.ps1'
$__haveEnsure = Test-Path -LiteralPath $__ensure
if ($__haveEnsure) { . $__ensure }

# Wrap a value in single quotes for safe embedding in the sourced bash config.
function Quote-Bash([string] $Value) { "'" + $Value.Replace("'", "'\''") + "'" }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslDistros { Invoke-Native 'wsl.exe' @('-l', '-q') | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
function Test-DistroExists { (Get-WslDistros) -contains $Distro }

# 解析版本选择：beta -> 最近的 beta-* 预发布；裸 YYYYMMDD.HHMM -> build-*；其余原样。
function Resolve-ReleaseTag {
  param([string] $Sel)
  $sel = Normalize-ReleaseTag $Sel
  if ($sel -eq 'beta') {
    $api  = "https://api.github.com/repos/$Repo/releases?per_page=100"
    $rels = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'agent-devbox-installer' }
    $beta = $rels | Where-Object { $_.prerelease -eq $true -and $_.tag_name -like 'beta-*' } | Select-Object -First 1
    if (-not $beta) { throw '未找到 beta 预发布版本。' }
    return $beta.tag_name
  }
  return $sel
}

# --- 变体选择（精简版 core / 完整版 agents）：仅未显式指定且交互时询问 ------
if (-not $PSBoundParameters.ContainsKey('Variant') -and -not $Yes -and [Environment]::UserInteractive) {
  $vsel = Read-Host '选择镜像 [回车 = 完整版（多助手 agents），c = 精简版（core）]'
  if (-not [string]::IsNullOrWhiteSpace($vsel) -and $vsel.Trim() -match '^(?i:c|core)$') { $Variant = 'core' }
  else { $Variant = 'agents' }
}

# --- 提权一次（UAC）：提权子进程写日志，原窗口等待后回显整份日志 ------------
if (-not (Test-Admin)) {
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Variant', $Variant)
  if ($InstallDir) { $argv += @('-InstallDir', "`"$InstallDir`"") }
  if ($ReleaseTag) { $argv += @('-ReleaseTag', $ReleaseTag) }
  if ($Yes)        { $argv += '-Yes' }
  if ($Reinstall)  { $argv += '-Reinstall' }
  if ($NoTask)     { $argv += '-NoTask' }

  $parentLog = if ($LogPath) { $LogPath } else { Join-Path ([System.IO.Path]::GetTempPath()) ("agent-devbox-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  $argv += @('-LogPath', "`"$parentLog`"")
  Write-Host '正在请求管理员权限（会弹出一次 UAC 授权提示）…'
  $p = $null
  try {
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv -Wait -PassThru -ErrorAction Stop
  } catch {
    Warn '已取消管理员授权；未做任何更改。'
    exit 2
  }
  try {
    # 把提权窗口的整份输出回显到当前（原）窗口，避免“结果无处可见”。
    if (Test-Path -LiteralPath $parentLog) {
      Write-Host ''
      Write-Host '===== 管理员会话输出 =====' -ForegroundColor Cyan
      Get-Content -LiteralPath $parentLog | Write-Host
      Write-Host '==========================' -ForegroundColor Cyan
    }
    $rc = 0
    $rcPath = "$parentLog.rc"
    if (Test-Path -LiteralPath $rcPath) { $rc = [int](Get-Content -LiteralPath $rcPath) }
    elseif ($p -and $null -ne $p.ExitCode) { $rc = [int]$p.ExitCode }
    if ($rc -eq 3010) { Warn 'WSL 已安装完成；请重启 Windows 后再次运行本安装脚本。'; exit 0 }
    if ($rc -ne 0) { Err "安装失败（退出码 $rc）。"; exit $rc }
    # 从“当前（非提权）用户”角度确认发行版可见——WSL 发行版按用户注册。
    try {
      $names = @(Invoke-Native 'wsl.exe' @('-l', '-q') | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
      if ($names -notcontains $Distro) {
        Warn "注意：当前（非提权）用户看不到发行版 '$Distro'。WSL 发行版按用户注册；若 UAC 用了另一个管理员帐户，发行版会落在那个帐户下。请用安装时的同一帐户，或在管理员帐户下运行 wsl -l -v 检查。"
      }
    } catch {}
    Ok '安装完成。进入环境：wsl -d agent-devbox'
    exit 0
  } finally {
    Remove-Item -LiteralPath $parentLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$parentLog.rc" -Force -ErrorAction SilentlyContinue
  }
}

# --- 提权后的主流程：把输出同时写进 -LogPath（供原窗口回显）---------------
$script:Logging = -not [string]::IsNullOrWhiteSpace($LogPath)
$script:RcPath  = if ($script:Logging) { "$LogPath.rc" } else { '' }
# Trap must sit at script scope (not inside an if-block) so it guards the whole
# flow: on any terminating error, mark the result file and flush the transcript.
trap {
  try { Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red } catch {}
  try { Write-Host ($_ | Out-String) } catch {}
  if ($script:Logging) {
    try { [System.IO.File]::WriteAllText($script:RcPath, '1') } catch {}
    try { Stop-Transcript | Out-Null } catch {}
  }
  exit 1
}
if ($script:Logging) {
  Start-Transcript -Path $LogPath -Force | Out-Null
}

# --- [1/10] 检查运行环境 ----------------------------------------------------
Step '[1/10] 检查运行环境…'
# 预检查：确保 WSL 存在，并（建议）启用镜像网络（helpers 已在顶部 dot-source）。
if ($__haveEnsure) {
  $__r = Ensure-Wsl -Yes:$Yes
  if ($__r -eq 'reboot-required') {
    Write-Host 'WSL 已安装完成；请重启 Windows 后再次运行本安装脚本。'
    if ($script:Logging) { try { [System.IO.File]::WriteAllText($script:RcPath, '3010') } catch {}; try { Stop-Transcript | Out-Null } catch {} }
    exit 0
  }
  if (-not (Test-WslInstalled)) { throw 'WSL 仍不可用，环境配置未完成。' }
  Set-MirroredNetworking -Yes:$Yes
} else {
  Write-Warning '未找到 wsl-ensure.ps1；已跳过 WSL/网络预检查（请从 Release 压缩包中完整解压所有脚本）。'
}

# --- 决定安装目录 -----------------------------------------------------------
if (-not $InstallDir) {
  $default = 'D:\WSL\agent-devbox'
  if ($Yes) {
    $InstallDir = $default
  } else {
    $answer = Read-Host "安装目录 [$default]（直接回车使用默认值）"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer }
  }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$VhdxPath = Join-Path $InstallDir $VhdxName
Write-Host "发行版=$Distro  变体=$Variant  安装目录=$InstallDir"

# --- 版本通道：正式版（latest）、滚动 beta 测试版，或指定版本号 ------------
if (-not $ReleaseTag) {
  if ($Yes) {
    $ReleaseTag = 'latest'
  } else {
    $sel = Read-Host '选择版本 [回车 = 正式版(latest)，b = beta 测试版，或输入版本号，例如 build-20261018.0731 / beta-20261018.0731]'
    $ReleaseTag = if ([string]::IsNullOrWhiteSpace($sel)) { 'latest' } else { $sel.Trim() }
  }
}
$ReleaseTag = Resolve-ReleaseTag $ReleaseTag

# --- 是否重装已存在的发行版？（回车 = 重装；数据盘独立，/home 等会保留）----
# 延迟注销：等磁盘预检通过后再注销旧发行版，避免空间不足时先删掉可用的发行版。
$distroExists = Test-DistroExists
$import = -not $distroExists
if ($distroExists) {
  if ($Yes) {
    $import = [bool]$Reinstall
  } else {
    $ans = Read-Host "发行版 '$Distro' 已存在。是否用 '$ReleaseTag' 版重装它？（不会影响数据盘）[Y/n]"
    $import = Resolve-YesNoDefault -Answer $ans -DefaultYes $true
  }
  if (-not $import) { Ok '保留现有发行版（不重装）。' }
}
$reinstall = $distroExists -and $import

# --- 导入相关路径与 Release 元数据（供磁盘预检与下载复用）------------------
$stz        = "rootfs-$Variant-amd64.tar.zst"
$stzPath    = Join-Path $InstallDir $stz
$tarPath    = Join-Path $InstallDir "rootfs-$Variant-amd64.tar"
$localParts = @(Get-ChildItem -Path $PSScriptRoot -Filter "$stz.part-*" -ErrorAction SilentlyContinue)
$local      = @()
$parts      = @()
$firstUrl   = $null
$compressed = 0L
$uncomp     = 0L

if ($import) {
  if ($localParts.Count -gt 0) {
    $parts = @($localParts | Sort-Object Name)
  } else {
    $relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
    $rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-installer' }
    $parts = @($rel.assets | Where-Object { $_.name -like "$stz.part-*" } | Sort-Object name)
    if ($parts.Count -eq 0) { throw "在 '$ReleaseTag' Release 中未找到 '$stz.part-*' 分片。" }
    $firstUrl = $parts[0].browser_download_url
  }
}

# --- [2/10] 检查磁盘空间（下载前，避免装到一半爆盘）----------------------
Step '[2/10] 检查磁盘空间…'
if ($import) {
  if (-not (Get-Command Assert-DiskSpace -ErrorAction SilentlyContinue)) {
    throw '缺少 wsl-ensure.ps1 中的磁盘检查辅助函数；请从 Release 压缩包中完整解压所有脚本后重试。'
  }
  if ($localParts.Count -gt 0) {
    $compressed = [long](($localParts | Measure-Object Length -Sum).Sum)
    $uncomp     = [long](Get-ZstdUncompressedSize ($parts[0].FullName))
  } else {
    $compressed = [long](($parts | Measure-Object -Property size -Sum).Sum)
    $uncomp     = [long](Get-ZstdUncompressedSizeFromUrl $firstUrl)
  }
  if ($uncomp -le 0) { $uncomp = 0 }   # Get-RequiredDiskBytes 会按压缩量保守估算
  $needBytes = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Stream'
  Assert-DiskSpace -Path $InstallDir -RequiredBytes $needBytes
  Ok ("磁盘空间充足（需要约 {0:N1} GiB）。" -f ($needBytes / 1073741824.0))
} else {
  Ok '发行版已存在，跳过。'
}

# 磁盘确认足够后才注销旧发行版（避免空间不足时先删掉可用的发行版）。
if ($reinstall) {
  Write-Host "正在注销 '$Distro'（数据盘保留）…"
  Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null
}

# --- [3/10] 下载镜像 -------------------------------------------------------
Step "[3/10] 下载镜像（$ReleaseTag）…"
if ($import) {
  if ($localParts.Count -gt 0) {
    Ok '发现本地 rootfs 分片，跳过下载。'
  } else {
    foreach ($p in $parts) {
      $dest = Join-Path $InstallDir $p.name
      if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq [long]$p.size)) {
        Ok "  已存在且完整，跳过：$($p.name)"
      } else {
        Write-Host "  $($p.name)"
        Save-Download -Url $p.browser_download_url -Dest $dest
      }
      $local += $dest
    }
  }
} else {
  Ok '跳过下载。'
}

# --- [4/10] 导入镜像（流式 zstd，三级回退）--------------------------------
Step '[4/10] 导入镜像…'
if ($import) {
  $importParts = if ($localParts.Count -gt 0) { @($parts | ForEach-Object { $_.FullName }) } else { @($local) }
  $imported = $false
  try {
    # Tier 1：分片直接流式喂给 `wsl --import -`（无 zstd.exe / 合并 / 中间 tar）。
    Write-Host '尝试流式导入（Tier 1）…'
    try {
      $code = Invoke-WslImportStream -Parts $importParts -Distro $Distro -InstallDir $InstallDir
      if ($code -eq 0) { $imported = $true } else { Warn "流式导入返回 $code，改用回退方案。" }
    } catch { Warn "流式导入异常：$($_.Exception.Message)" }
    if (-not $imported) { try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {} }

    # Tier 2：合并分片后按文件路径导入（从文件识别压缩，但不识别 stdin）。
    if (-not $imported) {
      Warn '回退 Tier 2：合并分片后按文件导入（会占用额外空间，重新检查）。'
      $need2 = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Merge'
      Assert-DiskSpace -Path $InstallDir -RequiredBytes $need2
      Join-Parts -Parts $importParts -Dest $stzPath
      Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $stzPath) | Out-Null
      if ($script:NativeExit -eq 0) { $imported = $true } else { Warn "Tier 2 导入返回 $($script:NativeExit)。" }
      if (-not $imported) { try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {} }
    }

    # Tier 3：用 zstd.exe 解压为 .tar 再导入（仅此路径才可能需要下载 zstd.exe）。
    if (-not $imported) {
      Warn '回退 Tier 3：解压为 .tar 再导入。'
      $need3 = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Legacy'
      Assert-DiskSpace -Path $InstallDir -RequiredBytes $need3
      $zstdExe = Get-ZstdExe -InstallDir $InstallDir
      Join-Parts -Parts $importParts -Dest $stzPath
      Invoke-Native $zstdExe @('-d', '-f', '-o', $tarPath, $stzPath) | Out-Null
      if ($script:NativeExit -ne 0) { throw "zstd 解压失败（$script:NativeExit）" }
      Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $tarPath) | Out-Null
      if ($script:NativeExit -ne 0) { try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}; throw "wsl --import 失败（$script:NativeExit）" }
      $imported = $true
    }
  } finally {
    # 成功或失败都清理：合并的 .zst、中间 .tar、以及本次下载的分片（保留仓库预置分片）。
    Remove-Item -LiteralPath $stzPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
    if ($localParts.Count -eq 0) { foreach ($lp in $local) { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue } }
  }
} else {
  Ok '跳过导入。'
}

# --- [5/10] 校验发行版注册 -------------------------------------------------
Step '[5/10] 校验发行版注册…'
if ($import) {
  # -NoLaunch: 此刻还没有数据盘/配置，不能启动发行版（否则启动脚本会写维护模式 MOTD）。
  Assert-DistroReady -Distro $Distro -InstallDir $InstallDir -NoLaunch -UnregisterOnFail
  Ok "发行版 '$Distro' 已注册。"
} else {
  Ok '跳过校验。'
}

# --- [6/10] 创建数据磁盘（32GB 动态）--------------------------------------
Step '[6/10] 创建数据磁盘（32GB 动态）…'
if (-not (Test-Path $VhdxPath)) {
  Write-Host "正在创建数据磁盘 $VhdxPath（32GB 动态）…"
  try {
    New-VHD -Path $VhdxPath -SizeBytes 32GB -Dynamic | Out-Null
  } catch {
    Write-Host 'New-VHD 不可用（可能是 Windows 家庭版）；改用 diskpart…'
    $dp = @"
create vdisk file="$VhdxPath" maximum=32768 type=expandable
select vdisk file="$VhdxPath"
attach vdisk
"@
    Invoke-Native 'diskpart' @() -InputText $dp | Out-Null
    # 分离；真正挂载交给下面的 wsl。
    $detach = @"
select vdisk file="$VhdxPath"
detach vdisk
"@
    Invoke-Native 'diskpart' @() -InputText $detach | Out-Null
  }
} else {
  Ok '数据磁盘已存在，保持不变。'
}

# --- [7/10] 初始化数据磁盘（bare 挂载 → 初始化 → 取 UUID → 卸载）---------
Step '[7/10] 初始化数据磁盘…'
Invoke-Native 'wsl.exe' @('--mount', '--vhd', $VhdxPath, '--bare') | Out-Null
Start-Sleep -Seconds 2

$initOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', '/usr/local/bin/datadisk-init.sh')
Write-Host $initOut
$uuid = ''
foreach ($line in ($initOut -split "`n")) {
  if ($line -match 'UUID=([0-9a-fA-F-]{36})') { $uuid = $Matches[1] }
}
# 兜底：按标签读取 UUID。只接受退出码为 0 且形如 UUID 的结果——Invoke-Native 合并了
# stderr，不能把原生进程的报错文本当成 UUID。
if (-not $uuid) {
  $blkidOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "blkid -t LABEL=$DiskName -s UUID -o value")
  if ($script:NativeExit -eq 0) {
    $uuid = ($blkidOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -First 1)
  }
}
if (-not $uuid) { throw '无法确定数据盘 UUID：datadisk-init 与 blkid 都没有返回有效 UUID，数据盘可能未初始化。' }

Write-Host '正在卸载数据磁盘（开机时会重新挂载）…'
Invoke-Native 'wsl.exe' @('--unmount', "\\?\$VhdxPath") | Out-Null

# --- [8/10] 修复权限（尽力而为：让非提权的 WSL 用户也能打开该 VHDX）---------
Step '[8/10] 修复权限…'
$RunAsUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if (-not $RunAsUser) { $RunAsUser = "$env:USERDOMAIN\$env:USERNAME" }
Invoke-Native 'icacls.exe' @($VhdxPath, '/setowner', $RunAsUser) | Out-Null
Invoke-Native 'icacls.exe' @($VhdxPath, '/grant', "${RunAsUser}:(F)") | Out-Null
Ok "已尽力修复 $VhdxName 的所有者/ACL（$RunAsUser）。"

# --- paseo 密码（后台服务必填）；写入启动配置 ------------------------------
if (-not $Yes) {
  $pw = Read-Host 'paseo 密码（直接回车则自动生成随机密码）'
} else {
  $pw = ''
}
if ([string]::IsNullOrWhiteSpace($pw)) {
  $pw = -join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
  Write-Host "已生成 paseo 密码：$pw"
}

# --- [9/10] 写入启动配置 ---------------------------------------------------
Step '[9/10] 写入启动配置 /etc/agent-devbox.conf…'
$conf = "DATA_VHDX=$(Quote-Bash $VhdxPath)`nDATA_UUID=$(Quote-Bash $uuid)`nPASEO_PASSWORD=$(Quote-Bash $pw)`nDATA_MNTNAME='agent-devbox-data'`nDATA_TASK='agent-devbox-mount-datadisk'`n"
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($conf))
Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "set -o pipefail; umask 077; printf '%s' '$b64' | base64 -d > $ConfPath && chmod 600 $ConfPath") | Out-Null
if ($script:NativeExit -ne 0) { throw "写入 $ConfPath 失败（退出码 $script:NativeExit）" }
Ok "已写入 $ConfPath（UUID=$uuid）"

# --- [10/10] 注册开机自动挂载计划任务（默认始终注册；-NoTask 可跳过）------
Step '[10/10] 注册开机自动挂载计划任务…'
if ($NoTask) {
  Ok '已跳过计划任务注册'
} else {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  }
  $action    = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "--mount --vhd `"$VhdxPath`" --type ext4 --name agent-devbox-data"
  $trigger   = New-ScheduledTaskTrigger -AtLogOn
  $principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Description 'agent-devbox：登录时自动挂载数据磁盘' | Out-Null
  Ok "已注册计划任务 '$TaskName'（开机自动挂载数据磁盘）。"
}

# --- [完成] 重启发行版并汇总 ----------------------------------------------
Step '[完成] 重启发行版…'
Invoke-Native 'wsl.exe' @('--terminate', $Distro) | Out-Null
$readyOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', 'echo "agent-devbox 已就绪"; mount | grep -E "agent-devbox-data| /home | /root | /workspace " || true')
Write-Host $readyOut
Write-Host ''
Assert-DistroReady -Distro $Distro -InstallDir $InstallDir
Ok "安装完成。变体=$Variant  Release=$ReleaseTag  安装目录=$InstallDir"
Write-Host '进入环境：wsl -d agent-devbox'
Write-Host 'paseo 网页界面：在打开的 WSL 里启动 paseo 后，浏览器访问 http://localhost:6767（登录密码即上面设置的 PASEO_PASSWORD）。'
Write-Host '若要修改 paseo 密码：编辑 /etc/agent-devbox.conf，或在启动前设置环境变量 PASEO_PASSWORD。'

if ($script:Logging) {
  try { [System.IO.File]::WriteAllText($script:RcPath, '0') } catch {}
  try { Stop-Transcript | Out-Null } catch {}
}
