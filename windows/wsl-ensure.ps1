<#
.SYNOPSIS
  Shared WSL preflight helpers for the agent-devbox Windows installers.

.DESCRIPTION
  Dot-source-safe: this file has NO param() block and runs NO code on load, so
  `. .\wsl-ensure.ps1` defines the functions without any side effects.

  Exposes:
    Test-WslInstalled    - is a functional WSL present? (no interactive block)
    Ensure-Wsl           - install WSL if missing (asks base-only vs base+wsl-ui)
    Get-AgentDevboxDownloadHelperPath - locate the lazily loaded download helper
                           (wsl-ensure-downloads.ps1: Install-WslUi, Get-ZstdExeFromRelease)
    Get-WslNetworkingMode- read the active networking mode
    Set-MirroredNetworking - switch .wslconfig [wsl2] networkingMode=mirrored

.NOTES
  Detection uses `wsl.exe --status` (fast, non-interactive). NEVER `wsl --version`
  (it blocks interactively when WSL is missing) and never `Get-Command wsl`
  (the System32 stub always exists even when WSL is not installed).
#>

# Location of the sibling, lazily loaded download helper. Recorded from this
# file (not the caller's $PSScriptRoot) so `Get-AgentDevboxDownloadHelperPath`
# works no matter which script dot-sourced us.
$script:AgentDevboxEnsureDir = $PSScriptRoot

function Test-WslInstalled {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  # UTF-8 output so we can parse wsl.exe reliably (avoids UTF-16).
  $env:WSL_UTF8 = '1'
  try {
    wsl.exe --status *> $null 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Ensure-Wsl {
  [CmdletBinding()]
  param([switch] $Yes)

  $ErrorActionPreference = 'Stop'

  # Idempotent: WSL already present -> do nothing, let the caller continue.
  if (Test-WslInstalled) { return 'ok' }

  # WSL is missing: base WSL only, or base WSL + the wsl-ui desktop GUI (default).
  $withUi = $true
  if (-not $Yes) {
    $sel = Read-Host '尚未安装 WSL。安装 [1] 仅基础 WSL，或 [2] 基础 WSL + wsl-ui 图形界面？[回车 = 2]'
    $withUi = -not ($sel -match '^\s*1\s*$')
  }

  Write-Host '正在安装 WSL（可能弹出控制台窗口，请稍候）…'
  # NOTE: deliberately NO -NoNewWindow: wsl --install needs an interactive console.
  $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Wait -PassThru

  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1641) {
    throw "wsl --install 失败（退出码 $($p.ExitCode)）"
  }

  # wsl-ui only needs installing (not a booted WSL), so install it even when a
  # reboot is still pending; a failure here must not abort the whole install.
  if ($withUi) {
    try {
      . (Get-AgentDevboxDownloadHelperPath)
      Install-WslUi
    } catch {
      Write-Warning "wsl-ui 未安装：$($_.Exception.Message)"
      Write-Warning '你可以稍后从 https://github.com/octasoft-ltd/wsl-ui/releases 重新安装。'
    }
  }

  if ($p.ExitCode -ne 0) {
    Write-Host '需要重启 Windows 后重新运行。'
    return 'reboot-required'
  }
  return 'ok'
}

function Get-WslNetworkingMode {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  $env:WSL_UTF8 = '1'
  try {
    $mode = (wsl.exe -e wslinfo --networking-mode 2> $null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mode)) { return 'unknown' }
    return $mode
  } catch {
    return 'unknown'
  }
}


function Restart-WslAfterConfigChange {
  [CmdletBinding()]
  param([switch] $Unattended)

  if ($Unattended) {
    Write-Host '已写入 .wslconfig；本次是无人值守运行，不会重启 WSL，配置将在 WSL VM 下次启动后生效。'
    return
  }

  Write-Host ''
  Write-Host '镜像网络是 [wsl2] 的 VM 级配置，必须重启 WSL 才会生效。' -ForegroundColor Yellow
  Write-Host '注意：wsl --shutdown 会关闭所有正在运行的 WSL 发行版（Docker、其它终端/编辑器里的 WSL 会话都会断开）。' -ForegroundColor Yellow
  $ans = Read-Host '现在执行 wsl --shutdown 吗？[y/N]（回车 = 否）'
  if (-not (Resolve-YesNoDefault -Answer $ans -DefaultYes $false)) {
    Write-Host '已跳过：下次 Windows 重启或你手动执行 wsl --shutdown 后生效。'
    return
  }
  Invoke-Native 'wsl.exe' @('--shutdown') | Out-Null
  if ($script:NativeExit -eq 0) {
    Write-Host '已执行 wsl --shutdown，镜像网络将在下次启动时生效。' -ForegroundColor Green
  } else {
    Write-Host "wsl --shutdown 返回 $($script:NativeExit)；配置已写入，下次重启后生效。" -ForegroundColor Yellow
  }
}

function Set-MirroredNetworking {
  [CmdletBinding()]
  param([switch] $Yes)

  $ErrorActionPreference = 'Stop'

  $cfg = Join-Path $env:USERPROFILE '.wslconfig'

  $live = Get-WslNetworkingMode
  $configured = $false
  if (Test-Path -LiteralPath $cfg) {
    $inWsl2 = $false
    foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
      $t = $line.Trim()
      if ($t -match '^\[(.+)\]$') { $inWsl2 = ($Matches[1] -ieq 'wsl2') }
      elseif ($inWsl2 -and $t -match '^networkingMode\s*=\s*mirrored\s*$') { $configured = $true; break }
    }
  }
  if ($live -eq 'mirrored') {
    Write-Host '镜像网络已开启。'
    return $false
  }
  if ($configured -and $live -eq 'nat') {
    Write-Host '.wslconfig 已配置镜像网络，但当前 WSL 仍是 NAT 模式（需要重启 WSL 才生效）。'
    Restart-WslAfterConfigChange -Unattended:$Yes
    return $true
  }
  if ($configured) {
    Write-Host '镜像网络已配置（WSL 启动后生效）。'
    return $false
  }

  if (-not $Yes) {
    $ans = Read-Host '建议开启镜像网络（对 VPN / 手机访问更友好）。现在切换？[Y/n]（回车 = 是）'
    if ($ans -match '^(n|no)$') {
      Write-Host '已跳过。'
      return $false
    }
  }

  # Back up once (never overwrite an existing backup).
  if (Test-Path -LiteralPath $cfg) {
    $bak = "$cfg.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
      Copy-Item -LiteralPath $cfg -Destination $bak -Force
    }
  }

  $lines = @()
  if (Test-Path -LiteralPath $cfg) {
    $lines = @([System.IO.File]::ReadAllLines($cfg))
  }

  # Locate the [wsl2] section (case-insensitive), if any.
  $secStart = -1
  $secEnd = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -match '^\[wsl2\]$') {
      $secStart = $i
      for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j].Trim() -match '^\[') { $secEnd = $j; break }
      }
      break
    }
  }

  $out = New-Object System.Collections.Generic.List[string]
  $out.AddRange([string[]]$lines)

  if ($secStart -lt 0) {
    # No [wsl2] section: append one.
    if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
    $out.Add('[wsl2]')
    $out.Add('networkingMode=mirrored')
  } else {
    # Find an existing networkingMode= key inside [wsl2].
    $keyIdx = -1
    for ($k = $secStart + 1; $k -lt $secEnd; $k++) {
      if ($out[$k].Trim() -match '^networkingMode\s*=') { $keyIdx = $k; break }
    }
    if ($keyIdx -ge 0) {
      $out[$keyIdx] = 'networkingMode=mirrored'
    } else {
      $out.Insert($secEnd, 'networkingMode=mirrored')
    }
  }

  # UTF-8 without BOM; one line per element (preserves every other line's content).
  [System.IO.File]::WriteAllLines($cfg, $out, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host '已写入 .wslconfig：networkingMode=mirrored。若使用 VPN，请确保 VPN 允许访问本地网络。'
  Restart-WslAfterConfigChange -Unattended:$Yes
  return $true
}

# ===========================================================================
# Installer shared helpers (dot-source-safe: definitions only, no side effects).
# ===========================================================================

# Resolve the lazily loaded download-and-execute helper next to this file. It is
# never dot-sourced at load time: the happy path (WSL present, Tier 1 streaming
# import) needs none of its primitives, so the download/execute shape stays out
# of the always-loaded working file. Throws a clear Chinese error when the
# sibling script was not fetched from `main`.
function Get-AgentDevboxDownloadHelperPath {
  [CmdletBinding()]
  param()
  $path = Join-Path $script:AgentDevboxEnsureDir 'wsl-ensure-downloads.ps1'
  if (-not (Test-Path -LiteralPath $path)) {
    throw ('缺少 wsl-ensure-downloads.ps1（安装脚本已取回，多半是杀毒软件把它隔离了）：' +
      '把 %LOCALAPPDATA%\agent-devbox 加入信任区后重试；只想用 wsl-ui 的话也可以从 ' +
      'https://github.com/octasoft-ltd/wsl-ui/releases 手动安装。')
  }
  return $path
}

# Run a native command with stderr merged into the output while locally relaxing
# $ErrorActionPreference: with 'Stop', PowerShell 5.1 can turn a native command's
# stderr (mkfs/zstd progress, icacls errors) into a terminating error. The exit
# code is left in $script:NativeExit. Shared by every installer script.
function Invoke-Native {
  param([Parameter(Mandatory)][string] $FilePath, [string[]] $Arguments = @(), [string] $InputText = $null)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $script:NativeExit = -1
    if ($null -ne $InputText) {
      $out = $InputText | & $FilePath @Arguments 2>&1
    } else {
      $out = & $FilePath @Arguments 2>&1
    }
    $script:NativeExit = $LASTEXITCODE
    return $out
  } finally {
    $ErrorActionPreference = $prev
  }
}

# Map a raw version selection to a release-tag input:
#   'b' | 'beta'    -> 'beta'   (sentinel; the caller resolves it via the GitHub API)
#   'YYYYMMDD.HHMM' -> 'build-YYYYMMDD.HHMM'
#   anything else   -> unchanged
function Normalize-ReleaseTag {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string] $Sel)
  $s = "$Sel".Trim()
  if ($s -match '^(b|beta)$') { return 'beta' }
  if ($s -match '^\d{8}\.\d{4}$') { return "build-$s" }
  return $s
}

# Interpret a yes/no answer where Enter takes the caller-supplied default.
function Resolve-YesNoDefault {
  [CmdletBinding()]
  param([AllowEmptyString()][string] $Answer = '', [bool] $DefaultYes = $true)
  $a = "$Answer".Trim()
  if ([string]::IsNullOrWhiteSpace($a)) { return $DefaultYes }
  if ($a -match '^(?i:n|no)$') { return $false }
  if ($a -match '^(?i:y|yes)$') { return $true }
  return $DefaultYes
}

# Does the system `tar.exe` advertise zstd support? The version banner lists the
# compression libraries compiled in; `libzstd` present <=> native zstd works.
# (Win11 22H2+/patched builds have it; Win10 and Win11 21H2 do not.)
function Test-ZstdBanner {
  [CmdletBinding()]
  param([AllowEmptyString()][string] $Text = '')
  return ("$Text" -match '(?i)libzstd')
}

function Get-NativeZstdSupport {
  [CmdletBinding()]
  param()
  $ErrorActionPreference = 'Stop'
  try {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { $tar = 'tar.exe' }
    $out = & $tar --version 2>&1 | Out-String
    return (Test-ZstdBanner $out)
  } catch {
    return $false
  }
}

# Quote a single argument for a native Windows command line (no cmd.exe string
# building - just argv quoting). Safe for paths with spaces.
function Quote-NativeArg {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string] $Arg)
  $s = $Arg -replace '(\\*)"', '$1$1\"'
  $s = $s -replace '(\\+)$', '$1$1'
  return '"' + $s + '"'
}

# Reassemble ordered parts into one file as a raw byte stream.
function Join-Parts {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string[]] $Parts, [Parameter(Mandatory)][string] $Dest)
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
  $out = [System.IO.File]::Create($Dest)
  try {
    foreach ($p in $Parts) {
      $in = [System.IO.File]::OpenRead($p)
      try { $in.CopyTo($out) } finally { $in.Dispose() }
    }
  } finally { $out.Dispose() }
}

# Free bytes available to the current user on the volume that holds $Path.
# Managed System.IO.DriveInfo only (no Add-Type / P/Invoke); walks up to the
# nearest existing parent. $Override is a test hook.
function Get-FreeDiskSpaceBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path, [Nullable[long]] $Override = $null)
  if ($null -ne $Override) { return [long]$Override }

  $full = [System.IO.Path]::GetFullPath($Path)
  try {
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
      $parent = [System.IO.Path]::GetDirectoryName($probe)
      if ([string]::IsNullOrEmpty($parent) -or $parent -eq $probe) { break }
      $probe = $parent
    }
    return [long]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($probe))).AvailableFreeSpace
  } catch {
    return [long]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($full))).AvailableFreeSpace
  }
}

# Parse the uncompressed size out of a zstd frame header (RFC 8878). Returns
# $null when the frame carries no Frame_Content_Size or the bytes are not zstd.
function Get-ZstdUncompressedSizeFromBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][byte[]] $Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -lt 6) { return $null }
  if (-not ($Bytes[0] -eq 0x28 -and $Bytes[1] -eq 0xB5 -and $Bytes[2] -eq 0x2F -and $Bytes[3] -eq 0xFD)) { return $null }
  $fhd       = [int]$Bytes[4]
  $fcsFlag   = ($fhd -shr 6) -band 0x3
  $singleSeg = (($fhd -shr 5) -band 0x1) -eq 1
  $dictFlag  = $fhd -band 0x3
  $off = 5
  if (-not $singleSeg) { $off += 1 }               # Window_Descriptor
  if     ($dictFlag -eq 1) { $off += 1 }
  elseif ($dictFlag -eq 2) { $off += 2 }
  elseif ($dictFlag -eq 3) { $off += 4 }
  try {
    switch ($fcsFlag) {
      0 {
        if ($singleSeg) { if ($Bytes.Length -lt ($off + 1)) { return $null }; return [long]$Bytes[$off] }
        return $null
      }
      1 { if ($Bytes.Length -lt ($off + 2)) { return $null }; return [long]([BitConverter]::ToUInt16($Bytes, $off)) + 256 }
      2 { if ($Bytes.Length -lt ($off + 4)) { return $null }; return [long]([BitConverter]::ToUInt32($Bytes, $off)) }
      3 { if ($Bytes.Length -lt ($off + 8)) { return $null }; return [long]([BitConverter]::ToUInt64($Bytes, $off)) }
    }
  } catch { return $null }
  return $null
}

# Read the zstd frame header from a local file (e.g. part-00).
function Get-ZstdUncompressedSize {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $fs = [System.IO.File]::OpenRead($Path)
  try {
    $buf = New-Object byte[] 18
    $n = $fs.Read($buf, 0, $buf.Length)
    if ($n -le 0) { return $null }
    if ($n -lt $buf.Length) { $buf = $buf[0..($n - 1)] }
    return (Get-ZstdUncompressedSizeFromBytes $buf)
  } finally { $fs.Dispose() }
}

# Read the first bytes of a remote part via a managed HttpClient range request;
# never buffers the body (ResponseHeadersRead) and parses the frame header.
# Returns $null on failure.
function Get-ZstdUncompressedSizeFromUrl {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Url)
  $ErrorActionPreference = 'Stop'
  $client = $null
  $req = $null
  $resp = $null
  try {
    if (-not ('System.Net.Http.HttpClient' -as [type])) {
      Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('agent-devbox-installer')
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 17)
    # ResponseHeadersRead: if a server ignores Range, we read 18 bytes and
    # dispose instead of buffering the whole multi-GB part.
    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { return $null }
    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    try {
      $buf = New-Object byte[] 18
      $read = 0
      while ($read -lt $buf.Length) {
        $n = $stream.Read($buf, $read, $buf.Length - $read)
        if ($n -le 0) { break }
        $read += $n
      }
      if ($read -le 0) { return $null }
      if ($read -lt $buf.Length) { $buf = $buf[0..($read - 1)] }
      return (Get-ZstdUncompressedSizeFromBytes $buf)
    } finally { $stream.Dispose() }
  } catch {
    return $null
  } finally {
    if ($resp) { $resp.Dispose() }
    if ($req) { $req.Dispose() }
    if ($client) { $client.Dispose() }
  }
}

# Required free bytes for an install tier. Tier peaks:
#   Stream = C + V            (stream parts into `wsl --import -`)
#   Merge  = 2C + V           (parts + merged .tar.zst)
#   Legacy = 2C + U + V       (parts + .tar.zst + uncompressed .tar)
# where C = compressed parts, U = uncompressed tar, V = U * 1.05 (dynamic vhdx).
function Get-RequiredDiskBytes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][long] $CompressedBytes,
    [long] $UncompressedBytes = 0,
    [ValidateSet('Stream', 'Merge', 'Legacy')][string] $Tier = 'Stream',
    [long] $DataDiskReserve = 2147483648,
    [long] $MarginMinBytes = 3221225472,
    [double] $MarginPct = 0.10
  )
  if ($UncompressedBytes -le 0) { $UncompressedBytes = [long]($CompressedBytes * 4.0) }
  $v = [long]($UncompressedBytes * 1.05)
  switch ($Tier) {
    'Stream' { $base = $CompressedBytes + $v }
    'Merge'  { $base = (2 * $CompressedBytes) + $v }
    'Legacy' { $base = (2 * $CompressedBytes) + $UncompressedBytes + $v }
  }
  $margin = [long]($base * $MarginPct)
  if ($margin -lt $MarginMinBytes) { $margin = $MarginMinBytes }
  return [long]($base + $DataDiskReserve + $margin)
}

function Test-DiskSpace {
  [CmdletBinding()]
  param([Parameter(Mandatory)][long] $RequiredBytes, [Parameter(Mandatory)][long] $AvailableBytes)
  return ($AvailableBytes -ge $RequiredBytes)
}

# Throw a clear, actionable (Chinese) error when the target volume is too small.
function Assert-DiskSpace {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][long] $RequiredBytes,
    [Nullable[long]] $Override = $null
  )
  $free = Get-FreeDiskSpaceBytes -Path $Path -Override $Override
  if (Test-DiskSpace -RequiredBytes $RequiredBytes -AvailableBytes $free) { return $true }
  $gi = 1073741824.0
  throw ("磁盘空间不足：安装需要约 {0:N1} GiB，但 {1} 仅剩 {2:N1} GiB。请清理磁盘，或用 -InstallDir 指定其他磁盘后重试。" -f `
    ($RequiredBytes / $gi), $Path, ($free / $gi))
}

# Tier-1 import: stream the concatenated zstd parts straight into
# `wsl --import <Distro> <InstallDir> -` via the child's raw stdin. No merged
# .zst, no .tar. Only stdin is redirected (stdout/stderr inherit the console so
# progress stays live and binary output is never text-decoded). Returns exit code.
function Invoke-WslImportStream {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string[]] $Parts,
    [Parameter(Mandatory)][string] $Distro,
    [Parameter(Mandatory)][string] $InstallDir
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'wsl.exe'
  $psi.Arguments = "--import $(Quote-NativeArg $Distro) $(Quote-NativeArg $InstallDir) -"
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError  = $false
  $psi.CreateNoWindow         = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdin = $p.StandardInput.BaseStream
  try {
    $buf = New-Object byte[] 4194304
    foreach ($part in $Parts) {
      $fs = [System.IO.File]::OpenRead($part)
      try {
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $stdin.Write($buf, 0, $n) }
      } finally { $fs.Dispose() }
    }
    $stdin.Flush()
  } finally { $stdin.Close() }
  $p.WaitForExit()
  return $p.ExitCode
}

# Fetch (once) the pinned zstd.exe through the lazily loaded download helper.
# Same name/signature as before, so Tier 3 callers are unchanged; the
# download+expand body lives in wsl-ensure-downloads.ps1.
function Get-ZstdExe {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $InstallDir)
  . (Get-AgentDevboxDownloadHelperPath)
  return (Get-ZstdExeFromRelease -InstallDir $InstallDir)
}

# ===========================================================================
# Download identity / integrity helpers
# ===========================================================================
# A partial download is only reusable when we can PROVE it belongs to the same
# remote object. The sidecar records (url, strong ETag, length, expected
# SHA256); a part whose sidecar is missing or does not match is discarded and
# fetched again. This is the lesson from the real incident: a 9 MiB partial left
# by an older release tag was resumed with the new tag's bytes, producing a file
# with the CORRECT length but mixed content - every import tier then failed and
# the console never said why.
#
# The sidecar MUST NOT live next to the part: the installer globs parts with
# `Get-ChildItem -Filter "rootfs-<variant>-amd64.tar.zst.part-*"`, so a sibling
# `...part-00.meta` would match that glob and be merged as if it were a part.
function Get-DownloadMetaPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Dest)
  $dir = Split-Path -Parent $Dest
  if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
  $leaf = Split-Path -Leaf $Dest
  return (Join-Path (Join-Path $dir '.agent-devbox-download') ($leaf + '.meta'))
}

# Returns $null when the sidecar is missing or unreadable (never throws).
function Read-DownloadSidecar {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $o = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if (-not $o) { return $null }
    return [pscustomobject]@{
      version  = [int]$o.version
      url      = [string]$o.url
      etag     = [string]$o.etag
      length   = [long]$o.length
      sha256   = [string]$o.sha256
      complete = [bool]$o.complete
      stamp    = [string]$o.stamp
    }
  } catch { return $null }
}

# Written BOM-less: PS 5.1's `Set-Content -Encoding UTF8` emits a BOM and
# ConvertFrom-Json then fails on the very next read.
function Write-DownloadSidecar {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Url,
    [AllowEmptyString()][string] $ETag = '',
    [long] $Length = 0,
    [AllowEmptyString()][string] $Sha256 = '',
    [bool] $Complete = $false
  )
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = [ordered]@{
      version  = 1
      url      = $Url
      etag     = $ETag
      length   = [long]$Length
      sha256   = $Sha256
      complete = $Complete
      stamp    = (Get-Date -Format 'o')
    }
    $json = $o | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# Pure predicate: may this sidecar be trusted to describe the requested object?
function Test-DownloadSidecarIdentity {
  [CmdletBinding()]
  param(
    [AllowNull()] $Sidecar,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Url,
    [long] $Length = 0,
    [AllowEmptyString()][string] $Sha256 = ''
  )
  if ($null -eq $Sidecar) { return $false }
  if ("$($Sidecar.url)" -cne $Url) { return $false }
  if ($Length -gt 0 -and [long]$Sidecar.length -ne $Length) { return $false }
  $want = "$Sha256".Trim()
  $had  = "$($Sidecar.sha256)".Trim()
  # A recorded-but-empty digest cannot prove content identity: if the caller
  # knows the expected digest, the sidecar must carry the same one. (Permissive
  # only when the caller has no digest - i.e. an older Release without sums.)
  if ($want -and $want -ne $had) { return $false }
  return $true
}

# Best-effort removal of a downloaded part and its sidecar.
function Remove-DownloadArtifacts {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Dest)
  Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
  $meta = Get-DownloadMetaPath -Dest $Dest
  Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
}

# Streaming SHA256 - the file is never loaded into memory.
function Get-FileSha256 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)
  $sha = $null
  $fs  = $null
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs  = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buf = New-Object byte[] 4194304
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sha.TransformBlock($buf, 0, $n, $null, 0) }
    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($fs) { $fs.Dispose() }
    if ($sha) { $sha.Dispose() }
  }
}

# Parse a `sha256sum`-style file: "<64 hex>  name" or "<64 hex> *name".
function ConvertFrom-Sha256Sums {
  [CmdletBinding()]
  param([AllowEmptyString()][string] $Text = '')
  $map = @{}
  foreach ($line in ("$Text" -split "`r?`n")) {
    if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
      $map[(Split-Path -Leaf $Matches[2])] = $Matches[1].ToLowerInvariant()
    }
  }
  return $map
}

# Names (leaves) that a SHA256SUMS map does not cover. A manifest that exists but
# does not cover every part must fail closed: silently falling back to a length
# check for those parts re-opens the "correct length, mixed content" hole.
function Get-MissingSha256Parts {
  [CmdletBinding()]
  param([AllowNull()] $ShaMap, [string[]] $Names = @())
  $missing = @()
  foreach ($n in $Names) {
    $leaf = Split-Path -Leaf $n
    $hit = $false
    try { $hit = ($ShaMap -and $ShaMap.ContainsKey($leaf) -and "$($ShaMap[$leaf])".Trim().Length -eq 64) } catch { $hit = $false }
    if (-not $hit) { $missing += $leaf }
  }
  return $missing
}

# Pure: may we conclude "the distro is NOT registered" from a `wsl -l -q` run?
# Only a SUCCESSFUL listing is authoritative. A failed call (service stopped,
# reboot pending) yields stderr text that does not contain the name - reading that
# as "absent" would delete a live distro's ext4.vhdx. Unknown => treated as listed.
function Test-DistroListed {
  [CmdletBinding()]
  param([AllowNull()] $List, [int] $ExitCode = 0, [Parameter(Mandatory)][AllowEmptyString()][string] $Distro)
  if ($ExitCode -ne 0) { return $true }
  $names = @($List | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
  return ($names -contains $Distro)
}

# Keep native tool output (wsl.exe / zstd.exe) readable but bounded.
function Format-NativeOutput {
  [CmdletBinding()]
  param([AllowNull()] $Output, [int] $MaxLines = 20)
  if ($null -eq $Output) { return '' }
  $lines = @($Output | ForEach-Object { "$_" } | Where-Object { "$_".Trim().Length -gt 0 })
  if ($lines.Count -eq 0) { return '' }
  if ($lines.Count -gt $MaxLines) { $lines = @($lines[($lines.Count - $MaxLines)..($lines.Count - 1)]) }
  $text = ($lines -join "`n")
  if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
  return $text
}

# 下载失败的人类可读原因：.NET 会把 Wait()/await 的底层异常包成
# MethodInvocationException -> AggregateException（"发生一个或多个错误"），
# 直接打印 $_.Exception.Message 只能得到那句套话（2026-10-20 安装日志里就是这样）。
# 这里沿 InnerException / InnerExceptions 往下找真正的原因；自家抛的
# "传输停滞（N 秒无数据）"永远优先，其次把常见的连接类错误翻成固定说法。
function Format-DownloadErrorMessage {
  [CmdletBinding()]
  param([AllowNull()] $Exception)
  $messages = New-Object System.Collections.Generic.List[string]
  $cur = $Exception
  for ($depth = 0; $depth -lt 8 -and $null -ne $cur; $depth++) {
    $m = "$($cur.Message)".Trim()
    if ($m) { $messages.Add($m) }
    $next = $cur.InnerException
    if ($null -eq $next -and $cur -is [System.AggregateException] -and $cur.InnerExceptions.Count -gt 0) {
      $next = $cur.InnerExceptions[0]
    }
    $cur = $next
  }
  foreach ($m in $messages) {
    # AggregateException 会把内层消息拼进自己的 Message（"...错误。 (传输停滞（30 秒无数据）)"），
    # 所以这里只取我们关心的那一段，别把套话再带出来。
    if ($m -match '传输停滞[（(][^）)]*[）)]') { return $matches[0] }
    if ($m -match '传输停滞') { return '传输停滞（连接无数据）' }
  }
  foreach ($m in $messages) {
    if ($m -match 'canceled|cancelled|任务已取消|已取消') { return '连接被取消（服务器或代理中断）' }
    if ($m -match 'timed out|timeout|超时') { return '连接超时（服务器无响应）' }
    if ($m -match 'prematurely|unexpectedly closed|响应提前结束') { return '连接被意外关闭（响应提前结束）' }
    if ($m -match 'underlying connection was closed|无法从传输连接读取数据') { return '连接被意外关闭（无法从传输连接读取数据）' }
  }
  # 最内层通常最有信息量；跳过 PowerShell/.NET 的包装套话。
  for ($i = $messages.Count - 1; $i -ge 0; $i--) {
    $m = $messages[$i]
    if ($m -and $m -notmatch '发生一个或多个错误|One or more errors occurred|时发生异常') { return $m }
  }
  if ($messages.Count -gt 0) { return $messages[0] }
  return '未知错误'
}

# A failed `wsl --import` can leave <InstallDir>\ext4.vhdx behind, which then
# makes every fallback tier fail too. Remove it ONLY when the distro is not
# registered - never touch a live distro's disk. Never throws.
function Clear-StaleImportArtifacts {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Distro, [Parameter(Mandatory)][string] $InstallDir)
  try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $list = Invoke-Native 'wsl.exe' @('-l', '-q')
      $exit = $script:NativeExit
    } finally {
      $ErrorActionPreference = $prev
    }
    # Unknown (non-zero exit) counts as REGISTERED -> never delete a live disk.
    if (Test-DistroListed -List $list -ExitCode $exit -Distro $Distro) { return $false }
    $vhdx = Join-Path $InstallDir 'ext4.vhdx'
    if (Test-Path -LiteralPath $vhdx) {
      Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $vhdx)) {
        Write-Host '     已清理上一次导入失败残留的 ext4.vhdx'
        return $true
      }
    }
    return $false
  } catch { return $false }
}

# Managed downloader: no external programs, no shell-out. The .NET HTTP stack
# resolves the Windows system proxy (WinINET, including PAC / auto-detect), so a
# system-proxy VPN works with no manual configuration - the same proxy the
# browser uses. Resume: a partial file is continued with a Range request (206
# appends, a 200 means the server ignored Range and the file restarts at zero).
# Progress: a line every ~2 s with done/total MiB and MiB/s, so a multi-GB part
# is never a silent screen. Stall guard: a read that does not return within
# -StallSeconds aborts the connection and the retry resumes from the bytes
# already on disk.
# CRITICAL: end-of-stream is NEVER success. After the output handle is closed,
# the file length must equal -ExpectedBytes (the Release asset size) and/or the
# total reported by the server. A short file is resumed; a truncated part is
# never returned as complete.
function Save-Download {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Url,
    [Parameter(Mandatory)][string] $Dest,
    [long] $ExpectedBytes = 0,
    [string] $Sha256 = '',
    [int] $Retries = 12,
    [int] $StallSeconds = 30,
    [int] $HeaderTimeoutSeconds = 60
  )
  $mb = 1048576.0
  $label = Split-Path -Leaf $Dest
  # A real console gets one line rewritten in place (carriage return); when the
  # output is redirected/file-backed we emit a normal line per tick so the log
  # still carries progress records.
  $interactiveHost = $true
  try { $interactiveHost = -not [Console]::IsOutputRedirected } catch { }
  $Sha256 = "$Sha256".Trim().ToLowerInvariant()
  if ($Sha256 -and $Sha256 -notmatch '^[0-9a-f]{64}$') { throw "无效的 SHA256：$Sha256" }
  $metaPath = Get-DownloadMetaPath -Dest $Dest
  $identityRestarts = 0
  $hashFails = 0

  # PowerShell 5.1 does not preload System.Net.Http; loading the assembly keeps
  # us clear of the AV-sensitive inline C# / P/Invoke shapes.
  $httpOk = $true
  if (-not ('System.Net.Http.HttpClient' -as [type])) {
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $httpOk = $false }
  }
  if (-not $httpOk -or -not ('System.Net.Http.HttpClient' -as [type])) {
    # Ancient .NET without System.Net.Http: bounded fallback, same size gate.
    # Without an expected size this path cannot prove completeness -> fail closed
    # instead of returning a possibly truncated file as success.
    if ($ExpectedBytes -le 0) { throw "无法确认下载完整性（缺少 -ExpectedBytes）：$Url" }
    for ($i = 1; $i -le $Retries; $i++) {
      try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
        $got = (Get-Item -LiteralPath $Dest).Length
        if ($got -eq $ExpectedBytes -and (-not $Sha256 -or (Get-FileSha256 -Path $Dest) -eq $Sha256)) { return }
        throw ("下载不完整或校验失败：{0} / {1} 字节" -f $got, $ExpectedBytes)
      } catch {
        Write-Warning ("下载中断，重试 {0}/{1}：{2}" -f $i, $Retries, (Format-DownloadErrorMessage -Exception $_.Exception))
        Start-Sleep -Seconds ([Math]::Min(10, 1 + $i))
      }
    }
    throw "下载失败（已重试 $Retries 次）：$Url"
  }

  $lastHave = -1L
  $noProgress = 0
  for ($i = 1; $i -le $Retries; $i++) {
    $handler = $null; $client = $null; $req = $null; $resp = $null
    $stream = $null; $out = $null; $cts = $null
    $fatal = $false
    $skipRead = $false
    $etag = ''
    $reqEtag = ''
    $knownTotal = if ($ExpectedBytes -gt 0) { [long]$ExpectedBytes } else { 0L }

    $have = 0L
    if (Test-Path -LiteralPath $Dest) { $have = (Get-Item -LiteralPath $Dest).Length }
    if ($have -gt 0) {
      # A partial may only be continued when we can prove it belongs to THIS
      # remote object. No sidecar, or one recorded for another URL / size /
      # digest (the usual case: the previous release tag, same part filename)
      # means the bytes cannot be trusted - drop them and start at zero.
      $meta = Read-DownloadSidecar -Path $metaPath
      if (-not (Test-DownloadSidecarIdentity -Sidecar $meta -Url $Url -Length $ExpectedBytes -Sha256 $Sha256)) {
        Write-Warning ("{0} 的残片没有可用的下载记录（可能来自其它版本），已丢弃并重新下载" -f $label)
        Remove-DownloadArtifacts -Dest $Dest
        $have = 0L
      }
    }
    if ($ExpectedBytes -gt 0 -and $have -eq $ExpectedBytes) {
      if (-not $Sha256) {
        Write-Host ("     {0}  已完整（{1:N0} MiB），跳过下载" -f $label, ($have / $mb))
        return
      }
      Write-Host ("     校验 {0} 的 SHA256…" -f $label)
      $actualSha = Get-FileSha256 -Path $Dest
      if ($actualSha -eq $Sha256) {
        Write-Host ("     {0}  已完整且校验通过（{1:N0} MiB）" -f $label, ($have / $mb))
        Write-DownloadSidecar -Path $metaPath -Url $Url -Length $have -Sha256 $Sha256 -Complete $true
        return
      }
      $hashFails++
      Write-Warning ("{0} 的 SHA256 不符（期望 {1}，实际 {2}），删除后重新下载" -f $label, $Sha256, $actualSha)
      Remove-DownloadArtifacts -Dest $Dest
      $have = 0L
      if ($hashFails -ge 2) { throw "SHA256 校验连续 $hashFails 次失败：$Url" }
    }
    if ($ExpectedBytes -gt 0 -and $have -gt $ExpectedBytes) {
      Write-Warning ("$label 已存在但大于预期（$have / $ExpectedBytes 字节），从头重新下载")
      $have = 0L
      Remove-DownloadArtifacts -Dest $Dest
    }
    if ($have -eq $lastHave) { $noProgress++ } else { $noProgress = 0; $lastHave = $have }
    if ($noProgress -ge 4) { throw "下载失败：连续 $noProgress 次无进展（$label 停在 $have 字节）" }
    if ($have -gt 0) { Write-Host ("     {0}  已有 {1:N0} MiB，断点续传…" -f $label, ($have / $mb)) }

    try {
      $handler = [System.Net.Http.HttpClientHandler]::new()
      $handler.AllowAutoRedirect = $true
      $handler.UseCookies = $false
      $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
      $handler.UseProxy = $true
      try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        if ($proxy) {
          $handler.Proxy = $proxy
          try { $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }
        }
      } catch { }

      $client = [System.Net.Http.HttpClient]::new($handler)
      $client.Timeout = [TimeSpan]::FromHours(6)
      $client.DefaultRequestHeaders.UserAgent.ParseAdd('agent-devbox-installer')

      # A request object is single-use: build a fresh one for every attempt.
      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
      if ($have -gt 0) {
        # Windows PowerShell 5.1 uses the .NET Framework handler, which maps a
        # typed Range value to webRequest.AddRange((long)From, (long)To) - an
        # open-ended "bytes=N-" has a null To and throws InvalidOperationException.
        # Always send a closed range: expected-1 when the asset size is known,
        # Int64.MaxValue as the open-ended equivalent otherwise.
        $end = if ($ExpectedBytes -gt $have) { [long]($ExpectedBytes - 1) } else { [long]::MaxValue }
        # Typed property (not a raw header): the .NET Framework handler reads
        # headers.Range and converts both ends, so a non-null end is mandatory.
        $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new([long]$have, [long]$end)

        # Conditional resume with the stored strong ETag. MEASURED: GitHub
        # Releases (Azure blob) IGNORE `If-Range` - a stale validator still
        # returns 206 - so If-Range cannot protect the append. `If-Match` is
        # honoured: a changed object returns 412 and we restart from zero.
        $m = Read-DownloadSidecar -Path $metaPath
        if ($m -and $m.etag) { $reqEtag = [string]$m.etag }
        if ($reqEtag) {
          $sent = $false
          try { $sent = [bool]$req.Headers.TryAddWithoutValidation('If-Match', $reqEtag) } catch { $sent = $false }
          if (-not $sent) {
            Write-Warning ("{0} 的 ETag 无法作为 If-Match 发送，本次只按 Range 续传（完成后仍会校验长度/哈希）" -f $label)
          }
        } else {
          Write-Warning ("{0} 没有可用的 ETag，本次只按 Range 续传（完成后仍会校验长度/哈希）" -f $label)
        }
      }

      $cts = [System.Threading.CancellationTokenSource]::new()
      $cts.CancelAfter([TimeSpan]::FromSeconds($HeaderTimeoutSeconds))
      $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode

      if ($status -eq 404 -or $status -eq 410) {
        $fatal = $true
        throw ("资源不存在（HTTP {0}）：{1}" -f $status, $Url)
      }

      if ($status -eq 412) {
        # If-Match rejected our validator: the remote object changed (a new
        # release reused the part filename). Never append - restart at zero.
        $identityRestarts++
        Write-Warning ("{0} 的云端文件已更新（HTTP 412），丢弃旧分片重新下载" -f $label)
        Remove-DownloadArtifacts -Dest $Dest
        $have = 0L
        if ($identityRestarts -ge 2) {
          $fatal = $true
          throw '下载内容在多次尝试中持续变化，已放弃（请稍后重试）'
        }
        throw 'HTTP 412（云端文件已更新）'
      }

      if ($status -eq 416) {
        # Range not satisfiable: either the file is already complete or the
        # local partial is bogus. The total lives in `Content-Range: bytes */N`.
        $t = 0L
        try {
          $cr = $resp.Content.Headers.ContentRange
          if ($cr -and $null -ne $cr.Length) { $t = [long]$cr.Length }
        } catch { }
        if ($t -gt 0 -and $have -eq $t) {
          $knownTotal = $t
          $skipRead = $true
        } else {
          Write-Warning ("$label 的续传位置无效（HTTP 416），从头重新下载")
          $have = 0L
          Remove-DownloadArtifacts -Dest $Dest
          throw 'HTTP 416（续传位置无效）'
        }
      } elseif (-not $resp.IsSuccessStatusCode) {
        throw ("HTTP {0} {1}" -f $status, $resp.ReasonPhrase)
      } else {
        $cl = $resp.Content.Headers.ContentLength
        $cr = $resp.Content.Headers.ContentRange
        if ($status -eq 206) {
          # A 206 must carry Content-Range and it must start exactly at our
          # offset. Never use truthiness here: From=0 is a legitimate value for
          # a zero-offset range, and a missing Content-Range must not be
          # mistaken for a match (that would append the wrong bytes and still
          # pass the final length check).
          if (-not $cr -or $null -eq $cr.From -or [long]$cr.From -ne $have) {
            $fromText = if ($cr -and $null -ne $cr.From) { $cr.From } else { '缺失' }
            Write-Warning ("$label 续传位置不匹配（服务器 {0}，本地 {1}），从头重新下载" -f $fromText, $have)
            $have = 0L
            Remove-DownloadArtifacts -Dest $Dest
            throw '续传位置不匹配'
          }
          if ($null -ne $cr.Length) { $knownTotal = [long]$cr.Length }
          elseif ($null -ne $cl) { $knownTotal = $have + [long]$cl }
        } else {
          # 200: Range was ignored -> restart, never append to the partial.
          if ($have -gt 0) {
            Write-Warning ("$label 的服务器不支持续传，从头重新下载")
            $have = 0L
          }
          if ($null -ne $cl) { $knownTotal = [long]$cl }
        }
        if ($ExpectedBytes -gt 0 -and $knownTotal -gt 0 -and $knownTotal -ne $ExpectedBytes) {
          $fatal = $true
          throw ("服务器文件大小（{0}）与 Release 元数据（{1}）不一致" -f $knownTotal, $ExpectedBytes)
        }
        # Record the identity BEFORE writing any bytes, so even a crash mid
        # transfer leaves a sidecar that proves which object this partial is.
        # A weak ETag is useless for If-Match, so only a strong one is stored.
        try {
          if ($resp.Headers.ETag -and -not $resp.Headers.ETag.IsWeak) { $etag = [string]$resp.Headers.ETag.Tag }
        } catch { }
        # Do not erase a previously stored strong ETag: a 206 may omit it, and
        # dropping it would permanently degrade later resumes to Range-only.
        if (-not $etag) { $etag = $reqEtag }
        $sidecarLen = if ($ExpectedBytes -gt 0) { [long]$ExpectedBytes } else { [long]$knownTotal }
        Write-DownloadSidecar -Path $metaPath -Url $Url -ETag $etag -Length $sidecarLen -Sha256 $Sha256 -Complete $false
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      }

      if (-not $skipRead) {
        $out = [System.IO.File]::Open($Dest, [System.IO.FileMode]::OpenOrCreate,
          [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $out.SetLength($have)
        $out.Position = $have
        $buf = New-Object byte[] 262144
        $done = 0L
        $winStart = [DateTime]::UtcNow
        $winBytes = 0L
        while ($true) {
          $rt = $stream.ReadAsync($buf, 0, $buf.Length)
          if (-not $rt.Wait([TimeSpan]::FromSeconds($StallSeconds))) {
            throw ("传输停滞（{0} 秒无数据）" -f $StallSeconds)
          }
          $n = $rt.Result
          if ($n -le 0) { break }
          $out.Write($buf, 0, $n)
          $done += $n
          $winBytes += $n
          $elapsed = ([DateTime]::UtcNow - $winStart).TotalSeconds
          if ($elapsed -ge 2) {
            $speed = $winBytes / $elapsed
            $cur = ($have + $done) / $mb
            if ($knownTotal -gt 0) {
              $pct = 100.0 * ($have + $done) / $knownTotal
              $cells = 20
              $filled = [int][Math]::Floor($pct * $cells / 100.0)
              if ($filled -lt 0) { $filled = 0 }
              if ($filled -gt $cells) { $filled = $cells }
              $bar = (('#' * $filled) -join '') + (('-' * ($cells - $filled)) -join '')
              # One line, rewritten in place on a console (NOT Write-Progress: that
              # draws in a separate top-of-console region and never reaches the
              # transcript). Redirected output falls back to one line per tick.
              # Fixed-width fields: the in-place rewrite must never leave
              # leftovers when a number grows a digit.
              $line = ("     {0}  [{1}] {2,5:N1}%  {3,5:N0}/{4,5:N0} MiB  {5,5:N1} MiB/s" -f $label, $bar, $pct, $cur, ($knownTotal / $mb), ($speed / $mb))
              if ($interactiveHost) {
                # ONE line, rewritten in place. [Console]::Write goes straight to
                # the console and is NOT captured by Start-Transcript, so neither
                # the popup nor the relayed log accumulates one line per tick.
                [Console]::Write("`r" + $line)
              } else {
                Write-Host $line
              }
            } else {
              $line = ("     {0}  {1:N0} MiB  {2:N1} MiB/s" -f $label, $cur, ($speed / $mb))
              if ($interactiveHost) { [Console]::Write("`r" + $line) } else { Write-Host $line }
            }
            $winStart = [DateTime]::UtcNow
            $winBytes = 0L
          }
        }
        # Terminate the in-place line so the completion message starts clean.
        if ($interactiveHost) { Write-Host '' }
      }
    } catch {
      Write-Warning ("下载中断，重试 {0}/{1}（断点续传）：{2}" -f $i, $Retries, (Format-DownloadErrorMessage -Exception $_.Exception))
      if ($fatal) { throw }
      Start-Sleep -Seconds ([Math]::Min(10, 1 + $i))
      continue
    } finally {
      if ($out) { try { $out.Flush(); $out.Dispose() } catch { } }
      if ($stream) { $stream.Dispose() }
      if ($resp) { $resp.Dispose() }
      if ($req) { $req.Dispose() }
      if ($cts) { $cts.Dispose() }
      if ($client) { $client.Dispose() }
      if ($handler) { $handler.Dispose() }
    }

    # Verify only after the output handle has been flushed and closed. This is
    # the gate that the old end-of-stream implementation lacked.
    $actual = 0L
    if (Test-Path -LiteralPath $Dest) { $actual = (Get-Item -LiteralPath $Dest).Length }
    $want = if ($ExpectedBytes -gt 0) { [long]$ExpectedBytes } elseif ($knownTotal -gt 0) { [long]$knownTotal } else { 0L }
    if ($want -le 0) { throw "无法确认下载完整性（缺少大小信息）：$Url" }
    if ($actual -ne $want) {
      Write-Warning ("{0} 大小不符（{1} / {2} 字节），继续续传" -f $label, $actual, $want)
      Start-Sleep -Seconds 1
      continue
    }
    # Content gate. The length can be right and the bytes still wrong (a mixed
    # prefix from another release), so when the Release publishes SHA256SUMS the
    # digest decides - not the length.
    if ($Sha256) {
      Write-Host ("     校验 {0} 的 SHA256…" -f $label)
      $actualSha = Get-FileSha256 -Path $Dest
      if ($actualSha -ne $Sha256) {
        $hashFails++
        Write-Warning ("{0} 的 SHA256 不符（期望 {1}，实际 {2}），删除后重新下载" -f $label, $Sha256, $actualSha)
        Remove-DownloadArtifacts -Dest $Dest
        if ($hashFails -ge 2) { throw "SHA256 校验连续 $hashFails 次失败：$Url" }
        continue
      }
    }
    Write-DownloadSidecar -Path $metaPath -Url $Url -ETag $etag -Length $actual -Sha256 $Sha256 -Complete $true
    Write-Host ("     {0}  完成 {1:N0} MiB" -f $label, ($actual / $mb))
    return
  }
  throw "下载失败（已重试 $Retries 次）：$Url"
}

# Verify a distro is really registered and bootable before declaring success.
# Distro registration is per-user: if UAC elevated into a DIFFERENT account the
# distro lands in that account's hive and the original user gets
# WSL_E_DISTRO_NOT_FOUND - the message below says so explicitly.
function Assert-DistroReady {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Distro,
    [Parameter(Mandatory)][string] $InstallDir,
    [switch] $NoLaunch,
    [switch] $UnregisterOnFail
  )
  $env:WSL_UTF8 = '1'
  $ok = $false
  $list = Invoke-Native 'wsl.exe' @('-l', '-q')
  if ($script:NativeExit -eq 0) {
    $names = @($list | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
    if ($names -contains $Distro) { $ok = $true }
  }
  if ($ok -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'ext4.vhdx'))) { $ok = $false }
  # -NoLaunch skips booting the distro: used right after import, BEFORE the data
  # disk/config exist, so the boot script cannot run and stamp a MAINTENANCE MOTD.
  if ($ok -and -not $NoLaunch) {
    Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', '/bin/true') | Out-Null
    if ($script:NativeExit -ne 0) { $ok = $false }
  }
  if (-not $ok) {
    if ($UnregisterOnFail) { Invoke-Native 'wsl.exe' @('--unregister', $Distro) | Out-Null }
    throw ("发行版 '$Distro' 未成功注册（wsl -d 会报 WSL_E_DISTRO_NOT_FOUND）。可能原因：导入失败 / 空间不足 / " +
      "提权时使用了不同的管理员帐户（WSL 发行版按用户注册，会落在该帐户下）。请重试，或手动运行 wsl -l -v 检查。")
  }
  return $true
}

function Assert-DataDiskMounted {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Distro,
    [Parameter(Mandatory)][string] $MountName,
    [int] $SinceLine = 0,
    [int] $TimeoutSeconds = 45
  )
  $target = "/mnt/$MountName"
  $bootLogPath = '/var/log/agent-devbox-boot.log'
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $newLog = ''
  do {
    # boot 日志是文件证据：`wsl -d` 会话不一定能看到 [boot] 会话建立的挂载
    # （2026-10-21 22:05 实测 findmnt 一直看不到，但 boot 日志已写「数据盘挂载成功 / boot complete」）。
    $tail = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "tail -n +$($SinceLine + 1) $bootLogPath 2>/dev/null")
    $newLog = "$tail"
    if ($newLog -match 'boot complete') { return $true }
    if ($newLog -match 'FATAL') { break }
    $out = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', "findmnt -rno TARGET --mountpoint $target 2>/dev/null")
    if ($script:NativeExit -eq 0 -and ("$out".Trim() -eq $target)) { return $true }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  $msg = "数据磁盘没有挂载到 {0}，安装未完成（发行版会停在维护模式）。`n本次启动新增日志：`n{1}`n" +
         "请以管理员运行安装目录里的 mount-datadisk.ps1（附加数据盘，诊断写入 datadisk-attach.log），再重新打开 WSL。"
  throw ($msg -f $target, $newLog)
}

# ===========================================================================
# Windows Terminal profile: one FIXED GUID across reinstalls
# ===========================================================================
# WSL's own profile fragment uses v5(WslTerminalNamespace, registration GUID), so
# every `wsl --import` produces a new WT profile and the user's customizations are
# orphaned. The image disables that generator ([windowsterminal] enabled=false);
# these helpers write one fragment with a constant GUID and name-based launch.
function New-TerminalProfileFragment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Distro,
    [Parameter(Mandatory)][string] $ProfileGuid,
    [Parameter(Mandatory)][string] $HideGuid,
    [Parameter(Mandatory)][string] $StartingDirectory
  )
  $doc = [ordered]@{
    profiles = @(
      [ordered]@{ updates = $HideGuid; hidden = $true },
      [ordered]@{
        guid              = $ProfileGuid
        name              = $Distro
        commandline       = ('C:\Windows\System32\wsl.exe -d {0}' -f $Distro)
        startingDirectory = $StartingDirectory
      }
    )
  }
  return ($doc | ConvertTo-Json -Depth 8)
}

function Write-AgentDevboxTerminalProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Distro,
    [Parameter(Mandatory)][string] $ProfileGuid,
    [Parameter(Mandatory)][string] $HideGuid
  )
  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA 为空，无法写入 Terminal profile。' }
  $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\AgentDevbox'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $path = Join-Path $dir ($Distro + '.json')
  $json = New-TerminalProfileFragment -Distro $Distro -ProfileGuid $ProfileGuid -HideGuid $HideGuid `
    -StartingDirectory ('\\wsl$\{0}\root' -f $Distro)
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

function Remove-StaleWslTerminalFragments {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Distro)
  $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Microsoft.WSL'
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $removed = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -ErrorAction SilentlyContinue)) {
    $isOurs = $false
    try {
      $doc = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
      foreach ($p in @($doc.profiles)) {
        if ($null -ne $p -and ("$($p.name)" -ieq $Distro)) { $isOurs = $true; break }
      }
    } catch { continue }
    if ($isOurs) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $f.FullName)) { $removed++ }
    }
  }
  return $removed
}

function Assert-PaseoHealthy {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Distro,
    [int] $TimeoutSeconds = 45
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'bash', '-lc', 'wget -q -T 5 -O /dev/null http://127.0.0.1:6767/api/health') | Out-Null
    if ($script:NativeExit -eq 0) { return $true }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  $log = Invoke-Native 'wsl.exe' @('-d', $Distro, '-u', 'root', '-e', 'tail', '-n', '20', '/var/log/paseo-boot.log')
  throw ("paseo 未在 {0}s 内就绪（/api/health 不是 200）。`n{1}" -f $TimeoutSeconds, $log)
}
