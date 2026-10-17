<#
.SYNOPSIS
  Shared WSL preflight helpers for the agent-devbox Windows installers.

.DESCRIPTION
  Dot-source-safe: this file has NO param() block and runs NO code on load, so
  `. .\wsl-ensure.ps1` defines the functions without any side effects.

  Exposes:
    Test-WslInstalled    - is a functional WSL present? (no interactive block)
    Ensure-Wsl           - install WSL if missing (asks base-only vs base+wsl-ui)
    Install-WslUi        - install the wsl-ui GUI from its latest GitHub release
    Get-WslNetworkingMode- read the active networking mode
    Set-MirroredNetworking - switch .wslconfig [wsl2] networkingMode=mirrored

.NOTES
  Detection uses `wsl.exe --status` (fast, non-interactive). NEVER `wsl --version`
  (it blocks interactively when WSL is missing) and never `Get-Command wsl`
  (the System32 stub always exists even when WSL is not installed).
#>

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

function Install-WslUi {
  [CmdletBinding()]
  param()

  $ErrorActionPreference = 'Stop'
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

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

function Set-MirroredNetworking {
  [CmdletBinding()]
  param([switch] $Yes)

  $ErrorActionPreference = 'Stop'

  $cfg = Join-Path $env:USERPROFILE '.wslconfig'

  # Already mirrored? Trust the live mode when a distro exists, else the config
  # file (wslinfo needs a distro, and right after installing WSL there is none).
  $mirrored = $false
  if ((Get-WslNetworkingMode) -eq 'mirrored') {
    $mirrored = $true
  } elseif (Test-Path -LiteralPath $cfg) {
    $inWsl2 = $false
    foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
      $t = $line.Trim()
      if ($t -match '^\[(.+)\]$') { $inWsl2 = ($Matches[1] -ieq 'wsl2') }
      elseif ($inWsl2 -and $t -match '^networkingMode\s*=\s*mirrored\s*$') { $mirrored = $true; break }
    }
  }
  if ($mirrored) {
    Write-Host '镜像网络已开启。'
    return
  }

  if (-not $Yes) {
    $ans = Read-Host '建议开启镜像网络（对 VPN / 手机访问更友好）。现在切换？[Y/n]（回车 = 是）'
    if ($ans -match '^(n|no)$') {
      Write-Host '已跳过。'
      return
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

  wsl.exe --shutdown | Out-Null
  Write-Host '已切换到镜像网络（已执行 wsl --shutdown）。若使用 VPN，请确保 VPN 允许访问本地网络。'
}

# ===========================================================================
# Installer shared helpers (dot-source-safe: definitions only, no side effects).
# ===========================================================================

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
# P/Invoke GetDiskFreeSpaceEx (handles directory mount points / junctions);
# falls back to DriveInfo on the path root. $Override is a test hook.
function Get-FreeDiskSpaceBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path, [Nullable[long]] $Override = $null)
  if ($null -ne $Override) { return [long]$Override }

  $full = [System.IO.Path]::GetFullPath($Path)
  try {
    if (-not ('AgentDevbox.DiskSpace' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AgentDevbox {
  public static class DiskSpace {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName,
      out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
  }
}
'@
    }
    # GetDiskFreeSpaceEx needs an existing path; walk up to the nearest parent.
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
      $parent = [System.IO.Path]::GetDirectoryName($probe)
      if ([string]::IsNullOrEmpty($parent) -or $parent -eq $probe) { break }
      $probe = $parent
    }
    [uint64]$avail = 0; [uint64]$total = 0; [uint64]$totalFree = 0
    if ([AgentDevbox.DiskSpace]::GetDiskFreeSpaceEx($probe, [ref]$avail, [ref]$total, [ref]$totalFree)) {
      return [long]$avail
    }
  } catch { }
  $root = [System.IO.Path]::GetPathRoot($full)
  return [long]([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
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

# Read the first bytes of a remote part via an HTTP Range request (raw stream,
# never a decoded string) and parse the frame header. Returns $null on failure.
function Get-ZstdUncompressedSizeFromUrl {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Url)
  $ErrorActionPreference = 'Stop'
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'agent-devbox-installer'
    $req.AddRange(0, 17)
    $req.Timeout = 30000
    $resp = $req.GetResponse()
    try {
      $stream = $resp.GetResponseStream()
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
    } finally { $resp.Close() }
  } catch {
    return $null
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

# Fetch (once) the pinned zstd.exe from the official facebook/zstd release.
function Get-ZstdExe {
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

# Robust download: curl.exe with resume + retries when available (Windows 10
# 1803+/11 ship it), else Invoke-WebRequest with retries. Throws after exhausting
# retries. Large GitHub asset downloads reset connections often, so never fire a
# single bare Invoke-WebRequest at a multi-GB part.
function Save-Download {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Url,
    [Parameter(Mandatory)][string] $Dest,
    [int] $Retries = 6
  )
  $curl = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\curl.exe' } else { $null }
  for ($i = 1; $i -le $Retries; $i++) {
    if ($curl -and (Test-Path -LiteralPath $curl)) {
      Invoke-Native $curl @('-L', '--fail', '--silent', '--show-error',
        '--retry', '3', '--retry-delay', '2', '--retry-connrefused',
        '-C', '-', '-o', $Dest, $Url) | Out-Null
      if ($script:NativeExit -eq 0) { return }
    } else {
      try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop; return } catch { }
    }
    Write-Warning ("下载中断，重试 {0}/{1}（断点续传）…" -f $i, $Retries)
    Start-Sleep -Seconds ([Math]::Min(15, 3 * $i))
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
