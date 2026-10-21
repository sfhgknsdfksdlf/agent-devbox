<#
.SYNOPSIS
  agent-devbox Windows 一键安装脚本（WSL2）。

.DESCRIPTION
  - 按变体导入镜像并让两个变体并存：agents 变体导入为 `agent-devbox`，core 变体
    导入为 `agent-devbox-core`（各自独立的发行版名 / 安装目录 / 计划任务名）。
  - 默认安装目录：agents = D:\WSL\agent-devbox，core = D:\WSL\agent-devbox-core。
  - 创建并挂载一块 32GB 动态 VHDX 数据磁盘并初始化。
  - 数据盘的 ext4 标签与挂载名统一为 `devbox-data`（两个变体共用同一标签，同一块
    数据盘在任一发行版下都能识别）。
  - 把数据磁盘接入发行版，使 /home、/root、/workspace 在镜像升级后依然保留。
  - 始终注册一个登录时自动挂载数据磁盘的计划任务（attach-only：只以 `--bare` 接入
    裸磁盘，由发行版启动脚本按 UUID 挂载；命令经 -EncodedCommand 隐藏执行，不弹空白
    `wsl.exe` 控制台窗口，也避免启动脚本被再次触发而重入；可用 -NoTask 跳过）。

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
  [switch] $KeepExisting,
  [switch] $NoTask,
  [string] $LogPath = ''
)

# --- 控制台 UTF-8（尽力而为，失败也不影响运行）------------------------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$env:WSL_UTF8 = '1'

$ErrorActionPreference = 'Stop'
$script:RunStamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:InstallLog  = ''
# 本次运行下载的分片：失败路径（trap / 导入失败）要把它们连同 sidecar 一起删掉，
# 否则下一次运行会把一个坏分片当成「已下载」继续用。
$script:PartsDownloaded = @()
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# 数据盘的 ext4 标签与挂载名：两个变体统一，指向同一块可共用的数据盘。
$Label     = 'devbox-data'
$MountName = 'devbox-data'
$VhdxName  = 'data.vhdx'
$Repo      = 'sfhgknsdfksdlf/agent-devbox'
$ConfPath  = '/etc/agent-devbox.conf'

# 变体映射：只有发行版名 / 安装目录 / 计划任务名按变体区分，数据盘标签与挂载名统一。
# $Variant 选定后（见下方变体选择块）再据此展开为 $Distro / $TaskName。
$VariantMap = @{
  agents = [pscustomobject]@{
    Distro = 'agent-devbox'; InstallDir = 'D:\WSL\agent-devbox'; TaskName = 'agent-devbox-mount-datadisk'
    TerminalGuid = '{6f4a1c2e-8b3d-4a97-9c51-0e7d2b8f3a64}'
    HideGuid     = '{04014822-8112-5520-a687-27d5f19a9da6}'
  }
  core = [pscustomobject]@{
    Distro = 'agent-devbox-core'; InstallDir = 'D:\WSL\agent-devbox-core'; TaskName = 'agent-devbox-core-mount-datadisk'
    TerminalGuid = '{c2d7e9a4-3f61-4b08-8e52-7a1d9c4b6f30}'
    HideGuid     = '{82ea5eb7-e460-5790-9192-d6a59b44f009}'
  }
}

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

# 应用变体映射：按选定变体展开发行版名 / 计划任务名（安装目录在决定安装目录处展开）。
$v        = $VariantMap[$Variant]
$Distro   = $v.Distro
$TaskName = $v.TaskName

# --- 提权一次（UAC）：提权子进程写日志，原窗口等待后回显整份日志 ------------
if (-not (Test-Admin)) {
  # Explorer-extracted scripts may carry Mark-of-the-Web, which RemoteSigned
  # would block; the .bat/.cmd entry points intentionally keep Bypass.
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Variant', $Variant)
  if ($InstallDir) { $argv += @('-InstallDir', "`"$InstallDir`"") }
  if ($ReleaseTag) { $argv += @('-ReleaseTag', $ReleaseTag) }
  if ($Yes)        { $argv += '-Yes' }
  if ($Reinstall)  { $argv += '-Reinstall' }
  if ($NoTask)     { $argv += '-NoTask' }

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
  }
}

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
  # 失败时删掉本次下载的分片与 sidecar：绝不能让一个坏分片在下一次运行里被当成
  # 「已下载/可续传」继续用（那正是「长度对、内容错、三级全败」的成因）。
  try {
    foreach ($p in @($script:PartsDownloaded)) {
      if (Get-Command Remove-DownloadArtifacts -ErrorAction SilentlyContinue) { Remove-DownloadArtifacts -Dest $p }
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
  Set-MirroredNetworking -Yes:$Yes
} else {
  Write-Warning '未找到 wsl-ensure.ps1；已跳过 WSL/网络预检查（install.ps1 应把它从 main 取回；请检查网络与源码分支）。'
}

# --- 决定安装目录 -----------------------------------------------------------
if (-not $InstallDir) {
  $default = $VariantMap[$Variant].InstallDir
  if ($Yes) {
    $InstallDir = $default
  } else {
    $answer = Read-Host "安装目录 [$default]（直接回车使用默认值）"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer }
  }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
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
foreach ($helper in @('mount-datadisk.ps1', 'mount-datadisk.cmd', 'unmount-datadisk.ps1', 'unmount-datadisk.cmd')) {
  $helperSrc = Join-Path $PSScriptRoot $helper
  if (Test-Path -LiteralPath $helperSrc) {
    Copy-Item -LiteralPath $helperSrc -Destination (Join-Path $InstallDir $helper) -Force
  } else {
    Warn "未找到 $helper（跳过复制到安装目录）。"
  }
}
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

# --- 是否覆盖已存在的发行版？（默认直接覆盖升级，不再要求输入 y）----------
# 延迟注销：等磁盘预检通过后再注销旧发行版，避免空间不足时先删掉可用的发行版。
# 升级 = 换系统盘，但数据盘（/home /root /workspace）和 paseo 密码都保留。
$distroExists = Test-DistroExists
$import = $true
if ($distroExists) {
  if ($KeepExisting) {
    $import = $false
    Ok "发行版 '$Distro' 已存在：按 -KeepExisting 保留现有安装（不升级）。"
  } else {
    Warn "发行版 '$Distro' 已存在：直接覆盖升级（数据盘保留，paseo 密码沿用）。"
  }
}
$reinstall = $distroExists -and $import

# 升级不再去旧系统盘读密码。密码的权威位置是数据盘上的 `.paseo-password`（[7/10] 按 UUID
# 挂载后读取，跨升级保留）；2026-10-20 01:13 起的所有安装都有这个文件。
# 去掉这一步是为了不再为 `cat` 一个文件把旧发行版整机拉起（[boot] 会顺带 mount 数据盘 +
# 启动 paseo），也就不会出现「升级刚开始 paseo 被拉起来、1 分钟后又被 terminate」。

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
    throw '缺少 wsl-ensure.ps1 中的磁盘检查辅助函数；请确认 install.ps1 已从 main 取回全部脚本后重试。'
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
  Assert-DiskSpace -Path $InstallDir -RequiredBytes $needBytes | Out-Null
  Ok ("磁盘空间充足（需要约 {0:N1} GiB）。" -f ($needBytes / 1073741824.0))
} else {
  Ok '发行版已存在，跳过。'
}

# --- [3/10] 下载镜像 -------------------------------------------------------
Step "[3/10] 下载镜像（$ReleaseTag）…"
if ($import) {
  if ($localParts.Count -gt 0) {
    Ok '发现本地 rootfs 分片，跳过下载。'
  } else {
    # 从 Release 取 SHA256SUMS（新版 Release 才有）。拿不到就只做长度校验并明确警告：
    # 长度对、内容错的分片（例如上一次安装留下的残片）长度校验是发现不了的。
    $shaMap = @{}
    $shaAsset = @($rel.assets | Where-Object { $_.name -ceq 'SHA256SUMS' }) | Select-Object -First 1
    if ($shaAsset) {
      $shaPath = Join-Path $InstallDir 'SHA256SUMS'
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
      # Register the destination BEFORE the download so a throw inside
      # Save-Download still gets cleaned up by the trap.
      $script:PartsDownloaded += $dest
      Save-Download -Url $p.browser_download_url -Dest $dest -ExpectedBytes ([long]$p.size) -Sha256 $shaMap[$p.name]
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
  Warn '旧发行版已注销；若随后导入失败，分片已保留在安装目录，重跑安装器不会重新下载。'
}

Step '[4/10] 导入镜像…'
if ($import) {
  $importParts = if ($localParts.Count -gt 0) { @($parts | ForEach-Object { $_.FullName }) } else { @($local) }
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
      Warn '回退 Tier 3：解压为 .tar 再导入。'
      $need3 = Get-RequiredDiskBytes -CompressedBytes $compressed -UncompressedBytes $uncomp -Tier 'Legacy'
      Assert-DiskSpace -Path $InstallDir -RequiredBytes $need3 | Out-Null
      $zstdExe = Get-ZstdExe -InstallDir $InstallDir
      Join-Parts -Parts $importParts -Dest $stzPath
      $zout = Invoke-Native $zstdExe @('-d', '-f', '-o', $tarPath, $stzPath)
      if ($script:NativeExit -ne 0) {
        throw ("zstd 解压失败（{0}）：{1}`n这说明分片内容已损坏（长度可能正确），本次下载的分片已删除，请重新运行安装器。" -f $script:NativeExit, (Format-NativeOutput -Output $zout))
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
    # 成功或失败都清理：合并的 .zst、中间 .tar、以及本次下载的分片（保留仓库预置分片）。
    Remove-Item -LiteralPath $stzPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
    if ($localParts.Count -eq 0) {
      foreach ($lp in $local) {
        if (Get-Command Remove-DownloadArtifacts -ErrorAction SilentlyContinue) { Remove-DownloadArtifacts -Dest $lp }
        else { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue }
      }
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
Invoke-Native 'wsl.exe' @('--mount', '--vhd', $VhdxPath, '--bare') | Out-Null
Start-Sleep -Seconds 2

$initOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "/usr/local/bin/datadisk-init.sh $(Quote-Bash $Label)")
Write-Host $initOut
$uuid = ''
foreach ($line in ($initOut -split "`n")) {
  if ($line -match 'UUID=([0-9a-fA-F-]{36})') { $uuid = $Matches[1] }
}
# 兜底 1（可选）：回读上一次安装写入的 DATA_UUID（重装 / 数据盘已初始化的场景）。
# 只接受退出码为 0 且形如 UUID 的结果——Invoke-Native 合并了 stderr，不能把原生
# 进程的报错文本当成 UUID。
if (-not $uuid) {
  $confOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "sed -n 's/^DATA_UUID=//p' $ConfPath 2>/dev/null | tr -d `"'`" | tr -d '\r'")
  if ($script:NativeExit -eq 0) {
    $uuid = ($confOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -First 1)
  }
}
# 兜底 2：按标签读取 UUID。两个变体（agents / core）的数据盘共用同一标签 `devbox-data`，
# 因此可能匹配到多个不同 UUID —— 此时必须报错，绝不静默取第一个。
if (-not $uuid) {
  $blkidOut = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "blkid -t LABEL=$Label -s UUID -o value")
  if ($script:NativeExit -eq 0) {
    $uuids = @($blkidOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -Unique)
    if ($uuids.Count -eq 1) {
      $uuid = $uuids[0]
    } elseif ($uuids.Count -gt 1) {
      throw "数据盘标签 '$Label' 匹配到多个不同的 UUID（$($uuids -join ', ')）：agents / core 两个变体共用同一标签，请先断开或删除多余的数据盘，再重试安装。"
    }
  }
}
if (-not $uuid) { throw '无法确定数据盘 UUID：datadisk-init 与 blkid 都没有返回有效 UUID，数据盘可能未初始化。' }

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
$conf = "DATA_VHDX=$(Quote-Bash $VhdxPath)`nDATA_UUID=$(Quote-Bash $uuid)`nPASEO_PASSWORD=$(Quote-Bash $pw)`nDATA_MNTNAME=$(Quote-Bash $MountName)`nDATA_TASK=$(Quote-Bash $TaskName)`n"
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
# 数据盘必须在上面的读取/写入之后才卸载；开机由计划任务重新 attach。
if ($dataDiskMounted) {
  Write-Host '正在卸载数据磁盘（开机时会重新挂载）…'
  $umOut = Invoke-Native 'wsl.exe' @('--unmount', "\\?\$VhdxPath")
  if ($script:NativeExit -ne 0) {
    Warn ("卸载数据磁盘返回 {0}（继续安装；[10/10] 会重新附加）：{1}" -f $script:NativeExit, $umOut)
  }
}

# --- [10/10] 注册开机自动挂载计划任务（默认始终注册；-NoTask 可跳过）------
Step '[10/10] 注册开机自动挂载计划任务…'
if ($NoTask) {
  Ok '已跳过计划任务注册'
} else {
  # attach-only：只把 VHDX 作为裸磁盘接入（--bare），不指定文件系统类型 / 挂载名，
  # 由发行版启动脚本按 UUID 自行挂载。任务调用安装目录里的 mount-datadisk.ps1：
  # 它会重试 3 次、把每次 `wsl --mount` 的退出码写进 datadisk-attach.log，并用
  # `exit $result.ExitCode` 把真实结果回给计划任务。直接 -EncodedCommand "& wsl.exe ..."
  # 时 PowerShell 永远退出 0，安装器会把 attach 失败误判为成功（2026-10-21 维护模式）。
  $attachScript = Join-Path $InstallDir 'mount-datadisk.ps1'
  $actionArgs   = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$attachScript`""
  $action     = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
  $trigger    = New-ScheduledTaskTrigger -AtLogOn
  $principal  = New-ScheduledTaskPrincipal -UserId $RunAsUser -RunLevel Highest
  # 电池开关必须显式打开：New-ScheduledTaskSettingsSet 的默认值是
  # DisallowStartIfOnBatteries=$true / StopIfGoingOnBatteries=$true。笔记本拔电登录时
  # 任务根本不跑 -> 数据盘没附加 -> wsl-boot 等 30 秒后进维护模式（台式机看不出来）。
  $settings   = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
                  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

  # 幂等：任务已存在且「动作 / 触发 / 身份 / 并发设置」都一致时不再重复注册。
  # 之前每次安装都先 Unregister 再 Register，等于每次都重写一遍计划任务注册表，毫无必要。
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $needRegister = $true
  if ($existingTask) {
    $same = $false
    try {
      $ea = @($existingTask.Actions) | Select-Object -First 1
      $et = @($existingTask.Triggers) | Select-Object -First 1
      $ep = $existingTask.Principal
      $sameAction    = $ea -and ("$($ea.Execute)" -match 'powershell') -and ("$($ea.Arguments)" -ceq $actionArgs)
      $sameTrigger   = $et -and ("$($et.CimClass.CimClassName)" -eq 'MSFT_TaskLogonTrigger')
      $samePrincipal = $ep -and ("$($ep.UserId)" -eq $RunAsUser) -and ("$($ep.RunLevel)" -eq 'Highest')
      # 设置一致性必须把电池策略也比进来：旧安装器没传两个开关，落到默认的
      # DisallowStartIfOnBatteries/StopIfGoingOnBatteries=$true；只比 MultipleInstances 的话
      # 这里会误判“一致”，已装机器永远修不到电池问题。
      $st = $existingTask.Settings
      $sameSettings  = ("$($st.MultipleInstances)" -eq 'IgnoreNew') -and
                       ($st.DisallowStartIfOnBatteries -eq $false) -and
                       ($st.StopIfGoingOnBatteries -eq $false)
      $same = [bool]($sameAction -and $sameTrigger -and $samePrincipal -and $sameSettings)
    } catch { $same = $false }
    if ($same) {
      $needRegister = $false
      Ok "计划任务 '$TaskName' 已存在且配置一致，跳过重复注册。"
    } else {
      Warn "计划任务 '$TaskName' 已存在但配置与当前安装不一致，重新注册。"
    }
  }

  if ($needRegister) {
    if ($existingTask) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    Warn '如果火绒 / 360 / Defender 弹出“允许/阻止”提示，请点击【允许】；本步骤只注册一个隐藏的登录挂载任务。'
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
      -Description "$Distro：登录时自动挂载数据磁盘" | Out-Null
  }
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  if (-not $task -or $task.State -eq 'Disabled') { throw "计划任务 '$TaskName' 注册后不可用。" }
  $act = @($task.Actions) | Select-Object -First 1
  if (-not $act -or $act.Execute -notmatch 'powershell' -or $act.Arguments -notmatch 'mount-datadisk\.ps1') { throw "计划任务 '$TaskName' 的动作不符合预期。" }
  if ($needRegister) { Ok "已注册并校验计划任务 '$TaskName'。" } else { Ok "已校验计划任务 '$TaskName'（未重复注册）。" }
  # 变体卸载/切换后旧任务会残留（任务名里带变体名），登录时仍去 attach 一个已经没有发行版的
  # 数据盘；旧式 `--mount --type ext4 --name` 还会把盘挂到所有发行版都看得见的 /mnt/wsl/<name>
  # （wsl-boot.sh 注释里警告过的共享挂载点）。这里只清理两类可判定的残留：发行版已不在
  # `wsl -l` 里，或任务指向的 VHDX 已不存在。当前任务和其它仍存活的变体一律不动。
  try {
    $liveDistros = @()
    $listed = Invoke-Native 'wsl.exe' @('-l', '-q')
    if ($script:NativeExit -eq 0) {
      $liveDistros = @($listed | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
    }
    foreach ($staleTask in @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match '^agent-devbox.*-mount-datadisk$' })) {
      if ($staleTask.TaskName -eq $TaskName) { continue }
      $staleDistro = $staleTask.TaskName -replace '-mount-datadisk$', ''
      $staleVhd = ''
      $staleAction = @($staleTask.Actions) | Select-Object -First 1
      if ($staleAction -and ("$($staleAction.Arguments)" -match '--vhd\s+["'']?([^"'']+)')) { $staleVhd = $matches[1] }
      $distroGone = ($liveDistros.Count -gt 0) -and ($liveDistros -notcontains $staleDistro)
      $vhdGone = [bool]($staleVhd -and -not (Test-Path -LiteralPath $staleVhd))
      if ($distroGone -or $vhdGone) {
        Unregister-ScheduledTask -TaskName $staleTask.TaskName -Confirm:$false -ErrorAction Stop
        Ok ("已清理残留计划任务 '{0}'（发行版 '{1}' 已不存在）" -f $staleTask.TaskName, $staleDistro)
        # 注销任务不会 detach 它挂过的盘（旧式 --mount 还会把它挂到 /mnt/wsl/<name>，
        # 所有发行版都看得见）。这里顺手分离，失败只告警（重启后自然消失）。
        if ($staleVhd -and -not $vhdGone) {
          Invoke-Native 'wsl.exe' @('--unmount', "\\?\$staleVhd") | Out-Null
          if ($script:NativeExit -eq 0) { Ok ("已分离残留数据盘：{0}" -f $staleVhd) }
          else { Warn ("残留数据盘未能分离（重启 Windows 后自动消失）：{0}" -f $staleVhd) }
        }
      }
    }
  } catch { Warn "清理残留挂载任务失败（不影响本次安装）：$($_.Exception.Message)" }
}

# 立即附加：安装器本身就是管理员，先自己挂一次（确定性、退出码可见），失败了才
# 交给计划任务重试。只靠 Start-ScheduledTask 时，wsl --mount 的失败会被吞掉，
# 重启后 wsl-boot 找不到设备 -> 维护模式（2026-10-21 core 实测）。
$attach = Invoke-Native 'wsl.exe' @('--mount', '--vhd', $VhdxPath, '--bare')
if ($script:NativeExit -eq 0) {
  Ok '数据磁盘已附加（--bare）。'
} elseif ("$attach" -match 'already|0x80070020|in use|正在使用|已附加') {
  Ok '数据磁盘已处于附加状态。'
} else {
  Warn "直接附加数据磁盘返回 $($script:NativeExit)；改由计划任务重试：$attach"
  try {
    Warn '若火绒/杀毒软件此刻弹出提示，请点击【允许】。'
    Start-ScheduledTask -TaskName $TaskName | Out-Null
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info -and [int]$info.LastTaskResult -ne 0) {
      Warn ("计划任务首次运行返回 0x{0:X}；若火绒/杀毒软件弹窗请点击允许。" -f [int]$info.LastTaskResult)
    }
  } catch {
    Warn "立即触发计划任务失败（下次登录仍会自动挂载）：$($_.Exception.Message)"
  }
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

Assert-DataDiskMounted -Distro $Distro -MountName $MountName -SinceLine $bootLinesBefore | Out-Null
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

Ok "安装完成。变体=$Variant  Release=$ReleaseTag  安装目录=$InstallDir"
Write-Host "进入环境：wsl -d $Distro"
if ($distroGuid) { Write-Host "发行版 GUID：$distroGuid（每次重装都会换新 GUID）" }
Write-Host '若 wsl-ui 打开终端异常，关掉 Windows Terminal 与 wsl-ui 后重开（WT 会按当前注册的发行版重新生成 profile，无需手工改配置）。'
# wsl-ui 的发行版列表是**它自己的 Windows 侧缓存**（%LOCALAPPDATA%\wsl-ui），不在数据盘上。
# 安装器不替用户删其它程序的缓存，只打印一条可复制的命令。
try {
  $uiMeta = Join-Path $env:LOCALAPPDATA 'wsl-ui\distro-metadata.json'
  if (Test-Path -LiteralPath $uiMeta) {
    Write-Host "若 wsl-ui 仍显示旧条目：关掉 wsl-ui，运行  Remove-Item `"$uiMeta`" -Force  再重开（那只是它的展示缓存）。"
  }
} catch { }
Write-Host 'paseo 网页界面：在打开的 WSL 里启动 paseo 后，浏览器访问 http://localhost:6767（登录密码见 /etc/agent-devbox.conf，下方有查看命令）。'
Write-Host '若要修改 paseo 密码：编辑 /etc/agent-devbox.conf，或在启动前设置环境变量 PASEO_PASSWORD。'
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
