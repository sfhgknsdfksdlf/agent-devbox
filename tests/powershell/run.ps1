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

Write-Host ''
if ($script:Failed -gt 0) {
  Write-Host "$script:Failed/$script:Total assertions FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "all $script:Total assertions passed" -ForegroundColor Green
exit 0
