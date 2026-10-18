#!/usr/bin/env pwsh
# Dependency-free unit tests for the Windows installer's pure helpers.
#   pwsh -NoProfile -File tests/powershell/run.ps1
# Exits non-zero if any assertion fails.
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..' '..' 'windows' 'wsl-ensure.ps1')

$script:Failed = 0
$script:Total  = 0
function Assert-True {
  param([bool] $Condition, [string] $Message)
  $script:Total++
  if (-not $Condition) {
    $script:Failed++
    Write-Host "FAIL: $Message" -ForegroundColor Red
  } else {
    Write-Host "ok: $Message"
  }
}
function Assert-Equal {
  param($Expected, $Actual, [string] $Message)
  Assert-True ($Expected -eq $Actual) "$Message (expected [$Expected] got [$Actual])"
}

# --- Normalize-ReleaseTag --------------------------------------------------
Assert-Equal 'beta' (Normalize-ReleaseTag 'b') 'Normalize: b -> beta'
Assert-Equal 'beta' (Normalize-ReleaseTag 'beta') 'Normalize: beta -> beta'
Assert-Equal 'beta' (Normalize-ReleaseTag '  beta ') 'Normalize: trim'
Assert-Equal 'build-20261018.0731' (Normalize-ReleaseTag '20261018.0731') 'Normalize: bare date -> build-'
Assert-Equal 'beta-20261018.0731' (Normalize-ReleaseTag 'beta-20261018.0731') 'Normalize: explicit beta tag passthrough'
Assert-Equal 'latest' (Normalize-ReleaseTag 'latest') 'Normalize: latest passthrough'

# --- Resolve-YesNoDefault (issue #1) --------------------------------------
Assert-True (Resolve-YesNoDefault -Answer '' -DefaultYes $true) 'YesNo: Enter defaults to yes'
Assert-True (Resolve-YesNoDefault -Answer 'y' -DefaultYes $true) 'YesNo: y -> yes'
Assert-True (Resolve-YesNoDefault -Answer 'Y' -DefaultYes $true) 'YesNo: Y -> yes'
Assert-True (-not (Resolve-YesNoDefault -Answer 'n' -DefaultYes $true)) 'YesNo: n -> no'
Assert-True (-not (Resolve-YesNoDefault -Answer 'No' -DefaultYes $true)) 'YesNo: No -> no'
Assert-True (-not (Resolve-YesNoDefault -Answer '' -DefaultYes $false)) 'YesNo: Enter defaults to no'
Assert-True (Resolve-YesNoDefault -Answer 'zzz' -DefaultYes $true) 'YesNo: unknown -> default'

# --- Test-ZstdBanner (issue #4) -------------------------------------------
Assert-True (Test-ZstdBanner 'bsdtar 3.6.2 - libarchive 3.6.2 zlib/1.2.5 liblzma/5.2.5 bz2lib/1.0.8 libzstd/1.5.4') 'zstd: libzstd present -> true'
Assert-True (-not (Test-ZstdBanner 'bsdtar 3.3.2 - libarchive 3.3.2 zlib/1.2.5.f-ipp')) 'zstd: libzstd absent -> false'
Assert-True (-not (Test-ZstdBanner '')) 'zstd: empty -> false'

# --- Get-ZstdUncompressedSizeFromBytes (RFC 8878) -------------------------
# Real-world header for this repo's rootfs (FCS flag 3 / 8 bytes, single-seg off).
$hdr = [byte[]](0x28, 0xB5, 0x2F, 0xFD, 0xC4, 0x60, 0x00, 0xE6, 0x90, 0x5F, 0x02, 0x00, 0x00, 0x00)
Assert-Equal ([long]10193266176) (Get-ZstdUncompressedSizeFromBytes $hdr) 'zstd-hdr: 8-byte FCS'
# FCS flag 1 (2 bytes, value + 256), window descriptor present, dictID 0.
Assert-Equal ([long]512) (Get-ZstdUncompressedSizeFromBytes ([byte[]](0x28, 0xB5, 0x2F, 0xFD, 0x40, 0x00, 0x00, 0x01))) 'zstd-hdr: 2-byte FCS +256'
# FCS flag 3 with a 1-byte Dictionary_ID (fhd = 0xC1).
Assert-Equal ([long]16) (Get-ZstdUncompressedSizeFromBytes ([byte[]](0x28, 0xB5, 0x2F, 0xFD, 0xC1, 0x00, 0xAB, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))) 'zstd-hdr: 8-byte FCS + dictID'
# Single-segment, FCS flag 0 -> 1-byte FCS (no window descriptor).
Assert-Equal ([long]64) (Get-ZstdUncompressedSizeFromBytes ([byte[]](0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x40))) 'zstd-hdr: single-seg 1-byte FCS'
# Not a zstd frame.
Assert-True ($null -eq (Get-ZstdUncompressedSizeFromBytes ([byte[]](0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06)))) 'zstd-hdr: bad magic -> null'

# --- Disk math + predicate (issue #8) -------------------------------------
$c = [long]3030000000   # ~2.82 GiB
$u = [long]10193266176  # ~9.49 GiB
$stream = Get-RequiredDiskBytes -CompressedBytes $c -UncompressedBytes $u -Tier Stream
$merge  = Get-RequiredDiskBytes -CompressedBytes $c -UncompressedBytes $u -Tier Merge
$legacy = Get-RequiredDiskBytes -CompressedBytes $c -UncompressedBytes $u -Tier Legacy
Assert-True ($stream -lt $merge) 'disk: Stream < Merge'
Assert-True ($merge -lt $legacy) 'disk: Merge < Legacy'
Assert-Equal $legacy ($stream + $c + $u) 'disk: Legacy - Stream = C + U'
Assert-True (Test-DiskSpace -RequiredBytes 100 -AvailableBytes 100) 'disk: equal available passes'
Assert-True (-not (Test-DiskSpace -RequiredBytes 100 -AvailableBytes 99)) 'disk: short available fails'

$tmp = [System.IO.Path]::GetTempPath()
Assert-True ((Get-FreeDiskSpaceBytes -Path $tmp) -gt 0) 'disk: free space of temp > 0'
Assert-True ((Get-FreeDiskSpaceBytes -Path $tmp -Override 12345) -eq 12345) 'disk: Override honoured'
Assert-True ($null -eq ('AgentDevbox.DiskSpace' -as [type])) 'disk: no inline C# type'
$threw = $false
try { Assert-DiskSpace -Path $tmp -RequiredBytes 1000000000 -Override 1000 | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match '磁盘空间不足') 'disk: insufficient -> Chinese error' }
Assert-True $threw 'disk: insufficient blocks install'
Assert-True (Assert-DiskSpace -Path $tmp -RequiredBytes 1000 -Override 1000000000) 'disk: sufficient passes'

# --- Structural tripwire: disk check must precede any download ------------
$installer = Join-Path $here '..' '..' 'windows' 'install-agent-devbox.ps1'
if (Test-Path -LiteralPath $installer) {
  $lines = [System.IO.File]::ReadAllLines($installer)
  $diskIdx = -1; $dlIdx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($diskIdx -lt 0 -and $lines[$i] -match 'Assert-DiskSpace') { $diskIdx = $i }
    if ($dlIdx -lt 0 -and $lines[$i] -match 'Save-Download') { $dlIdx = $i }
  }
  Assert-True ($diskIdx -ge 0) 'struct: installer calls Assert-DiskSpace'
  Assert-True ($dlIdx -ge 0) 'struct: installer downloads via Save-Download'
  Assert-True ($diskIdx -ge 0 -and $dlIdx -ge 0 -and $diskIdx -lt $dlIdx) 'struct: disk check precedes download'
}

# --- AV hardening tripwires (static) --------------------------------------
$winDir = Join-Path $here '..' '..' 'windows'
$ensureText = Get-Content -Raw (Join-Path $winDir 'wsl-ensure.ps1')
$webText    = Get-Content -Raw (Join-Path $winDir 'install.ps1')
$mainText   = Get-Content -Raw (Join-Path $winDir 'install-agent-devbox.ps1')

# C1: no inline C# / P/Invoke in the shared helper.
Assert-True ($ensureText -notmatch 'TypeDefinition') 'av: wsl-ensure has no Add-Type -TypeDefinition'
Assert-True ($ensureText -notmatch 'DllImport') 'av: wsl-ensure has no DllImport'
# C2: no raw HttpWebRequest / response stream.
Assert-True ($ensureText -notmatch 'HttpWebRequest') 'av: wsl-ensure has no HttpWebRequest'
Assert-True ($ensureText -notmatch 'GetResponseStream') 'av: wsl-ensure has no GetResponseStream'
# C3: staging outside %TEMP%.
Assert-True ($webText -match 'LOCALAPPDATA') 'av: install.ps1 stages under LOCALAPPDATA'
Assert-True ($webText -notmatch 'GetTempPath') 'av: install.ps1 does not use GetTempPath'
Assert-True ($mainText -match 'LOCALAPPDATA') 'av: installer log under LOCALAPPDATA'
Assert-True ($mainText -notmatch 'GetTempPath') 'av: installer does not use GetTempPath'
# C4: no Bypass / AMSI-visible tokens in the web entry.
Assert-True ($webText -notmatch '(?i)\birm\b') 'av: install.ps1 has no irm token'
Assert-True ($webText -notmatch '(?i)\biex\b') 'av: install.ps1 has no iex token'
Assert-True ($webText -notmatch 'ExecutionPolicy[^\r\n]*Bypass') 'av: install.ps1 has no ExecutionPolicy Bypass'
Assert-True ($webText -match 'RemoteSigned') 'av: install.ps1 elevation uses RemoteSigned'
# C5: install.cmd exists, ASCII/CRLF, fetches scripts from the SOURCE tree.
$cmdPath = Join-Path $winDir 'install.cmd'
Assert-True (Test-Path -LiteralPath $cmdPath) 'av: install.cmd exists'
if (Test-Path -LiteralPath $cmdPath) {
  $cmdBytes = [System.IO.File]::ReadAllBytes($cmdPath)
  Assert-True (-not ($cmdBytes | Where-Object { $_ -gt 127 })) 'av: install.cmd is ASCII'
  $cmdText = [System.IO.File]::ReadAllText($cmdPath)
  Assert-True ($cmdText -match 'raw\.githubusercontent\.com') 'av: install.cmd fetches scripts from the source tree'
  Assert-True ($cmdText -match 'Invoke-WebRequest') 'av: install.cmd downloads via PowerShell (system proxy)'
  Assert-True ($cmdText -notmatch 'curl\.exe') 'av: install.cmd does not depend on curl.exe'
  Assert-True ($cmdText -match 'LOCALAPPDATA') 'av: install.cmd stages under LOCALAPPDATA'
  Assert-True ($cmdText -notmatch '%TEMP%') 'av: install.cmd avoids %TEMP%'
  Assert-True ($cmdText -match 'AGENT_DEVBOX_RELEASE_TAG') 'av: install.cmd documents the tag env var'
  Assert-True ($cmdText -notmatch '(?m)[^\r]\n') 'av: install.cmd uses CRLF'
  # The Release is used ONLY for the rootfs parts; scripts come from main.
  Assert-True ($cmdText -notmatch 'releases/latest/download') 'av: install.cmd does not rely on /releases/latest'
}
# C6: release packaging.
$ciText = Get-Content -Raw (Join-Path $here '..' '..' '.github' 'workflows' 'build.yml')
Assert-True ($ciText -match '(?m)^\s*windows/install\.cmd\s*$') 'av: build.yml bundles install.cmd'
Assert-True ($ciText -notmatch '(?m)^\s*windows/install\.ps1\s*$') 'av: build.yml zip list excludes install.ps1'

# C7: Pass 2 - the download-and-execute primitives live in a lazily loaded helper.
Assert-True ($ensureText -notmatch 'function Install-WslUi') 'av: wsl-ensure has no Install-WslUi body'
Assert-True ($ensureText -notmatch 'facebook/zstd') 'av: wsl-ensure has no facebook/zstd URL'
Assert-True ($ensureText -match 'Get-AgentDevboxDownloadHelperPath') 'av: wsl-ensure has the lazy helper resolver'
Assert-True ($ensureText -match 'function Get-ZstdExe\b') 'av: wsl-ensure keeps the Get-ZstdExe wrapper'
$helperPath = Join-Path $winDir 'wsl-ensure-downloads.ps1'
Assert-True (Test-Path -LiteralPath $helperPath) 'av: wsl-ensure-downloads.ps1 exists'
if (Test-Path -LiteralPath $helperPath) {
  $helperText = Get-Content -Raw $helperPath
  Assert-True ($helperText -match 'function Install-WslUi') 'av: helper owns Install-WslUi'
  Assert-True ($helperText -match 'function Get-ZstdExeFromRelease') 'av: helper owns Get-ZstdExeFromRelease'
}
Assert-True ($ciText -match '(?m)^\s*windows/wsl-ensure-downloads\.ps1\s*\\?\s*$') 'av: build.yml bundles the download helper'

# Downloader: curl.exe with resume/retries. curl verifies Content-Length and exits
# non-zero on a short read, so a truncated part is RESUMED - never kept silently
# (an incomplete part is exactly what broke the merge/import). Invoke-WebRequest
# fallback; no manual proxy plumbing.
Assert-True ($ensureText -match 'function Save-Download') 'dl: wsl-ensure has Save-Download'
Assert-True ($ensureText -match 'System32\\curl\.exe') 'dl: Save-Download uses curl.exe'
Assert-True ($ensureText -match 'Invoke-WebRequest -Uri \$Url -OutFile') 'dl: Save-Download falls back to Invoke-WebRequest'
Assert-True ($ensureText -match '--retry') 'dl: Save-Download retries/resumes'
Assert-True ($ensureText -notmatch 'Get-SystemProxy|GetSystemWebProxy') 'dl: no manual proxy resolution'

# --- Interpolation tripwire: bare $var? inside a string --------------------
# `"$relApi?per_page=100"` does NOT interpolate $relApi: `?` is a legal
# variable-name character, so the parser reads a variable named `relApi?per_page`
# (undefined -> empty), the URL collapses to "=100", and Invoke-RestMethod throws
# UriFormatException (无效的 URI: 未能分析主机名). Always brace it:
# `"${relApi}?per_page=100"`. PS7's `$a?.b` null-conditional is excluded.
$badInterp = @()
foreach ($ps1 in Get-ChildItem -LiteralPath $winDir -Filter '*.ps1') {
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($ps1.FullName)) {
    $n++
    if ($line -match '\$[A-Za-z_][A-Za-z0-9_]*\?(?!\.)') { $badInterp += "$($ps1.Name):$n" }
  }
}
Assert-Equal 0 $badInterp.Count "url: no bare `$var? interpolation in windows/*.ps1 (found: $($badInterp -join ', '))"

# --- Naming-model tripwires (distro / dir / data-disk unification) --------
# The WSL/Windows paths cannot execute on Linux, so these structural pins are
# the tests of record for the final naming model:
#   agents = distro agent-devbox      dir D:\WSL\agent-devbox
#   core   = distro agent-devbox-core dir D:\WSL\agent-devbox-core
#   data   = ext4 label AND mount name both `devbox-data` (unified)
$importText   = Get-Content -Raw (Join-Path $winDir 'import-distro.ps1')
$dataInitText = Get-Content -Raw (Join-Path $here '..' '..' 'scripts' 'datadisk-init.sh')

# Data-disk identity is unified on `devbox-data` (label + mount name).
Assert-True ($mainText -match 'devbox-data') 'name: installer uses devbox-data'
Assert-True ($mainText -match 'DATA_MNTNAME') 'name: installer writes DATA_MNTNAME'
Assert-True ($mainText -notmatch 'agent-devbox-data') 'name: installer drops the old agent-devbox-data'

# The logon mount task is attach-only. The PowerShell command that gets
# base64-encoded must use --bare (no --type ext4 / --name); the action itself
# must run it hidden via -EncodedCommand. (Asserting `--bare` on the
# New-ScheduledTaskAction line would be wrong: a base64 payload cannot contain
# that literal token, so the meaningful pin is the encoded `$cmd` string.)
$mountCmdLines = @([System.IO.File]::ReadAllLines($installer) | Where-Object { $_ -match '\$cmd\s*=' })
Assert-True ($mountCmdLines.Count -ge 1) 'name: installer builds the encoded mount command'
foreach ($cl in $mountCmdLines) {
  Assert-True ($cl -match '--bare') 'name: mount command uses --bare'
  Assert-True ($cl -notmatch '--type ext4') 'name: mount command has no --type ext4'
  Assert-True ($cl -notmatch '--name') 'name: mount command has no --name'
}
$actionLines = @([System.IO.File]::ReadAllLines($installer) | Where-Object { $_ -match 'New-ScheduledTaskAction' })
Assert-True ($actionLines.Count -ge 1) 'name: installer has a New-ScheduledTaskAction line'
foreach ($al in $actionLines) {
  Assert-True ($al -match '-EncodedCommand') 'name: mount task action encodes the command'
  Assert-True ($al -match '-WindowStyle Hidden') 'name: mount task action hides the console'
  Assert-True ($al -notmatch '--type ext4') 'name: mount task action has no --type ext4'
  Assert-True ($al -notmatch '--name') 'name: mount task action has no --name'
}
Assert-True ($mainText -match '-MultipleInstances IgnoreNew') 'name: mount task ignores new instances'

# Manual mount/unmount helpers are copied into the install dir and shipped in the zip.
Assert-True ($mainText -match 'mount-datadisk\.ps1') 'name: installer copies the mount helper'
Assert-True ($mainText -match 'unmount-datadisk\.cmd') 'name: installer copies the unmount helper'
foreach ($h in @('mount-datadisk.ps1', 'mount-datadisk.cmd', 'unmount-datadisk.ps1', 'unmount-datadisk.cmd')) {
  Assert-True ($ciText -match [regex]::Escape($h)) "name: build.yml bundles $h"
}

# The core variant names are wired through the installer.
Assert-True ($mainText -match 'agent-devbox-core') 'name: installer knows agent-devbox-core'
Assert-True ($mainText -match [regex]::Escape('D:\WSL\agent-devbox-core')) 'name: installer knows the core dir'
Assert-True ($mainText -match [regex]::Escape('agent-devbox-core-mount-datadisk')) 'name: installer knows the core task name'

# import-distro derives the distro/dir from the variant map.
Assert-True ($importText -match "'agent-devbox'") 'name: import-distro maps the agents distro'
Assert-True ($importText -match "'agent-devbox-core'") 'name: import-distro maps the core distro'

# install.ps1 derives $Distro from $Variant.
Assert-True ($webText -match "'agent-devbox-core'") 'name: install.ps1 derives the core distro name'

# datadisk-init takes the ext4 label as its first argument (no hardcoded name).
Assert-True ($dataInitText -match 'LABEL="\$\{1') 'name: datadisk-init takes the label as $1'
Assert-True ($dataInitText -notmatch 'LABEL=agent-devbox-data') 'name: datadisk-init has no hardcoded label'

Write-Host ''
if ($script:Failed -gt 0) {
  Write-Host "$script:Failed/$script:Total assertions FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "all $script:Total assertions passed" -ForegroundColor Green
exit 0
