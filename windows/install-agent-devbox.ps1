<#
.SYNOPSIS
  agent-devbox Windows 一键安装脚本（WSL2）。

.DESCRIPTION
  - 按变体导入镜像并让两个变体并存：agents 变体导入为 `agent-devbox`，core 变体
    导入为 `agent-devbox-core`（各自独立的发行版名 / 安装目录）。
  - 通道（-Channel）：stable（main）沿用上面的名字；beta（任何非 main 的 ref）全部
    加 `-beta`：agent-devbox-beta / agent-devbox-core-beta，默认安装目录为
    D:\WSL\agent-devbox-beta / D:\WSL\agent-devbox-core-beta。beta 与 stable 是两套
    完全独立的身份（目录 / 发行版 / 数据盘标签 / 挂载名 / WT GUID），互不影响。
  - 创建并挂载一块 32GB 动态 VHDX 数据磁盘并初始化。
  - 数据盘的 ext4 标签与挂载名按通道区分：stable = `devbox-data`，beta =
    `devbox-data-beta`（同一通道内两个变体可互换数据盘；跨通道绝不互相挂载）。
  - 把数据磁盘接入发行版，使 /home、/root、/workspace 在镜像升级后依然保留。
  - 完全不注册任何计划任务：数据盘由发行版开机时的 guest 侧 wsl-boot.sh 自己 attach。
    boot 失败时维护横幅会打印安装目录里的 `mount-datadisk.cmd`；安装器只负责删除旧版本
    注册过的计划任务（不接管、不再注册）。

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
  [ValidateSet('stable', 'beta')] [string] $Channel = 'stable',
  [string] $InstallDir = '',
  [string] $ReleaseTag = '',
  [switch] $Yes,
  [switch] $Reinstall,
  [switch] $KeepExisting,
  [switch] $UpgradeConfirmed,
  [ValidateRange(1, 8)] [int] $Connections = 4,
  [string] $LogPath = ''
)

# --- 控制台 UTF-8（尽力而为，失败也不影响运行）------------------------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$env:WSL_UTF8 = '1'

$ErrorActionPreference = 'Stop'
$script:RunStamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:InstallLog  = ''
# 本次运行下载的分片：网络/导入失败时保留（连同 sidecar），下一次运行会重新校验
# 身份并续传；只有确认内容可疑或导入成功时才由清理计划删除。
$script:PartsDownloaded = @()
# 分片内容被证明可疑（Tier 3 zstd 解压失败 / SHA256 连续失败）时为 $true：
# 清理计划此时才允许删除本次下载的分片。
$script:ContentSuspect  = $false
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$VhdxName  = 'data.vhdx'
$Repo      = 'sfhgknsdfksdlf/agent-devbox'
$ConfPath  = '/etc/agent-devbox.conf'

# --- 输出辅助：统一的进度 / 提示样式 ----------------------------------------
# 折行 / 宽度感知由 wsl-ensure.ps1 的共享 UI 辅助提供；拿不到时退回普通 Write-Host
# （安装器可能在只取回部分脚本的旧环境里运行）。
function Step([string]$m) {
  if (Get-Command Write-UiSection -ErrorAction SilentlyContinue) { Write-UiSection -Text $m; return }
  Write-Host ''
  Write-Host "==> $m" -ForegroundColor Cyan
}
function Ok([string]$m) {
  if (Get-Command Write-UiLine -ErrorAction SilentlyContinue) { Write-UiLine -Text "  - $m" -Color Green; return }
  Write-Host "  - $m" -ForegroundColor Green
}
function Warn([string]$m) {
  if (Get-Command Write-UiLine -ErrorAction SilentlyContinue) { Write-UiLine -Text "  ! $m" -Color Yellow; return }
  Write-Host "  ! $m" -ForegroundColor Yellow
}
function Err([string]$m) {
  if (Get-Command Write-UiLine -ErrorAction SilentlyContinue) { Write-UiLine -Text "  x $m" -Color Red; return }
  Write-Host "  x $m" -ForegroundColor Red
}

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
# Thin wrapper: the authoritative probe is shared with the entry (never throws).
function Test-DistroExists {
  if (Get-Command Test-WslDistroExists -ErrorAction SilentlyContinue) { return (Test-WslDistroExists -Distro $Distro) }
  return ((Get-WslDistros) -contains $Distro)
}

# 解析版本选择：beta -> 最近的 beta-* 预发布；裸 YYYYMMDD.HHMM -> build-*；其余原样。
function Resolve-ReleaseTag {
  param([string] $Sel)
  $sel = Normalize-ReleaseTag $Sel
  $hdr = @{ 'User-Agent' = 'agent-devbox-installer' }
  $api = "https://api.github.com/repos/$Repo/releases"
  if ($sel -eq 'beta') {
    $rels = Invoke-RestMethod "${api}?per_page=100" -Headers $hdr
    $beta = $rels | Where-Object { $_.prerelease -eq $true -and $_.tag_name -like 'beta-*' } | Select-Object -First 1
    if (-not $beta) { throw '未找到 beta 预发布版本。' }
    return $beta.tag_name
  }
  if ($sel -eq 'latest') {
    # 优先正式（非预发布）Release；若当前只有预发布（beta）Release，则退回最新的一个。
    try { return (Invoke-RestMethod "$api/latest" -Headers $hdr).tag_name }
    catch {
      $first = @(Invoke-RestMethod "${api}?per_page=1" -Headers $hdr | Select-Object -First 1)
      if ($first.Count -ge 1 -and $first[0].tag_name) {
        Write-Host "暂无正式版 Release，改用最新的 Release：$($first[0].tag_name)"
        return $first[0].tag_name
      }
      throw '未找到任何 Release。'
    }
  }
  return $sel
}

# --- 变体选择（精简版 core / 完整版 agents）：仅未显式指定且交互时询问 ------
if (-not $PSBoundParameters.ContainsKey('Variant') -and -not $Yes -and [Environment]::UserInteractive) {
  $vsel = Read-Host '选择镜像 [回车 = 完整版（多助手 agents），c = 精简版（core）]'
  if (-not [string]::IsNullOrWhiteSpace($vsel) -and $vsel.Trim() -match '^(?i:c|core)$') { $Variant = 'core' }
  else { $Variant = 'agents' }
}

# 应用通道身份：发行版名 / 安装目录 / 数据盘标签与挂载名 / Terminal GUID 全部由
# (变体, 通道) 决定；stable 与正式安装逐字一致，beta 是一套独立的身份。
if (-not (Get-Command Get-AgentDevboxChannelIdentity -ErrorAction SilentlyContinue)) {
  throw '缺少 Get-AgentDevboxChannelIdentity（wsl-ensure.ps1 未加载）。请通过 install.ps1 安装；直接运行本脚本时请把 wsl-ensure.ps1 放在同一目录。'
}
$v = Get-AgentDevboxChannelIdentity -Variant $Variant -Channel $Channel
$Distro = $v.Distro
$Label = $v.Label
$MountName = $v.MountName

# --- 决定安装目录（必须早于 UAC 提权与升级确认）------------------------------
# 提权子进程只能靠 -InstallDir 收到用户的选择，升级提示也要显示同一个目录。
# 默认值随「变体 + 通道」变化；-Yes / 重定向 / 非交互一律用默认值，绝不阻塞。
# 这里只确定路径，目录本身仍然等到 [1/10] 之后才真正创建（取消升级不留痕迹）。
if (-not $InstallDir) {
  $default = $v.InstallDir
  $__dirInteractive = if (Get-Command Test-InteractiveConsole -ErrorAction SilentlyContinue) {
    Test-InteractiveConsole
  } else {
    [Environment]::UserInteractive
  }
  if ($Yes -or -not $__dirInteractive) {
    $InstallDir = $default
  } else {
    $answer = Read-Host "安装目录 [$default]（直接回车使用默认值）"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer }
  }
}
$InstallDir = $InstallDir.Trim()
if ($InstallDir -notmatch '^[A-Za-z]:\\$') { $InstallDir = $InstallDir.TrimEnd('\') }
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = $v.InstallDir }

# --- 通道所有权闸门：一个安装目录只属于一个通道（早于 UAC / 任何改动）------
# beta 绝不能接管正式安装的目录/数据盘，stable 也不能接管 beta 的目录。
# 占用判定 = 已有数据盘（data.vhdx）或系统盘（ext4.vhdx）：旧安装可能在数据盘创建
# 之前就失败，只留下 ext4.vhdx；只看 data.vhdx 会让 beta 的 import 覆盖正式系统盘。
# 标记文件缺失 = 通道功能之前的旧安装（按 stable 处理）。
$ChannelMarker = Join-Path $InstallDir '.agent-devbox-channel'
$ownedByDisk = (
  (Test-Path -LiteralPath (Join-Path $InstallDir $VhdxName)) -or
  (Test-Path -LiteralPath (Join-Path $InstallDir 'ext4.vhdx'))
)
if ($ownedByDisk) {
  $markedChannel = 'stable'
  if (Test-Path -LiteralPath $ChannelMarker) {
    try {
      $markedRaw = [System.IO.File]::ReadAllText($ChannelMarker).Trim()
    } catch {
      throw ("无法读取通道标记 $ChannelMarker：$($_.Exception.Message)。请修复权限后重试，或换一个新的 -InstallDir。")
    }
    if (-not [string]::IsNullOrWhiteSpace($markedRaw)) { $markedChannel = $markedRaw }
  }
  if ($markedChannel -ne $Channel) {
    throw ("安装目录 $InstallDir 属于 $markedChannel 通道（$ChannelMarker），不能用 $Channel 通道安装。" +
      "beta 与 stable 各自使用独立目录与数据盘；请去掉 -InstallDir 使用 $Channel 通道的默认目录，或为 $Channel 通道指定一个新目录。")
  }
}

# --- 提权一次（UAC）：提权子进程写日志，原窗口等待后回显整份日志 ------------
if (-not (Test-Admin)) {
  # Explorer-extracted scripts may carry Mark-of-the-Web, which RemoteSigned
  # would block; the .bat/.cmd entry points intentionally keep Bypass.
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Variant', $Variant)
  $argv += @('-Channel', $Channel)
  if ($InstallDir) { $argv += @('-InstallDir', "`"$InstallDir`"") }
  if ($ReleaseTag) { $argv += @('-ReleaseTag', $ReleaseTag) }
  if ($Yes)        { $argv += '-Yes' }
  if ($Reinstall)  { $argv += '-Reinstall' }
  if ($KeepExisting) { $argv += '-KeepExisting' }
  if ($UpgradeConfirmed) { $argv += '-UpgradeConfirmed' }
  $argv += @('-Connections', "$Connections")

  $parentLog = if ($LogPath) { $LogPath } else {
    $scratch = Join-Path $env:LOCALAPPDATA 'agent-devbox'
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    Join-Path $scratch ("agent-devbox-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  }
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
    # A cancel exits 0 but changed NOTHING: never let it fall through to the
    # success message.
    if (Test-Path -LiteralPath "$parentLog.cancel") {
      Warn '已取消升级（未做任何更改）。'
      exit 0
    }
    if ($rc -eq 3010) { Warn 'WSL 已安装完成；请重启 Windows 后再次运行本安装脚本。'; exit 0 }
    if ($rc -ne 0) { Err "安装失败（退出码 $rc）。"; exit $rc }
    # 从“当前（非提权）用户”角度确认发行版可见——WSL 发行版按用户注册。
    try {
      $names = @(Invoke-Native 'wsl.exe' @('-l', '-q') | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
      if ($names -notcontains $Distro) {
        Warn "注意：当前（非提权）用户看不到发行版 '$Distro'。WSL 发行版按用户注册；若 UAC 用了另一个管理员帐户，发行版会落在那个帐户下。请用安装时的同一帐户，或在管理员帐户下运行 wsl -l -v 检查。"
      }
    } catch {}
    Ok "安装完成。进入环境：wsl -d $Distro"
    exit 0
  } finally {
    Remove-Item -LiteralPath $parentLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$parentLog.rc" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$parentLog.cancel" -Force -ErrorAction SilentlyContinue
  }
}

# --- 升级确认：只在交互式控制台问一次（回车 = 覆盖升级，n = 取消）-----------
# 决策必须发生在任何改动之前：此刻还没有 WT profile、没有 Ensure-Wsl、没有下载、
# 也没有注销。Test-WslDistroExists 在 WSL 缺失时安全返回 $false（-> 按全新安装）。
# 入口（install.ps1）已经问过时带 -UpgradeConfirmed，这里不再重复提问。
# 没有 wsl-ensure.ps1 时（降级路径）跳过确认，保持旧的「静默升级」行为。
$distroExists = $false
$decision = 'upgrade'
if ($__haveEnsure) {
  $distroExists = Test-WslDistroExists -Distro $Distro
  $decision = if ($UpgradeConfirmed) {
    if ($KeepExisting -and $distroExists) { 'keep' } else { 'upgrade' }
  } else {
    Confirm-Upgrade -Distro $Distro -Yes:$Yes -KeepExisting:$KeepExisting -LogPath $LogPath -InstallDir $InstallDir
  }
}
if ($decision -eq 'cancel') { return }
$import = $decision -ne 'keep'
$reinstall = $distroExists -and $import

# --- Windows Terminal profile：固定 GUID（跨重装不变）------------------------
# WSL 每次 `wsl --import` 都会按注册表 GUID 生成一条 WT profile；重装换 GUID 后用户
# 的自定义全留在旧条目上。镜像里用 [windowsterminal] enabled=false 关掉自动生成，
# 这里写一条固定 GUID 的 fragment，并用 `-d <发行版名>` 启动（不依赖注册表 GUID）。
try {
  $fragPath = Write-AgentDevboxTerminalProfile -Distro $Distro -ProfileGuid $v.TerminalGuid -HideGuid $v.HideGuid
  Ok "Windows Terminal profile 已固定：$fragPath（GUID=$($v.TerminalGuid)）"
} catch { Warn "写入 Windows Terminal profile 失败（不影响安装）：$($_.Exception.Message)" }
try {
  $staleFrag = Remove-StaleWslTerminalFragments -Distro $Distro
  if ($staleFrag -gt 0) { Ok "已清理 WSL 自动生成的旧 Terminal profile：$staleFrag 个。" }
} catch { Warn "清理旧 Terminal profile 失败：$($_.Exception.Message)" }

# --- 提权后的主流程：把输出同时写进 -LogPath（供原窗口回显）---------------
$script:Logging = -not [string]::IsNullOrWhiteSpace($LogPath)
$script:RcPath  = if ($script:Logging) { "$LogPath.rc" } else { '' }

# 结束本次安装的转录日志，并把它复制到安装目录（持久保留）。
# 显式路径调用（-LogPath）时，转录写在 LogPath，最后复制为安装目录下的安装日志。
function Save-InstallTranscript {
  if ($script:Logging) {
    try { Stop-Transcript | Out-Null } catch {}
    $script:Logging = $false
  }
  if ($script:InstallLog -and $LogPath -and ($script:InstallLog -ne $LogPath) -and (Test-Path -LiteralPath $LogPath)) {
    try { Copy-Item -LiteralPath $LogPath -Destination $script:InstallLog -Force } catch { Warn "复制安装日志失败：$($_.Exception.Message)" }
  }
}

# Trap must sit at script scope (not inside an if-block) so it guards the whole
# flow: on any terminating error, mark the result file and flush the transcript.
trap {
  try { Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red } catch {}
  try { Write-Host ($_ | Out-String) } catch {}
  # 失败时绝不删除已下载的分片与 sidecar：下一次运行会用 sidecar 里的身份
  # （URL / ETag / 长度 / SHA256）重新校验，再从这里续传。
  try {
    if (@($script:PartsDownloaded).Count -gt 0) {
      $partDir = if ($InstallDir) { $InstallDir } else { $PSScriptRoot }
      Write-Host ("已下载的分片保留在：{0}" -f $partDir)
      Write-Host '重跑安装器会校验分片身份并续传（无需重新下载）。'
    }
  } catch {}
  if ($script:Logging -and $script:RcPath) {
    try { [System.IO.File]::WriteAllText($script:RcPath, '1') } catch {}
  }
  Save-InstallTranscript
  exit 1
}
if ($script:Logging) {
  Start-Transcript -Path $LogPath -Force | Out-Null
}

# 无人值守/提前确认：在下载和注销之前就把“空数据盘”说清楚，不能只等到 [6/10]。
# 必须在 Start-Transcript 之后，否则提权窗口回显的日志里看不到这条告警。
if ($distroExists -and -not (Test-Path -LiteralPath (Join-Path $InstallDir $VhdxName))) {
  Warn "升级：安装目录 $InstallDir 下没有 data.vhdx；本次会新建空数据盘，旧 /home /root /workspace 不会迁移。"
}

# --- [1/10] 检查运行环境 ----------------------------------------------------
Step '[1/10] 检查运行环境…'
# 预检查：确保 WSL 存在，并（建议）启用镜像网络（helpers 已在顶部 dot-source）。
if ($__haveEnsure) {
  $__r = Ensure-Wsl -Yes:$Yes
  if ($__r -eq 'reboot-required') {
    Write-Host 'WSL 已安装完成；请重启 Windows 后再次运行本安装脚本。'
    if ($script:Logging -and $script:RcPath) { try { [System.IO.File]::WriteAllText($script:RcPath, '3010') } catch {} }
    Save-InstallTranscript
    exit 0
  }
  if (-not (Test-WslInstalled)) { throw 'WSL 仍不可用，环境配置未完成。' }
  Set-MirroredNetworking -Yes:$Yes | Out-Null
} else {
  Write-Warning '未找到 wsl-ensure.ps1；已跳过 WSL/网络预检查（install.ps1 应把它从 main 取回；请检查网络与源码分支）。'
}

# --- 创建安装目录（路径早在提权前就已确定，这里才真正落盘）------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
# 记录本目录所属通道：同一目录不允许换个通道再来一次（否则会串用数据盘）。
[System.IO.File]::WriteAllText($ChannelMarker, $Channel, (New-Object System.Text.UTF8Encoding($false)))
$script:InstallLog = Join-Path $InstallDir ("agent-devbox-install-{0}.log" -f $script:RunStamp)
if (-not $script:Logging) {
  try {
    Start-Transcript -Path $script:InstallLog -Force | Out-Null
    $script:Logging = $true
  } catch {
    Warn "无法写入安装日志：$($_.Exception.Message)"
  }
}

# --- 手动挂载/卸载助手（复制到安装目录，方便排查或挂载其它数据盘）------------
foreach ($helper in @('mount-datadisk.cmd', 'unmount-datadisk.cmd')) {
  $helperSrc = Join-Path $PSScriptRoot $helper
  if (Test-Path -LiteralPath $helperSrc) {
    Copy-Item -LiteralPath $helperSrc -Destination (Join-Path $InstallDir $helper) -Force
  } else {
    Warn "未找到 $helper（跳过复制到安装目录）。"
  }
}
$VhdxPath = Join-Path $InstallDir $VhdxName
Write-Host "发行版=$Distro  变体=$Variant  通道=$Channel  安装目录=$InstallDir"

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

# 是否覆盖已存在的发行版已在提权后、任何改动之前决定（$import / $reinstall）。
# 延迟注销：等磁盘预检通过后再注销旧发行版，避免空间不足时先删掉可用的发行版。
# 升级 = 换系统盘，但数据盘（/home /root /workspace）和 paseo 密码都保留。

# 升级不再去旧系统盘读密码。密码的权威位置是数据盘上的 `.paseo-password`（[7/10] 按 UUID
# 挂载后读取，跨升级保留）；2026-10-20 01:13 起的所有安装都有这个文件。
# 去掉这一步是为了不再为 `cat` 一个文件把旧发行版整机拉起（[boot] 会顺带 mount 数据盘 +
# 启动 paseo），也就不会出现「升级刚开始 paseo 被拉起来、1 分钟后又被 terminate」。

# --- 导入相关路径与 Release 元数据（供磁盘预检与下载复用）------------------
$Arch = Get-AgentDevboxHostArch   # 'amd64' | 'arm64'; unknown throws
$osBuild = [Environment]::OSVersion.Version.Build
if ($Arch -eq 'arm64' -and $osBuild -lt 22000) {
  throw ("Windows 10 ARM64 不受支持：ARM64 路径需要 Windows 11（build 22000+），当前 build {0}。" +
    "请改用 x64 Windows，或升级到 Windows 11 ARM64。" -f $osBuild)
}
$stz        = "rootfs-$Variant-$Arch.tar.zst"
$stzPath    = Join-Path $InstallDir $stz
$tarPath    = Join-Path $InstallDir "rootfs-$Variant-$Arch.tar"
# 预置分片只在安装目录里找。$PSScriptRoot 是 install.ps1 取回的脚本副本所在目录
# （提权后的暂存目录），永远看不到用户放在 InstallDir 里的分片。
$localParts = @(Get-ChildItem -Path $InstallDir -Filter "$stz.part-*" -ErrorAction SilentlyContinue)
$partsWerePreexisting = ($localParts.Count -gt 0)
$useLocalParts = $false
$local      = @()
$parts      = @()
$firstUrl   = $null
$compressed = 0L
$uncomp     = 0L
$rel        = $null

if ($import -and $localParts.Count -gt 0) {
  # 预置分片只有在「有清单 + 每个分片都被覆盖且 SHA256 匹配」时才可信。
  # 清单优先取安装目录里的 SHA256SUMS，其次取 Release 资产；缺失 / 不完整 /
  # 不匹配都只警告，然后回退到正常 Release 下载路径（由下载器重新校验）。
  $seedMap = @{}
  $sumsPath = Join-Path $InstallDir 'SHA256SUMS'
  if (Test-Path -LiteralPath $sumsPath) {
    try {
      $seedMap = ConvertFrom-Sha256Sums -Text ([System.IO.File]::ReadAllText($sumsPath))
    } catch { $seedMap = @{} }
    if ($seedMap.Count -eq 0) { Warn '本地 SHA256SUMS 为空或无法解析，不信任预置分片。' }
  }
  if ($seedMap.Count -eq 0) {
    try {
      $relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
      $rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-installer' }
      $sumsAsset = @($rel.assets | Where-Object { $_.name -ceq 'SHA256SUMS' }) | Select-Object -First 1
      if ($sumsAsset) {
        $tmpSums = Join-Path $InstallDir '.agent-devbox-seed-SHA256SUMS'
        try {
          Invoke-WebRequest -Uri $sumsAsset.browser_download_url -OutFile $tmpSums -UseBasicParsing -ErrorAction Stop
          $seedMap = ConvertFrom-Sha256Sums -Text ([System.IO.File]::ReadAllText($tmpSums))
        } finally {
          Remove-Item -LiteralPath $tmpSums -Force -ErrorAction SilentlyContinue
        }
      } else {
        Warn '该 Release 未提供 SHA256SUMS，无法校验预置分片。'
      }
    } catch {
      Warn "获取 SHA256SUMS 失败（无法校验预置分片）：$($_.Exception.Message)"
    }
  }
  if ($seedMap.Count -gt 0) {
    $seedNames = @($localParts | ForEach-Object { $_.Name })
    $seedMissing = @(Get-MissingSha256Parts -ShaMap $seedMap -Names $seedNames)
    if ($seedMissing.Count -gt 0) {
      Warn ("SHA256SUMS 未覆盖预置分片：{0}；改从 Release 重新校验并下载。" -f ($seedMissing -join ', '))
    } else {
      $seedBad = @()
      foreach ($lp in $localParts) {
        $want = "$($seedMap[$lp.Name])".Trim().ToLowerInvariant()
        $got = Get-FileSha256 -Path $lp.FullName
        if ($got -ne $want) { $seedBad += $lp.Name }
      }
      if ($seedBad.Count -gt 0) {
        Warn ("预置分片 SHA256 不符：{0}；改从 Release 重新校验并下载。" -f ($seedBad -join ', '))
      } else {
        # 清单覆盖的每个分片都必须已经在安装目录里。只下载了一部分就失败的
        # 上一次运行留下的「有效子集」不能直接导入（会缺分片），必须回退到
        # Release 路径：下载器复用已校验的部分、只续传缺少的部分。
        $manifestParts = @($seedMap.Keys | Where-Object { $_ -like "$stz.part-*" })
        $presentParts = @($localParts | ForEach-Object { $_.Name })
        $seedAbsent = @($manifestParts | Where-Object { $presentParts -notcontains $_ })
        if ($seedAbsent.Count -gt 0) {
          Warn ("预置分片不完整（缺少：{0}）；改从 Release 续传缺少的分片。" -f ($seedAbsent -join ', '))
        } else {
          $parts = @($localParts | Sort-Object Name)
          $useLocalParts = $true
          Ok ("已校验预置 rootfs 分片（{0} 个，SHA256 全部匹配）。" -f $parts.Count)
        }
      }
    }
  } else {
    Warn '没有可用的 SHA256SUMS，预置分片不受信任；改从 Release 重新校验并下载。'
  }
}

if ($import -and -not $useLocalParts) {
  if ($null -eq $rel) {
    $relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
    $rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-installer' }
  }
  $parts = @($rel.assets | Where-Object { $_.name -like "$stz.part-*" } | Sort-Object name)
  if ($parts.Count -eq 0) {
    if ($Arch -eq 'arm64') {
      throw ("Release '$ReleaseTag' 没有 ARM64 分片（$stz.part-*）：该版本早于 ARM64 支持，只发布了 amd64。" +
        "请改用最新版本（-ReleaseTag latest / beta），或在 x64 Windows 上安装。未下载任何文件，现有安装未改动。")
    }
    throw "在 '$ReleaseTag' Release 中未找到 '$stz.part-*' 分片。"
  }
  $firstUrl = $parts[0].browser_download_url
}

# --- [2/10] 检查磁盘空间（下载前，避免装到一半爆盘）----------------------
Step '[2/10] 检查磁盘空间…'
if ($import) {
  if (-not (Get-Command Assert-DiskSpace -ErrorAction SilentlyContinue)) {
    throw '缺少 wsl-ensure.ps1 中的磁盘检查辅助函数；请确认 install.ps1 已从 main 取回全部脚本后重试。'
  }
  if ($useLocalParts) {
    $compressed = [long](($localParts | Measure-Object Length -Sum).Sum)
    $uncomp     = [long](Get-ZstdUncompressedSize ($parts[0].FullName))
  } else {
    $compressed = [long](($parts | Measure-Object -Property size -Sum).Sum)
    $uncomp     = [long](Get-ZstdUncompressedSizeFromUrl $firstUrl)
  }
  if ($uncomp -le 0) { $uncomp = 0 }   # Get-RequiredDiskBytes 会按压缩量保守估算
  # Segmented mode peaks at 2C (segment files + destination); the streaming peak
  # is normally larger, but assert the max so a future small-image layout cannot
  # pass the check and then run out of space during a segmented download.
  $needStream = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Stream'
  $needSegmented = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Segmented'
  $needBytes = [Math]::Max([long]$needStream, [long]$needSegmented)
  Assert-DiskSpace -Path $InstallDir -RequiredBytes $needBytes | Out-Null
  Ok ("磁盘空间充足（需要约 {0:N1} GiB）。" -f ($needBytes / 1073741824.0))
} else {
  Ok '发行版已存在，跳过。'
}

# --- [3/10] 下载镜像 -------------------------------------------------------
Step "[3/10] 下载镜像（$ReleaseTag）…"
if ($import) {
  if ($useLocalParts) {
    Ok '发现已校验的本地 rootfs 分片，跳过下载。'
  } else {
    # 从 Release 取 SHA256SUMS（新版 Release 才有）。拿不到就只做长度校验并明确警告：
    # 长度对、内容错的分片（例如上一次安装留下的残片）长度校验是发现不了的。
    $shaMap = @{}
    $shaAsset = @($rel.assets | Where-Object { $_.name -ceq 'SHA256SUMS' }) | Select-Object -First 1
    if ($shaAsset) {
      # 临时文件名（不是 SHA256SUMS）：不能覆盖/删除用户放在 InstallDir 里的清单。
      $shaPath = Join-Path $InstallDir '.agent-devbox-SHA256SUMS'
      $shaText = $null
      try {
        Invoke-WebRequest -Uri $shaAsset.browser_download_url -OutFile $shaPath -UseBasicParsing -ErrorAction Stop
        # ReadAllText (not Get-Content -Raw): a 0-byte file must yield '' so the
        # "manifest exists but covers nothing" guard below actually fires.
        $shaText = [System.IO.File]::ReadAllText($shaPath)
      } catch {
        Warn "获取 SHA256SUMS 失败（本次只做长度校验）：$($_.Exception.Message)"
      } finally {
        Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue
      }
      # A manifest that EXISTS must cover every part. A partial manifest would
      # silently downgrade some parts to a length-only check - the exact hole
      # this change exists to close - so it is a hard failure.
      if ($null -ne $shaText) {
        $shaMap = ConvertFrom-Sha256Sums -Text $shaText
        if ($shaMap.Count -eq 0) { throw 'SHA256SUMS 为空或无法解析；拒绝仅按长度校验。' }
        $missing = Get-MissingSha256Parts -ShaMap $shaMap -Names @($parts | ForEach-Object { $_.name })
        if ($missing.Count -gt 0) {
          throw ("SHA256SUMS 未覆盖分片：{0}；拒绝仅按长度校验（该分片可能来自其它版本）。" -f ($missing -join ', '))
        }
        Ok ("已获取 SHA256SUMS（{0} 个分片）。" -f $shaMap.Count)
      }
    } else {
      Warn '该 Release 未提供 SHA256SUMS：本次仅按长度校验，无法发现「长度正确但内容损坏」的分片。'
    }

    foreach ($p in $parts) {
      $dest = Join-Path $InstallDir $p.name
      # Validate the Release metadata BEFORE touching the destination: a
      # zero/null size must never let a zero-length leftover count as done.
      if ([long]$p.size -le 0) {
        throw "Release 资产 '$($p.name)' 缺少有效大小（size），无法校验下载完整性。"
      }
      Write-Host "  $($p.name)"
      # No installer-side "length matches -> skip" shortcut: only Save-Download
      # may decide that a file is usable, and it needs the URL + digest identity.
      # Register the destination BEFORE the download so cleanup can find it
      # even when the download throws.
      $script:PartsDownloaded += $dest
      Save-Download -Url $p.browser_download_url -Dest $dest -ExpectedBytes ([long]$p.size) -Sha256 $shaMap[$p.name] -Connections $Connections
      $local += $dest
    }
  }
} else {
  Ok '跳过下载。'
}

# --- [4/10] 导入镜像（流式 zstd，三级回退）--------------------------------
# 注销旧发行版放在这里：所有分片已下载并通过 SHA256 校验之后、import 之前。
# 放在 [2/10]（下载前）时，下载失败会先把旧系统盘删掉 -> 新系统没有、旧系统也没了。
if ($reinstall) {
  Write-Host "正在注销 '$Distro'（数据盘保留）…"
  Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null
  Warn '旧发行版已注销；若导入失败，已下载分片会保留，重跑安装器校验身份后续传。'
}

Step '[4/10] 导入镜像…'
if ($import) {
  $importParts = if ($useLocalParts) { @($parts | ForEach-Object { $_.FullName }) } else { @($local) }
  $imported = $false
  try {
    # Tier 1：分片直接流式喂给 `wsl --import -`（无 zstd.exe / 合并 / 中间 tar）。
    Write-Host '尝试流式导入（Tier 1）…'
    try {
      $code = Invoke-WslImportStream -Parts $importParts -Distro $Distro -InstallDir $InstallDir
      if ($code -eq 0) {
        $imported = $true
        # 成功也要有一行确认：静默成功让日志无法判断到底走了哪一级回退。
        Ok '流式导入（Tier 1）成功（未使用 zstd.exe / 中间 tar）。'
      } else { Warn "流式导入返回 $code，改用回退方案。" }
    } catch { Warn "流式导入异常：$($_.Exception.Message)" }
    if (-not $imported) {
      try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}
      # 失败的导入会留下 <InstallDir>\ext4.vhdx，挡死后面两层回退。
      if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
        Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
      }
    }

    # Tier 2：合并分片后按文件路径导入（从文件识别压缩，但不识别 stdin）。
    if (-not $imported) {
      Warn '回退 Tier 2：合并分片后按文件导入（会占用额外空间，重新检查）。'
      $need2 = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Merge'
      Assert-DiskSpace -Path $InstallDir -RequiredBytes $need2 | Out-Null
      Join-Parts -Parts $importParts -Dest $stzPath
      $t2out = Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $stzPath)
      if ($script:NativeExit -eq 0) {
        $imported = $true
      } else {
        # 以前这里 | Out-Null，把 WSL 的真实报错全丢了，只剩一个退出码。
        Warn ("Tier 2 导入返回 {0}：{1}" -f $script:NativeExit, (Format-NativeOutput -Output $t2out))
      }
      if (-not $imported) {
        try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}
        if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
          Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
        }
      }
    }

    # Tier 3：用 zstd.exe 解压为 .tar 再导入（仅此路径才可能需要下载 zstd.exe）。
    if (-not $imported) {
      if ($Arch -eq 'arm64') {
        # zstd.exe 只有 win64；不依赖 x64 模拟，也不下载。
        # 内容未被证明损坏：不设 ContentSuspect，保留分片/sidecar 供重试续传。
        try {
          if ((Get-Command Test-WslDistroExists -ErrorAction SilentlyContinue) -and
              (Test-WslDistroExists -Distro $Distro)) {
            Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null
          }
        } catch {}
        if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
          Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
        }
        throw ("ARM64 不提供 Tier 3：zstd.exe 只有 x64 版本，无法在此解压（Tier 1 流式与 Tier 2 文件导入均已失败）。" +
          "旧系统盘（若有）已按升级流程替换，数据盘 data.vhdx 保留；已下载分片保留在 $InstallDir，" +
          "重跑安装器会先校验 SHA256 再重试。若仍失败，请先运行 wsl --update 再重装。")
      }
      Warn '回退 Tier 3：解压为 .tar 再导入。'
      $need3 = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Legacy'
      Assert-DiskSpace -Path $InstallDir -RequiredBytes $need3 | Out-Null
      $zstdExe = Get-ZstdExe -InstallDir $InstallDir
      Join-Parts -Parts $importParts -Dest $stzPath
      $zout = Invoke-Native $zstdExe @('-d', '-f', '-o', $tarPath, $stzPath)
      if ($script:NativeExit -ne 0) {
        $script:ContentSuspect = $true
        throw ("zstd 解压失败（{0}）：{1}`n这说明分片内容已损坏（长度可能正确），已标记为可疑；重跑安装器会重新校验并下载。" -f $script:NativeExit, (Format-NativeOutput -Output $zout))
      }
      $t3out = Invoke-Native 'wsl.exe' @('--import', $Distro, $InstallDir, $tarPath)
      if ($script:NativeExit -ne 0) {
        try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}
        if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
          Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
        }
        throw ("wsl --import 失败（{0}）：{1}" -f $script:NativeExit, (Format-NativeOutput -Output $t3out))
      }
      $imported = $true
    }
  } finally {
    # 合并出的中间文件总是删除。本次下载的分片只在「导入成功」或「内容可疑」时
    # 删除；网络/导入失败则保留分片+sidecar，下次运行重新校验身份后续传。
    $cleanup = Get-ImportCleanupPlan -Attempted $import -Imported $imported -PartsWerePreexisting $partsWerePreexisting -ContentSuspect $script:ContentSuspect
    if ($cleanup.RemoveMerged) {
      Remove-Item -LiteralPath $stzPath -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
    }
    if ($cleanup.RemoveParts) {
      foreach ($lp in $local) {
        if (Get-Command Remove-DownloadArtifacts -ErrorAction SilentlyContinue) { Remove-DownloadArtifacts -Dest $lp }
        else { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue }
      }
    } elseif ($cleanup.KeepParts) {
      Ok ("分片已保留：{0}；重跑安装器会校验身份并续传（无需重新下载）。" -f $InstallDir)
    }
  }
} else {
  Ok '跳过导入。'
}

# --- [5/10] 校验发行版注册 -------------------------------------------------
Step '[5/10] 校验发行版注册…'
if ($import) {
  # -NoLaunch: 此刻还没有数据盘/配置，不能启动发行版（否则启动脚本会写维护模式 MOTD）。
  Assert-DistroReady -Distro $Distro -InstallDir $InstallDir -NoLaunch -UnregisterOnFail | Out-Null
  Ok "发行版 '$Distro' 已注册。"
  # 防御：若镜像里的 [windowsterminal] enabled=false 没有生效，导入时可能又生成一条。
  try {
    Remove-StaleWslTerminalFragments -Distro $Distro | Out-Null
    Write-AgentDevboxTerminalProfile -Distro $Distro -ProfileGuid $v.TerminalGuid -HideGuid $v.HideGuid | Out-Null
  } catch { Warn "刷新 Terminal profile 失败：$($_.Exception.Message)" }
} else {
  Ok '跳过校验。'
}

# --- [6/10] 创建数据磁盘（32GB 动态）--------------------------------------
Step '[6/10] 创建数据磁盘（32GB 动态）…'
if (-not (Test-Path $VhdxPath)) {
  if ($distroExists -and -not (Test-Path -LiteralPath $VhdxPath)) { Warn "升级：安装目录 $InstallDir 下没有 data.vhdx；将新建空数据盘，旧 /home /root /workspace 不会迁移。" }
  Write-Host "正在创建数据磁盘 $VhdxPath（32GB 动态）…"
  $newVhd = Get-Command New-VHD -ErrorAction SilentlyContinue
  $useDiskpart = $false
  if ($newVhd) {
    try {
      New-VHD -Path $VhdxPath -SizeBytes 32GB -Dynamic | Out-Null
    } catch {
      Warn "New-VHD 调用失败：$($_.Exception.Message)；改用 diskpart…"
      $useDiskpart = $true
    }
  } else {
    Warn '未检测到 Hyper-V PowerShell 模块（New-VHD 不可用；Windows 家庭版、或专业版/企业版未启用 Hyper-V 时都会这样）；改用 diskpart…'
    $useDiskpart = $true
  }
  if ($useDiskpart) {
    $dp = @"
create vdisk file="$VhdxPath" maximum=32768 type=expandable
select vdisk file="$VhdxPath"
attach vdisk
"@
    $dpOut = Invoke-Native 'diskpart' @() -InputText $dp
    if ($script:NativeExit -ne 0) { throw "diskpart 创建数据磁盘失败（退出码 $script:NativeExit）：$dpOut" }
    # 分离；真正挂载交给下面的 wsl。
    $detach = @"
select vdisk file="$VhdxPath"
detach vdisk
"@
    $detachOut = Invoke-Native 'diskpart' @() -InputText $detach
    if ($script:NativeExit -ne 0) { throw "diskpart 分离数据磁盘失败（退出码 $script:NativeExit）：$detachOut" }
  }
  $created = $true
} else {
  $created = $false
}
$vhdxItem = Get-Item -LiteralPath $VhdxPath -ErrorAction SilentlyContinue
if (-not $vhdxItem -or $vhdxItem.Length -le 0) { throw "数据磁盘创建后不存在或为空：$VhdxPath" }
if ($created) { Ok "数据磁盘已创建：$VhdxPath" } else { Ok '数据磁盘已存在，保持不变。' }

# --- [7/10] 初始化数据磁盘（bare 挂载 → 初始化 → 取 UUID → 卸载）---------
Step '[7/10] 初始化数据磁盘…'
$earlyAttach = Invoke-Native 'wsl.exe' @('--mount', '--vhd', $VhdxPath, '--bare')
if ($script:NativeExit -ne 0 -and "$earlyAttach" -notmatch 'ALREADY_ATTACHED|already attached|0x80040312|正在使用|已附加') {
  # 不 throw：紧接着的 datadisk-init 会给出真正的失败原因；这里只把附加结果说清楚。
  Warn ("直接附加数据磁盘返回 {0}（已附加视为成功）：{1}" -f $script:NativeExit, $earlyAttach)
}
Start-Sleep -Seconds 2

$expectedMachine = if ($Arch -eq 'arm64') { 'aarch64' } else { 'x86_64' }
# beta 通道的 rootfs 必须带 DATA_LABEL 支持（见 scripts/wsl-boot.sh）：旧镜像的
# wsl-boot.sh 没有 DATA_LABEL，数据盘未附加时会退回共享标签 devbox-data，从而挂到
# 正式通道的数据盘。stable 不加任何内容，探针与今天逐字一致。
$channelBootGuard = if ($Channel -eq 'beta') {
  'grep -q "DATA_LABEL" /usr/local/bin/wsl-boot.sh || { echo "CHANNEL_BOOT_UNSUPPORTED" >&2; exit 43; }; '
} else { '' }
$probe = $channelBootGuard + ('m=$(uname -m); [ "$m" = {0} ] || {{ echo "ARCH_MISMATCH:$m" >&2; exit 42; }}; /usr/local/bin/datadisk-init.sh {1}' -f $expectedMachine, (Quote-Bash $Label))
$initOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', $probe)
$initExit = $script:NativeExit
if ($initExit -ne 0 -and ("$initOut" -match 'ARCH_MISMATCH:(\S+)' -or "$initOut" -match '(?i)exec format error')) {
  $seen = if ("$initOut" -match 'ARCH_MISMATCH:(\S+)') { $Matches[1] } else { '无法执行（Exec format error）' }
  try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}
  if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
    Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
  }
  throw ("导入的 rootfs 架构与主机不匹配：主机 $Arch（期望 $expectedMachine），实际 $seen。" +
    "本次导入已注销；数据盘 data.vhdx 保留。重跑安装器会重新校验/下载所需分片；若反复出现，" +
    "说明该 Release 的 $Arch 分片内容有误（wsl --import 本身不校验架构）。")
}
if ($initExit -eq 43 -or "$initOut" -match 'CHANNEL_BOOT_UNSUPPORTED') {
  # 探针在 datadisk-init 之前就退出，所以这块 rootfs 从未被 mkfs 过。
  try { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null } catch {}
  if (Get-Command Clear-StaleImportArtifacts -ErrorAction SilentlyContinue) {
    Clear-StaleImportArtifacts -Distro $Distro -InstallDir $InstallDir | Out-Null
  }
  throw 'beta 通道需要包含 DATA_LABEL 支持的 rootfs（当前镜像的 /usr/local/bin/wsl-boot.sh 过旧，attach 失败时可能按 devbox-data 挂到正式数据盘）；请用 -ReleaseTag beta 或包含该修复的构建重试。本次导入已注销，data.vhdx 保留。'
}
if ($initExit -ne 0) {
  throw ("数据盘初始化失败（标签 $Label，退出码 $initExit）：无法确认这块 data.vhdx 可以安全地作为 $Channel 通道的数据盘，" +
    "继续下去会把另一个通道的数据盘写进 $ConfPath。data.vhdx 已保留；请检查上面的错误输出后重试，或换一个新的 -InstallDir。")
}
Write-Host $initOut
$uuid = ''
foreach ($line in ($initOut -split "`n")) {
  if ($line -match 'UUID=([0-9a-fA-F-]{36})') { $uuid = $Matches[1] }
}
# 兜底 1：按本通道标签读取 UUID。同一通道（stable = devbox-data / beta =
# devbox-data-beta）的两个变体共用标签，所以把另一变体的 data.vhdx 复制过来也能识别
# （复制盘保留源盘 UUID，与本变体旧 conf 里的 UUID 不同）。多个不同 UUID -> 报错，
# 绝不静默取第一个。
if (-not $uuid) {
  $blkidOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "blkid -t LABEL=$Label -s UUID -o value")
  if ($script:NativeExit -eq 0) {
    $uuids = @($blkidOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -Unique)
    if ($uuids.Count -eq 1) {
      $uuid = $uuids[0]
    } elseif ($uuids.Count -gt 1) {
      throw "数据盘标签 '$Label' 匹配到多个不同的 UUID（$($uuids -join ', ')）：同一通道（$Channel）只应有一块数据盘（stable 用 devbox-data，beta 用 devbox-data-beta），请先断开或删除多余的数据盘，再重试安装。"
    }
  }
}
# 旧 conf 里的 DATA_UUID 只是兜底提示，所以无论前面是否解析成功都读取它（用于下面的
# 变化日志）：同一通道的两个变体数据盘可以互换，复制盘保留源盘 UUID，与本变体旧 conf
# 不同。
# 只接受退出码为 0 且形如 UUID 的结果——Invoke-Native 合并了 stderr，不能把原生
# 进程的报错文本当成 UUID。
$confUuid = ''
$confOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "sed -n 's/^DATA_UUID=//p' $ConfPath 2>/dev/null | tr -d `"'`" | tr -d '\r'")
if ($script:NativeExit -eq 0) {
  $confUuid = ($confOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -First 1)
}
# 兜底 2：标签查询没有结果时，回读上一次安装写入的 DATA_UUID（重装 / 旧版本升级）。
if (-not $uuid -and $confUuid) { $uuid = $confUuid }
if (-not $uuid) { throw '无法确定数据盘 UUID：datadisk-init 与 blkid 都没有返回有效 UUID，数据盘可能未初始化。' }
if ($uuid -and $confUuid -and $uuid -ne $confUuid) {
  Ok "数据盘 UUID 已变化（$confUuid -> $uuid）：按标签 '$Label' 识别，可能是另一个变体的数据盘。"
}

# 密码保存在**数据盘**上（/mnt/<DATA_MNTNAME>/.paseo-password）：数据盘跨升级保留，
# 所以升级镜像不再需要去旧系统盘里翻配置。这里趁磁盘还 attach 着先挂载并读取。
$mountPoint = "/mnt/$MountName"
$pwFile = "$mountPoint/.paseo-password"
$dataDiskPw = ''
$dataDiskMounted = $false
try {
  $mountScript = 'set -e; mkdir -p {0}; dev=$(blkid -U {1}); [ -n "$dev" ] || exit 3; mountpoint -q {0} || mount -t ext4 "$dev" {0}; mountpoint -q {0}' -f $mountPoint, $uuid
  Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', $mountScript) | Out-Null
  $dataDiskMounted = ($script:NativeExit -eq 0)
  if ($dataDiskMounted) {
    $pwOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "cat $pwFile 2>/dev/null || true")
    if ($script:NativeExit -eq 0) {
      $dataDiskPw = ($pwOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 1)
    }
  }
} catch { $dataDiskMounted = $false }

if ($dataDiskMounted) {
  if ($dataDiskPw) { Ok '数据盘上已有 paseo 密码：升级后继续使用同一个密码。' }
  else { Ok "数据盘已挂载：本次设置的密码会保存到数据盘（$pwFile）。" }
} else {
  Warn '数据盘未能挂载：本次仍会完成安装，但密码无法保存到数据盘（下次升级可能需要重新设置）。'
}

# --- [8/10] 修复权限（尽力而为：让非提权的 WSL 用户也能打开该 VHDX）---------
Step '[8/10] 修复权限…'
$RunAsUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if (-not $RunAsUser) { $RunAsUser = "$env:USERDOMAIN\$env:USERNAME" }
Invoke-Native 'icacls.exe' @($VhdxPath, '/setowner', $RunAsUser) | Out-Null
Invoke-Native 'icacls.exe' @($VhdxPath, '/grant', "${RunAsUser}:(F)") | Out-Null
Ok "已尽力修复 $VhdxName 的所有者/ACL（$RunAsUser）。"

# --- paseo 密码（后台服务必填）；写入启动配置 ------------------------------
# 优先级：数据盘上保存的密码（升级的唯一来源）> 交互输入 / 随机生成（仅首次安装）。
$pw = ''
if ($dataDiskPw) {
  $pw = $dataDiskPw
  Ok '沿用数据盘上保存的 paseo 密码（升级不会改变密码）。'
} elseif ($reinstall) {
  # 升级却读不到 = 数据盘没挂上或密码文件被删；不能静默换密码，必须让用户看见。
  Warn '升级未能从数据盘读回 paseo 密码：本次会按新密码处理（旧密码将失效）。'
}
if ([string]::IsNullOrWhiteSpace($pw) -and -not $Yes) {
  $pw = Read-Host 'paseo 密码（直接回车则自动生成随机密码）'
}
if ([string]::IsNullOrWhiteSpace($pw)) {
  $pw = -join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
  Write-Host '已生成随机 paseo 密码（不显示在控制台/日志中）；安装完成后按下方命令查看。'
}

# --- [9/10] 写入启动配置 ---------------------------------------------------
Step '[9/10] 写入启动配置 /etc/agent-devbox.conf…'
$conf = "DATA_VHDX=$(Quote-Bash $VhdxPath)`nDATA_UUID=$(Quote-Bash $uuid)`nDATA_LABEL=$(Quote-Bash $Label)`nPASEO_PASSWORD=$(Quote-Bash $pw)`nDATA_MNTNAME=$(Quote-Bash $MountName)`nDATA_DISTRO=$(Quote-Bash $Distro)`n"
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($conf))
Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "set -o pipefail; umask 077; printf '%s' '$b64' | base64 -d > $ConfPath && chmod 600 $ConfPath") | Out-Null
if ($script:NativeExit -ne 0) { throw "写入 $ConfPath 失败（退出码 $script:NativeExit）" }
Ok "已写入 $ConfPath（UUID=$uuid）"

# 把密码存到数据盘：升级只会替换系统盘，数据盘上的这个文件会原样保留。
if ($dataDiskMounted -and $pw) {
  try {
    $writeScript = 'set -e; umask 077; printf %s {0} > {1}; chmod 600 {1}' -f (Quote-Bash $pw), $pwFile
    Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', $writeScript) | Out-Null
    if ($script:NativeExit -eq 0) { Ok '已把 paseo 密码保存到数据盘（下次升级沿用）。' }
    else { Warn '保存密码到数据盘失败（本次密码仍写入 /etc/agent-devbox.conf）。' }
  } catch { Warn "保存密码到数据盘失败：$($_.Exception.Message)" }
}
# 数据盘必须在上面的读取/写入之后才卸载；重启发行版时由 wsl-boot.sh 自己重新 attach。
if ($dataDiskMounted) {
  Write-Host '正在卸载数据磁盘（开机时会重新挂载）…'
  $umOut = Invoke-Native 'wsl.exe' @('--unmount', "\\?\$VhdxPath")
  if ($script:NativeExit -ne 0) {
    Warn ("卸载数据磁盘返回 {0}（继续安装；[10/10] 会重新附加）：{1}" -f $script:NativeExit, $umOut)
  }
}

# --- [10/10] 附加数据磁盘并清理旧版计划任务 --------------------------------
# 设计：不再注册任何计划任务。boot 是唯一的自动 attach 路径（发行版每次启动时
# wsl-boot.sh 自己 `wsl.exe --mount --vhd ... --bare`）；boot 失败时维护横幅打印
# 安装目录里的 mount-datadisk.cmd。安装器只删除旧版本留下的计划任务，并自己 attach
# 一次（确定性、退出码可见）。
Step '[10/10] 附加数据磁盘并清理旧版计划任务…'

# 旧版本注册过 `agent-devbox*-mount-datadisk`：现在已经没有这种任务，全部删掉。
# 失败只告警，绝不让安装失败（任务注册表可能被策略锁定）。
try {
  foreach ($oldTask in @(Get-ScheduledTask -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^agent-devbox.*-mount-datadisk$' })) {
    try {
      Unregister-ScheduledTask -TaskName $oldTask.TaskName -Confirm:$false -ErrorAction Stop
      Ok ("已删除旧版计划任务 '{0}'" -f $oldTask.TaskName)
    } catch {
      Warn ("删除旧版计划任务 '{0}' 失败（不影响本次安装）：{1}" -f $oldTask.TaskName, $_.Exception.Message)
    }
  }
} catch { Warn "枚举旧版计划任务失败（不影响本次安装）：$($_.Exception.Message)" }

# 立即附加：最多 3 次，间隔 2 秒。attach-only（--bare），由 boot 按 UUID 挂载。
# 失败不阻塞安装（只告警）：重启发行版时 boot 会再试一次；仍失败则按维护横幅运行
# 安装目录里的 mount-datadisk.cmd，再 wsl --terminate。
$attach = ''
for ($i = 1; $i -le 3; $i++) {
  $attach = Invoke-Native 'wsl.exe' @('--mount', '--vhd', $VhdxPath, '--bare')
  if ($script:NativeExit -eq 0 -or "$attach" -match 'already|0x80070020|in use|正在使用|已附加') { break }
  if ($i -lt 3) { Start-Sleep -Seconds 2 }
}
if ($script:NativeExit -eq 0) {
  Ok '数据磁盘已附加（--bare）。'
} elseif ("$attach" -match 'already|0x80070020|in use|正在使用|已附加') {
  Ok '数据磁盘已处于附加状态。'
} else {
  Warn ("附加数据磁盘失败（退出码 {0}）：{1}" -f $script:NativeExit, $attach)
  Warn '重启发行版时 boot 会再试；仍失败请手动修复：'
  Warn "  1) $(Join-Path $InstallDir 'mount-datadisk.cmd')"
  Warn "  2) wsl --terminate $Distro"
}

# --- [完成] 重启发行版并汇总 ----------------------------------------------
Step '[完成] 重启发行版…'
# 重启前的 boot 日志行数：重启后只认「新增」的行，避免把上一次的 boot complete 当成本次成功。
$bootLogPath = '/var/log/agent-devbox-boot.log'
$bootLinesBefore = 0
$lineOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "wc -l < $bootLogPath 2>/dev/null || echo 0")
if ("$lineOut".Trim() -match '^\d+$') { $bootLinesBefore = [int]("$lineOut".Trim()) }
Invoke-Native 'wsl.exe' @('--terminate', $Distro) | Out-Null
$readyOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "echo `"$Distro 已就绪`"; mount | grep -E `"$MountName| /home | /root | /workspace `" || true")
Write-Host $readyOut
Write-Host ''
Assert-DistroReady -Distro $Distro -InstallDir $InstallDir | Out-Null

Assert-DataDiskMounted -Distro $Distro -MountName $MountName -SinceLine $bootLinesBefore -InstallDir $InstallDir | Out-Null
Ok "数据磁盘已挂载到 /mnt/$MountName。"
Assert-PaseoHealthy -Distro $Distro | Out-Null
Ok 'paseo 已就绪（/api/health 200）。' 

# 只读地报告发行版 GUID。**不改用户的默认发行版**（不执行 wsl --set-default）：
# 用户机器上可能还有 Ubuntu 等其它发行版，默认项属于用户设置，安装器无权改。
$distroGuid = ''
try {
  $lxKey = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop |
    Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName -eq $Distro } |
    Select-Object -First 1
  if ($lxKey) { $distroGuid = $lxKey.PSChildName }
} catch { }

Ok '安装完成。'
Ok "变体：$Variant"
Ok "通道=$Channel"
Ok "Release：$ReleaseTag"
Ok "安装目录：$InstallDir"
Ok "进入环境：wsl -d $Distro"
if ($distroGuid) { Ok "发行版 GUID：$distroGuid（每次重装都会换新 GUID）" }
Write-UiLine '若 wsl-ui 打开终端异常：关掉 Windows Terminal 与 wsl-ui 后重开（WT 会按当前注册的发行版重新生成 profile，无需手工改配置）。'
# wsl-ui 的发行版列表是**它自己的 Windows 侧缓存**（%LOCALAPPDATA%\wsl-ui），不在数据盘上。
# 安装器不替用户删其它程序的缓存，只打印一条可复制的命令。
try {
  $uiMeta = Join-Path $env:LOCALAPPDATA 'wsl-ui\distro-metadata.json'
  if (Test-Path -LiteralPath $uiMeta) {
    Write-UiLine "若 wsl-ui 仍显示旧条目：关掉 wsl-ui，运行  Remove-Item `"$uiMeta`" -Force  再重开（那只是它的展示缓存）。"
  }
} catch { }
Write-UiLine 'paseo 网页界面：在打开的 WSL 里启动 paseo 后，浏览器访问 http://localhost:6767（登录密码见 /etc/agent-devbox.conf，下方有查看命令）。'
Write-UiLine '若要修改 paseo 密码：编辑 /etc/agent-devbox.conf，或在启动前设置环境变量 PASEO_PASSWORD。'
Write-Host "安装日志：$script:InstallLog"
Write-Host "查看安装日志：Get-Content -LiteralPath '$script:InstallLog' -Tail 200"
Write-Host "查看 paseo 密码（Windows 侧）：wsl -d $Distro -u root -e cat /etc/agent-devbox.conf"
Write-Host '查看 paseo 密码（WSL 内）：cat /etc/agent-devbox.conf'
Write-Host "查看启动日志：wsl -d $Distro -u root -e tail -n 200 /var/log/agent-devbox-boot.log"
Write-Host "查看 paseo 日志：wsl -d $Distro -u root -e tail -n 200 /var/log/paseo-boot.log"

if (-not $Yes -and [Environment]::UserInteractive) {
  Write-Host '若刚才出现火绒/杀毒软件弹窗，请点击【允许】。本窗口将在 10 秒后自动关闭…'
  Start-Sleep -Seconds 10
}

if ($script:Logging -and $script:RcPath) {
  try { [System.IO.File]::WriteAllText($script:RcPath, '0') } catch {}
}
Save-InstallTranscript
