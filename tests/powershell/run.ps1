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
# C6: release packaging.
$ciText = Get-Content -Raw (Join-Path $here '..' '..' '.github' 'workflows' 'build.yml')
Assert-True ($ciText -notmatch 'agent-devbox-windows\.zip') 'converge: build.yml no longer packages the Windows zip'
Assert-True ($ciText -notmatch '(?m)^\s*windows/install\.cmd\s*$') 'converge: build.yml no longer ships install.cmd'
Assert-True ($ciText -notmatch 'windows/import-distro\.ps1') 'converge: build.yml has no import-distro'
Assert-True ($ciText -match 'rootfs-\*-amd64\.tar\.zst\.part-\*') 'converge: build.yml keeps the rootfs parts'
Assert-True ($ciText -match 'agent-devbox-1panel-localapp\.zip') 'converge: build.yml keeps the 1panel zip'

# Converge: the removed installer entry points stay gone.
foreach ($gone in @('install.cmd', 'agent-devbox.bat', 'agent-devbox-core.bat', 'import-distro.ps1')) {
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $winDir $gone))) "converge: $gone is removed"
}

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
  # Huorong DELETES this file when it contains the literal `-UseBasicParsing`
  # token. A/B on 2026-10-21: token in the two calls -> quarantined before
  # dot-source; the same bytes without it -> dot-sources fine; a rewrite that only
  # moved the token into a comment -> quarantined again. So the invariant is "this
  # file must not contain the token anywhere", and an IWR hang must be fixed by a
  # structural change, not by adding it back.
  $ubp = @($helperText -split "`r?`n" | Where-Object { $_ -match '-UseBasicParsing' })
  Assert-Equal 0 $ubp.Count "av: helper must not contain -UseBasicParsing (found: $($ubp -join ' | '))"
}
Assert-True ($webText -match 'wsl-ensure-downloads\.ps1') 'converge: install.ps1 fetches the download helper'
# PS 5.1 hands `.Content` back as a byte[] for some responses; string-joining
# those bytes parses to zero manifest entries and the install dies with a bare
# exit code 1. Read the downloaded file instead (same pattern as the installer).
Assert-True ($webText -match 'ReadAllText\(\$sumsFile\)') 'sums: install.ps1 reads the manifest from disk (ReadAllText)'
Assert-True ($webText -notmatch '\$sumsText\s*=\s*\(Invoke-WebRequest') 'sums: install.ps1 never parses IWR .Content'
# The elevated child is a separate console: a pre-installer failure must be
# relayed to the original window, not just an exit code.
Assert-True ($webText -match '\$log\.err') 'diag: install.ps1 records the pre-installer failure detail'
Assert-True ($webText -match '失败原因') 'diag: the original window echoes the failure detail'

# Downloader: managed .NET (System.Net.Http), no external program. It resolves the
# Windows system proxy (WinINET/PAC), resumes with a Range request, prints
# progress + speed, and - the gate the old implementation lacked - verifies the
# final file length against the Release asset size. EOF alone is never success:
# a short file is resumed, never kept (an incomplete part broke the import).
Assert-True ($ensureText -match 'function Save-Download') 'dl: wsl-ensure has Save-Download'
$curlFiles = @(Get-ChildItem -LiteralPath $winDir -Filter '*.ps1' |
  Where-Object { (Get-Content -Raw $_.FullName) -match '(?i)curl' } | ForEach-Object { $_.Name })
Assert-Equal 0 $curlFiles.Count "dl: no curl in windows/*.ps1 (found: $($curlFiles -join ', '))"
Assert-True ($ensureText -match 'System\.Net\.Http\.HttpClient') 'dl: Save-Download uses managed HttpClient'
Assert-True ($ensureText -match 'Add-Type -AssemblyName System\.Net\.Http') 'dl: loads System.Net.Http without inline C#'
Assert-True ($ensureText -match 'GetSystemWebProxy') 'dl: resolves the Windows system proxy (WinINET/PAC)'
Assert-True ($ensureText -match 'Headers\.Range = \[System\.Net\.Http\.Headers\.RangeHeaderValue\]::new') 'dl: sends a typed Range request to resume'
Assert-True ($ensureText -match '\$end = if \(\$ExpectedBytes -gt \$have\)') 'dl: Range is closed (PS 5.1 cannot cast an open-ended To)'
Assert-True ($ensureText -match '\$null -eq \$cr\.From') 'dl: a 206 without Content-Range is rejected'
Assert-True ($ensureText -match 'ContentRange') 'dl: derives the total from Content-Range'
Assert-True ($ensureText -match 'ReadAsync') 'dl: streams with ReadAsync (stall guard)'
Assert-True ($ensureText -match 'ExpectedBytes') 'dl: accepts the expected asset size'
Assert-True ($ensureText -match '大小不符') 'dl: a length mismatch is a failure, not success'
Assert-True ($ensureText -match '无法确认下载完整性（缺少 -ExpectedBytes）') 'dl: the fallback fails closed without a size'
Assert-True ($ensureText -match 'Invoke-WebRequest -Uri \$Url -OutFile') 'dl: Save-Download falls back to Invoke-WebRequest'
Assert-True ($mainText -match 'Save-Download -Url \$p\.browser_download_url -Dest \$dest -ExpectedBytes') 'dl: installer passes the Release asset size'
$dlLines = [System.IO.File]::ReadAllLines($installer)
$sizeIdx = -1; $firstDlIdx = -1
for ($i = 0; $i -lt $dlLines.Count; $i++) {
  if ($sizeIdx -lt 0 -and $dlLines[$i] -match 'size -le 0') { $sizeIdx = $i }
  if ($firstDlIdx -lt 0 -and $dlLines[$i] -match 'Save-Download') { $firstDlIdx = $i }
}
Assert-True ($sizeIdx -ge 0 -and $firstDlIdx -ge 0 -and $sizeIdx -lt $firstDlIdx) 'dl: size guard precedes the download'
$pdIdx = -1; $dlCallIdx = -1
for ($i = 0; $i -lt $dlLines.Count; $i++) {
  if ($pdIdx -lt 0 -and $dlLines[$i] -match 'script:PartsDownloaded \+= \$dest') { $pdIdx = $i }
  if ($dlCallIdx -lt 0 -and $dlLines[$i] -match 'Save-Download -Url') { $dlCallIdx = $i }
}
Assert-True ($pdIdx -ge 0 -and $dlCallIdx -ge 0 -and $pdIdx -lt $dlCallIdx) 'dl: the part is registered before the download so the trap can clean it'

# --- 下载身份 / 条件续传 / 完整性 ------------------------------------------
# 真机事故：上一个 release tag 留下的 9 MiB 残片被新 tag 的字节续上，长度正确但内容混合，
# 于是 Tier 1/2/3 全败。修复 = 身份旁车 + If-Match 条件续传 + SHA256 校验。
Assert-True ($mainText -notmatch '已存在且完整') 'dl: no installer-side length-only "already complete" shortcut'
Assert-True ($mainText -match 'Save-Download[^\r\n]*-Sha256') 'dl: installer passes the expected SHA256'
Assert-True ($mainText -match 'SHA256SUMS') 'dl: installer fetches SHA256SUMS'
Assert-True ($mainText -match '该 Release 未提供 SHA256SUMS') 'dl: old releases still install (warn + length-only)'
Assert-True ($ensureText -match 'If-Match') 'dl: conditional resume uses If-Match'
# Only the header we actually SEND matters; the comment explaining why the other
# conditional header is unusable is allowed to name it.
Assert-True ($ensureText -notmatch "TryAddWithoutValidation\('If-Range'") 'dl: If-Range is never sent (GitHub/Azure ignore it)'
Assert-True ($ensureText -notmatch 'Headers\.IfRange') 'dl: no typed If-Range header either'
Assert-True ($ensureText -match 'TryAddWithoutValidation') 'dl: If-Match is sent as a raw header'
Assert-True ($ensureText -match 'identityRestarts') 'dl: the 412 restart path is bounded'
Assert-True ($ensureText -match '\$bar = ') 'dl: an inline progress bar is built'
Assert-True ($ensureText -match '\[\{1\}\] \{2,5:N1\}%') 'dl: the bar is printed on the download line with a percentage'
Assert-True ($ensureText -notmatch '(?m)^\s*Write-Progress\b') 'dl: no top-of-console Write-Progress (it is invisible in the relayed log)'
Assert-True ($ensureText -match 'IsOutputRedirected') 'dl: a console is detected (in-place updates)'
Assert-True ($ensureText -match '\[Console\]::Write') 'dl: the in-place update bypasses the transcript (Console.Write)'
Assert-True ($ensureText -notmatch '\$lastBucket') 'dl: no periodic duplicate lines (one line, rewritten in place)'
Assert-True ($ensureText -match '`r') 'dl: the in-place rewrite uses a carriage return'
Assert-True ($ensureText -match '没有可用的下载记录') 'dl: a partial without identity is discarded'
Assert-True ($ensureText -match 'Get-FileSha256') 'dl: SHA256 is verified after the length gate'
Assert-True ($ensureText -match 'ConvertFrom-Sha256Sums') 'dl: SHA256SUMS parser present'
Assert-True ($mainText -match 'Format-NativeOutput') 'diag: native tool output is surfaced'
Assert-True ($mainText -match 'Clear-StaleImportArtifacts') 'diag: stale ext4.vhdx is cleaned before the next tier'
$badImportLines = @($dlLines | Where-Object { ($_ -match '--import' -or $_ -match '\$zstdExe') -and $_ -match 'Out-Null' })
Assert-Equal 0 $badImportLines.Count "diag: no import/zstd output piped to Out-Null (found: $($badImportLines -join ' | '))"
$diskCallLines = @($dlLines | Where-Object { $_ -match '^\s*Assert-DiskSpace\s' -and $_ -notmatch '\| Out-Null' })
Assert-Equal 0 $diskCallLines.Count "diag: Assert-DiskSpace never leaks True (found: $($diskCallLines -join ' | '))"
Assert-True ($ciText -match 'sha256sum rootfs-\*-amd64\.tar\.zst\.part-\*') 'ci: publishes SHA256SUMS'
Assert-True ($ciText -match '(?m)^\s*SHA256SUMS\s*$') 'ci: uploads SHA256SUMS as a Release asset'

# --- 升级是幂等的：不重设密码、不需要按 y ----------------------------------
# 密码唯一来源是数据盘（跨升级保留）。旧系统盘的 conf 读取已删除：它会为了 cat 一个文件
# 把旧发行版整机拉起（[boot] 顺带 mount 数据盘 + 起 paseo），升级时多一次无谓的启停。
Assert-True ($mainText -notmatch 'existingPw') 'upgrade: the installer no longer reads the old system-disk conf'
Assert-True ($mainText -match "'--unregister'") 'upgrade: the old distro is unregistered for the upgrade'
Assert-True ($mainText -notmatch '\[Y/n\]|\[y/N\]') 'upgrade: no y/N reinstall prompt'
Assert-True ($mainText -match 'KeepExisting') 'upgrade: overwrite is the default (-KeepExisting opts out)'
Assert-True ($mainText -match '\.paseo-password') 'upgrade: the password is stored on the data disk'
Assert-True ($mainText -match 'blkid -U') 'upgrade: the data disk is mounted by UUID to read/write the password'
Assert-True ($mainText -match 'mountpoint -q') 'upgrade: mounting is idempotent (mountpoint -q)'

# --- 安装器不变量（原先重复写在 build.yml 的 tripwire 里，已合并到这里）-----
Assert-True ($mainText -notmatch 'Read-Host[^\r\n]*重装') 'inv: no interactive reinstall prompt'
Assert-True ($mainText -match 'Assert-DiskSpace') 'inv: disk space is checked before download'
Assert-True ($mainText -match 'Invoke-WslImportStream') 'inv: parts are streamed into wsl --import'
Assert-True ($mainText -match 'Assert-DataDiskMounted') 'inv: the data disk is verified after restart'
foreach ($p in @('install.ps1', 'install-agent-devbox.ps1')) {
  $t = if ($p -eq 'install.ps1') { $webText } else { $mainText }
  foreach ($line in ($t -split "`r?`n")) {
    if ($line -match '-Verb\s+RunAs') {
      Assert-True ($line -match '-Wait') "inv: $p uses -Verb RunAs with -Wait"
    }
  }
}
Assert-True ($webText -match '\$ScriptsBase\s*=\s*[^\r\n]*\$Ref') 'inv: install.ps1 builds ScriptsBase from $Ref'
Assert-True ($webText.Contains("'-Ref', `$Ref")) 'inv: install.ps1 forwards -Ref to the elevated child'
foreach ($needle in @('SHA256SUMS', 'Get-FileHash', 'AllowUnverifiedScripts')) {
  Assert-True ($webText.Contains($needle)) "inv: install.ps1 verifies siblings ($needle)"
}

$diskPwIdx = -1
for ($i = 0; $i -lt $dlLines.Count; $i++) {
  if ($diskPwIdx -lt 0 -and $dlLines[$i] -match 'if \(\$dataDiskPw\)') { $diskPwIdx = $i }
}
Assert-True ($diskPwIdx -ge 0) 'upgrade: the data-disk password is the only upgrade source'
Assert-True ($mainText -match '升级未能从数据盘读回') 'upgrade: a missing data-disk password is surfaced (never silent)'
$pwWriteIdx = -1; $unmountIdx = -1
for ($i = 0; $i -lt $dlLines.Count; $i++) {
  if ($pwWriteIdx -lt 0 -and $dlLines[$i] -match 'printf %s \{0\} > \{1\}') { $pwWriteIdx = $i }
  if ($unmountIdx -lt 0 -and $dlLines[$i] -match "'--unmount'") { $unmountIdx = $i }
}
Assert-True ($pwWriteIdx -ge 0 -and $unmountIdx -ge 0 -and $pwWriteIdx -lt $unmountIdx) 'upgrade: the data disk is unmounted only after the password is written'

# --- 纯函数：sidecar / 身份判定 / SHA256SUMS / 哈希 / 原生输出 -------------
$qa = Join-Path ([System.IO.Path]::GetTempPath()) ('adbox-unit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $qa -Force | Out-Null
try {
  $shaA = ('a' * 64) -join ''
  $shaB = ('b' * 64) -join ''
  $part = Join-Path $qa 'rootfs-core-amd64.tar.zst.part-00'
  $meta = Get-DownloadMetaPath -Dest $part
  Assert-Equal (Join-Path $qa '.agent-devbox-download') (Split-Path -Parent $meta) 'id: sidecar lives in .agent-devbox-download'
  Assert-Equal 'rootfs-core-amd64.tar.zst.part-00.meta' (Split-Path -Leaf $meta) 'id: sidecar leaf name'
  [System.IO.File]::WriteAllText($part, 'x')
  Write-DownloadSidecar -Path $meta -Url 'http://h/a' -ETag '"v1"' -Length 12 -Sha256 $shaA -Complete $false
  $globbed = @(Get-ChildItem -Path $qa -Filter 'rootfs-core-amd64.tar.zst.part-*')
  Assert-Equal 1 $globbed.Count 'id: sidecar cannot be picked up by the part glob'
  $bytes = [System.IO.File]::ReadAllBytes($meta)
  Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'id: sidecar has no BOM'
  $s = Read-DownloadSidecar -Path $meta
  Assert-Equal 'http://h/a' $s.url 'id: sidecar round-trip url'
  Assert-Equal '"v1"' $s.etag 'id: sidecar round-trip etag'
  Assert-Equal ([long]12) $s.length 'id: sidecar round-trip length'
  Assert-True (Test-DownloadSidecarIdentity -Sidecar $s -Url 'http://h/a' -Length 12 -Sha256 $shaA) 'id: matching identity accepted'
  Assert-True (-not (Test-DownloadSidecarIdentity -Sidecar $s -Url 'http://h/b' -Length 12)) 'id: a different url is rejected'
  Assert-True (-not (Test-DownloadSidecarIdentity -Sidecar $s -Url 'http://h/a' -Length 13)) 'id: a different length is rejected'
  Assert-True (-not (Test-DownloadSidecarIdentity -Sidecar $s -Url 'http://h/a' -Length 12 -Sha256 $shaB)) 'id: a different digest is rejected'
  Assert-True (-not (Test-DownloadSidecarIdentity -Sidecar $null -Url 'http://h/a' -Length 12)) 'id: a missing sidecar is rejected'
  # A sidecar that recorded no digest cannot prove identity when the caller
  # knows the expected digest (e.g. the manifest gained sums after the fact).
  $emptyMeta = [pscustomobject]@{ url = 'http://h/a'; length = [long]12; sha256 = '' }
  Assert-True (-not (Test-DownloadSidecarIdentity -Sidecar $emptyMeta -Url 'http://h/a' -Length 12 -Sha256 $shaA)) 'id: an empty recorded digest is rejected when a digest is known'
  Assert-True (Test-DownloadSidecarIdentity -Sidecar $emptyMeta -Url 'http://h/a' -Length 12) 'id: an empty recorded digest is accepted when the caller has none'
  Assert-True ($null -eq (Read-DownloadSidecar -Path (Join-Path $qa 'nope.meta'))) 'id: a missing sidecar reads as null'
  [System.IO.File]::WriteAllText($meta, '{not json')
  Assert-True ($null -eq (Read-DownloadSidecar -Path $meta)) 'id: a corrupt sidecar reads as null'

  $sums = ConvertFrom-Sha256Sums -Text ("{0}  rootfs-core-amd64.tar.zst.part-00`r`n{1} *rootfs-core-amd64.tar.zst.part-01`n`n# junk`n" -f (('1' * 64) -join ''), (('2' * 64) -join ''))
  Assert-Equal 2 $sums.Count 'sums: parses two entries'
  Assert-Equal (('2' * 64) -join '') $sums['rootfs-core-amd64.tar.zst.part-01'] 'sums: bare filename key, * stripped'
  Assert-Equal 0 (@(Get-MissingSha256Parts -ShaMap $sums -Names @('rootfs-core-amd64.tar.zst.part-00', 'rootfs-core-amd64.tar.zst.part-01')).Count) 'sums: full coverage reports no missing parts'
  Assert-Equal 0 (ConvertFrom-Sha256Sums -Text '').Count 'sums: an empty manifest parses to zero entries (guard must fire)'
  Assert-True ($mainText -match '\[System\.IO\.File\]::ReadAllText\(\$shaPath\)') 'dl: a 0-byte manifest is read as empty text, not $null'
  Assert-Equal 'rootfs-core-amd64.tar.zst.part-09' (@(Get-MissingSha256Parts -ShaMap $sums -Names @('rootfs-core-amd64.tar.zst.part-00', 'rootfs-core-amd64.tar.zst.part-09'))[0]) 'sums: an uncovered part is reported'
  Assert-Equal 1 (@(Get-MissingSha256Parts -ShaMap @{} -Names @('a')).Count) 'sums: an empty manifest covers nothing'
  # Stale-vhdx cleanup must fail closed when the listing itself failed.
  Assert-True (Test-DistroListed -List @('agent-devbox') -ExitCode 1 -Distro 'agent-devbox-core') 'vhd: an unknown listing counts as registered'
  Assert-True (Test-DistroListed -List @('agent-devbox-core') -ExitCode 0 -Distro 'agent-devbox-core') 'vhd: a listed distro is detected'
  Assert-True (-not (Test-DistroListed -List @('agent-devbox-core') -ExitCode 0 -Distro 'agent-devbox')) 'vhd: an absent distro is detected only on a successful listing'
  $abc = Join-Path $qa 'abc.bin'
  [System.IO.File]::WriteAllText($abc, 'abc')
  Assert-Equal 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (Get-FileSha256 -Path $abc) 'sha: known vector'
  Assert-Equal '' (Format-NativeOutput -Output $null) 'native: null -> empty'
  $fmt = Format-NativeOutput -Output (1..30 | ForEach-Object { "line$_" }) -MaxLines 5
  Assert-Equal 5 (@($fmt -split "`n").Count) 'native: bounded to MaxLines'
  Assert-True ($fmt -match 'line30') 'native: keeps the last line'
} finally {
  Remove-Item -LiteralPath $qa -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 下载失败的可读原因（AggregateException 解包） ------------------------
# 2026-10-20 的安装日志里重试告警只剩 PowerShell 的包装套话
# （使用“1”个参数调用“Wait”时发生异常:“发生一个或多个错误。”），真正原因被吞掉了。
$stallInner = New-Object System.Management.Automation.RuntimeException('传输停滞（30 秒无数据）')
$aggStall   = New-Object System.AggregateException('发生一个或多个错误。', $stallInner)
$wrapped    = New-Object System.Management.Automation.MethodInvocationException('使用“1”个参数调用“Wait”时发生异常:“发生一个或多个错误。”', $aggStall)
Assert-Equal '传输停滞（30 秒无数据）' (Format-DownloadErrorMessage -Exception $wrapped) 'dl-err: the inner stall reason wins'
$closedInner = New-Object System.IO.IOException('无法从传输连接读取数据: 连接被意外关闭。')
$aggClosed   = New-Object System.AggregateException('发生一个或多个错误。', $closedInner)
$wrapped2    = New-Object System.Management.Automation.MethodInvocationException('使用“1”个参数调用“Wait”时发生异常:“发生一个或多个错误。”', $aggClosed)
Assert-Equal '连接被意外关闭（无法从传输连接读取数据）' (Format-DownloadErrorMessage -Exception $wrapped2) 'dl-err: unexpected close is mapped to a readable reason'
Assert-Equal 'boom' (Format-DownloadErrorMessage -Exception (New-Object System.Exception('boom'))) 'dl-err: a plain exception passes through'
Assert-Equal '未知错误' (Format-DownloadErrorMessage -Exception $null) 'dl-err: null exception is safe'

# --- 变体名不再写死（core / agents 两个名字） -------------------------------
# 文档里曾经所有命令都写死 `wsl -d agent-devbox`，装的是 core 时一条都粘不了。
# 现在统一先解析 $Distro；安装器负责把新导入的发行版设为默认（重装会换 GUID）。
$readmeText  = Get-Content -Raw (Join-Path $here '..' '..' 'README.md')
$installDoc  = Get-Content -Raw (Join-Path $here '..' '..' 'docs' 'installation-wsl.md')
$persistDoc  = Get-Content -Raw (Join-Path $here '..' '..' 'docs' 'wsl-persistence.md')
Assert-True ($readmeText -match '\$Distro') 'variant: README resolves the distro name once'
Assert-True ($installDoc -match '\$Distro') 'variant: installation-wsl resolves the distro name once'
Assert-True ($persistDoc -match '\$Distro') 'variant: wsl-persistence resolves the distro name once'
Assert-True ($readmeText -notmatch 'wsl -d agent-devbox -u root') 'variant: README has no hardcoded agents distro in runnable commands'
Assert-True ($mainText -notmatch '@\(.--set-default., \$Distro\)') 'variant: the installer never changes the user default distro'
Assert-True ($mainText -notmatch 'Remove-Item -LiteralPath \$uiMeta') 'variant: the installer does not delete another app cache'
Assert-True ($mainText -match 'wsl-ui\\distro-metadata\.json') 'variant: the manual wsl-ui cache hint is printed'

# --- Windows Terminal profile：固定 GUID（安装器写 fragment） ---------------
# WSL 每次 import 都按注册表 GUID 生成 profile -> 重装换 GUID、用户自定义留在旧条目。
# 镜像关掉 WSL 的生成器，安装器写一条固定 GUID 的 fragment（按发行版名字启动）。
$wslDistConf = Get-Content -Raw (Join-Path $here '..' '..' 'config' 'wsl-distribution.conf')
Assert-True ($wslDistConf -match '\[windowsterminal\]') 'wt: the image configures WSL windowsterminal'
Assert-True ($wslDistConf -match 'enabled\s*=\s*false') 'wt: windowsterminal.enabled is false'
$dockerText = Get-Content -Raw (Join-Path $here '..' '..' 'Dockerfile')
Assert-True ($dockerText -match 'config/wsl-distribution\.conf /etc/wsl-distribution\.conf') 'wt: the Dockerfile ships wsl-distribution.conf'
$repairPath = Join-Path $winDir 'repair-terminal-profiles.ps1'
Assert-True (-not (Test-Path -LiteralPath $repairPath)) 'wt: the old profile-repair script stays deleted'
Assert-True ($mainText -match 'Write-AgentDevboxTerminalProfile') 'wt: the installer writes its own fragment'
Assert-True ($mainText -match 'Remove-StaleWslTerminalFragments') 'wt: the installer removes WSL-generated fragments'
Assert-True ($mainText -match "'\{6f4a1c2e-8b3d-4a97-9c51-0e7d2b8f3a64\}'") 'wt: the agents profile GUID is fixed'
Assert-True ($mainText -match "'\{c2d7e9a4-3f61-4b08-8e52-7a1d9c4b6f30\}'") 'wt: the core profile GUID is fixed'
$writeIdx = $mainText.IndexOf('Write-AgentDevboxTerminalProfile -Distro $Distro -ProfileGuid')
$importIdx = $mainText.IndexOf("Step '[4/10]")
Assert-True ($writeIdx -ge 0 -and $importIdx -gt $writeIdx) 'wt: the fragment is written BEFORE the import'
Assert-True ($mainText -match 'PSChildName') 'variant: installer reports the new distro GUID'
$fragJson = New-TerminalProfileFragment -Distro 'agent-devbox-core' `
  -ProfileGuid '{11111111-2222-3333-4444-555555555555}' `
  -HideGuid '{66666666-7777-8888-9999-000000000000}' `
  -StartingDirectory '\\wsl$\agent-devbox-core\root'
$fragObj = $fragJson | ConvertFrom-Json
Assert-Equal 2 @($fragObj.profiles).Count 'wt: fragment has a hide entry + one profile'
Assert-Equal '{66666666-7777-8888-9999-000000000000}' "$($fragObj.profiles[0].updates)" 'wt: the tier1 profile is hidden via updates'
Assert-Equal $true ([bool]$fragObj.profiles[0].hidden) 'wt: the hide entry is hidden=true'
Assert-Equal '{11111111-2222-3333-4444-555555555555}' "$($fragObj.profiles[1].guid)" 'wt: the fragment GUID is the fixed one'
Assert-Equal 'agent-devbox-core' "$($fragObj.profiles[1].name)" 'wt: the profile name is the distro'
Assert-True ("$($fragObj.profiles[1].commandline)" -match 'wsl\.exe -d agent-devbox-core') 'wt: launch is name-based'
Assert-True ("$($fragObj.profiles[1].commandline)" -notmatch '--distribution-id') 'wt: launch does not depend on the registration GUID'
Assert-Equal '\\wsl$\agent-devbox-core\root' "$($fragObj.profiles[1].startingDirectory)" 'wt: startingDirectory targets the distro root'

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
$dataInitText = Get-Content -Raw (Join-Path $here '..' '..' 'scripts' 'datadisk-init.sh')

# Data-disk identity is unified on `devbox-data` (label + mount name).
Assert-True ($mainText -match 'devbox-data') 'name: installer uses devbox-data'
Assert-True ($mainText -match 'DATA_MNTNAME') 'name: installer writes DATA_MNTNAME'
Assert-True ($mainText -notmatch 'agent-devbox-data') 'name: installer drops the old agent-devbox-data'

# The logon mount task runs the copied attach helper. The helper retries, logs
# every attempt and exits with wsl's real code: `-EncodedCommand "& wsl.exe
# --mount ..."` always exits 0, which made a failed attach look successful
# (2026-10-21: core booted into MAINTENANCE MODE after an upgrade).
$argsLines = @([System.IO.File]::ReadAllLines($installer) | Where-Object { $_ -match '^\s*\$actionArgs\s*=' })
Assert-Equal 1 $argsLines.Count 'name: the task arguments are built exactly once'
Assert-True ($argsLines[0] -match '-File') 'name: mount task action runs a script file'
Assert-True ($argsLines[0] -match '\$attachScript') 'name: mount task action points at the attach helper'
Assert-True ($mainText -match 'attachScript\s*=\s*Join-Path[^\r\n]*mount-datadisk\.ps1') 'name: the attach helper is mount-datadisk.ps1'
Assert-True ($argsLines[0] -match '-WindowStyle Hidden') 'name: mount task action hides the console'
Assert-True ($argsLines[0] -notmatch '-EncodedCommand') 'name: mount task never hides wsl failures behind EncodedCommand'
$mountHelper = Get-Content -Raw (Join-Path $winDir 'mount-datadisk.ps1')
Assert-True ($mountHelper -match "'--bare'") 'name: attach helper uses --bare'
Assert-True ($mountHelper -match '\$attempts\s*=\s*3') 'name: attach helper retries the attach'
Assert-True ($mountHelper -match 'datadisk-attach\.log') 'name: attach helper logs every attempt'
Assert-True ($mountHelper -match 'exit \$result\.ExitCode') 'name: attach helper propagates the real exit code'
Assert-True ($mainText -match '@\(''--mount'', ''--vhd'', \$VhdxPath, ''--bare''\)') 'name: installer attaches the disk itself before restarting'
Assert-True ($mainText -match 'Assert-DataDiskMounted') 'name: installer verifies the mount after the restart'
Assert-True ([bool](Get-Command Assert-DataDiskMounted -ErrorAction SilentlyContinue)) 'name: Assert-DataDiskMounted helper is defined'
# wsl --shutdown 只允许出现在「镜像网络改完 -> 用户明确 y/N 确认」这一条路径；
# 其它脚本一律不得出现，日常停止只用 wsl --terminate <发行版>。
foreach ($f in Get-ChildItem $winDir -Filter *.ps1) {
  if ($f.Name -eq 'wsl-ensure.ps1') { continue }
  $t = Get-Content -Raw $f.FullName
  Assert-True ($t -notmatch '--shutdown') "shutdown: $($f.Name) never touches wsl --shutdown"
}
$ensureText = Get-Content -Raw (Join-Path $winDir 'wsl-ensure.ps1')
Assert-Equal 1 ([regex]::Matches($ensureText, "Invoke-Native 'wsl\.exe' @\('--shutdown'\)").Count) 'shutdown: exactly one gated wsl --shutdown call'
Assert-True ($ensureText -match "Resolve-YesNoDefault[\s\S]{0,600}Invoke-Native 'wsl\.exe' @\('--shutdown'\)") 'shutdown: the call requires an explicit y/N confirmation'
Assert-True ($ensureText -match 'if \(\$Unattended\)[\s\S]{0,300}return') 'shutdown: unattended runs never shut WSL down'
Assert-True ($ensureText -match '会关闭所有正在运行的 WSL 发行版') 'shutdown: the warning names the impact'
Assert-True ($mainText -match 'bootLinesBefore') 'name: installer records the boot-log line count before restarting'
Assert-True ($mainText -match 'Assert-DataDiskMounted -Distro \$Distro -MountName \$MountName -SinceLine') 'name: the mount assertion trusts only the NEW boot log lines'
$actionLines = @([System.IO.File]::ReadAllLines($installer) | Where-Object { $_ -match 'New-ScheduledTaskAction' })
Assert-True ($actionLines.Count -ge 1) 'name: installer has a New-ScheduledTaskAction line'
foreach ($al in $actionLines) {
  Assert-True ($al -match '-Argument \$actionArgs') 'name: the action uses the prebuilt argument string'
}
Assert-True ($mainText -match '-MultipleInstances IgnoreNew') 'name: mount task ignores new instances'

# Manual mount/unmount helpers are copied into the install dir and fetched by install.ps1.
Assert-True ($mainText -match 'mount-datadisk\.ps1') 'name: installer copies the mount helper'
Assert-True ($mainText -match 'unmount-datadisk\.cmd') 'name: installer copies the unmount helper'
foreach ($h in @('mount-datadisk.ps1', 'mount-datadisk.cmd', 'unmount-datadisk.ps1', 'unmount-datadisk.cmd')) {
  Assert-True ($webText -match [regex]::Escape($h)) "converge: install.ps1 fetches $h"
}

# The core variant names are wired through the installer.
Assert-True ($mainText -match 'agent-devbox-core') 'name: installer knows agent-devbox-core'
Assert-True ($mainText -match [regex]::Escape('D:\WSL\agent-devbox-core')) 'name: installer knows the core dir'
Assert-True ($mainText -match [regex]::Escape('agent-devbox-core-mount-datadisk')) 'name: installer knows the core task name'

# install.ps1 derives $Distro from $Variant.
Assert-True ($webText -match "'agent-devbox-core'") 'name: install.ps1 derives the core distro name'

# datadisk-init takes the ext4 label as its first argument (no hardcoded name).
Assert-True ($dataInitText -match 'LABEL="\$\{1') 'name: datadisk-init takes the label as $1'
Assert-True ($dataInitText -notmatch 'LABEL=agent-devbox-data') 'name: datadisk-init has no hardcoded label'

# Installer hardening (New-VHD / persistent log / task verification).
Assert-True ($mainText -match 'Get-Command\s+New-VHD') 'fix: installer probes Get-Command New-VHD'
Assert-True ($mainText -notmatch '可能是 Windows 家庭版') 'fix: installer does not guess the Windows edition'
Assert-True ($mainText -match 'diskpart 创建数据磁盘失败') 'fix: diskpart create exit code is checked'
Assert-True ($mainText -match '数据磁盘创建后不存在或为空') 'fix: created VHDX is verified non-empty'
Assert-True ($mainText -match 'script:InstallLog') 'log: persistent InstallDir log path'
Assert-True ($mainText -match 'Start-Transcript -Path \$script:InstallLog') 'log: transcript can start at the InstallDir log'
Assert-True ($mainText -match 'Copy-Item -LiteralPath \$LogPath -Destination \$script:InstallLog') 'log: relay log copied into the InstallDir'
Assert-True ($mainText -match 'cat /etc/agent-devbox.conf') 'log: password retrieval command is shown'
Assert-True ($mainText -notmatch '已生成 paseo 密码：') 'log: password is never printed'
Assert-True ($mainText -match 'Get-ScheduledTaskInfo') 'task: registration result is checked'
Assert-True ($mainText -match 'needRegister') 'task: registration is idempotent (needRegister gate)'
Assert-True ($mainText -match '跳过重复注册') 'task: an identical task is not re-registered'
Assert-Equal 1 ([regex]::Matches($mainText, 'Register-ScheduledTask -TaskName').Count) 'task: exactly one Register-ScheduledTask call'
$checkIdx = $mainText.IndexOf('$existingTask = Get-ScheduledTask')
$regIdx   = $mainText.IndexOf('Register-ScheduledTask -TaskName')
Assert-True ($checkIdx -ge 0 -and $regIdx -ge 0 -and $checkIdx -lt $regIdx) 'task: the existing task is inspected BEFORE registering'
$gateIdx  = $mainText.IndexOf('if ($needRegister) {')
$unregIdx = $mainText.IndexOf('Unregister-ScheduledTask -TaskName')
Assert-True ($gateIdx -ge 0 -and $unregIdx -ge 0 -and $gateIdx -lt $unregIdx) 'task: unregister only happens on a real change'
Assert-True ($mainText -match 'Start-Sleep -Seconds 10') 'task: interactive hold is present'
Assert-True ($mainText -match '火绒') 'task: AV allow prompt is present'
Assert-True ($mainText -match '-not \$Yes') 'task: hold is gated on -not $Yes'
# 电池策略：New-ScheduledTaskSettingsSet 默认禁用电池启动（DisallowStartIfOnBatteries=
# StopIfGoingOnBatteries=$true）。笔记本拔电登录 -> 任务不跑 -> 数据盘没附加 -> 维护模式。
Assert-True ($mainText -match '-AllowStartIfOnBatteries') 'task: the logon task starts on battery'
Assert-True ($mainText -match '-DontStopIfGoingOnBatteries') 'task: the logon task is not stopped on battery'
Assert-True ($mainText -match 'DisallowStartIfOnBatteries') 'task: idempotence compares DisallowStartIfOnBatteries'
Assert-True ($mainText -match 'StopIfGoingOnBatteries') 'task: idempotence compares StopIfGoingOnBatteries'
# 残留任务清理：任务名带变体名；只清「发行版已注销」或「VHDX 不存在」的条目。
Assert-True ($mainText -match "agent-devbox\.\*-mount-datadisk") 'task: stale mount tasks are discovered by name'
Assert-True ($mainText -match 'Unregister-ScheduledTask -TaskName \$staleTask') 'task: stale mount tasks are unregistered'
Assert-True ($mainText.Contains('if ($staleTask.TaskName -eq $TaskName) { continue }')) 'task: the task being installed is never cleaned up'


Write-Host ''
if ($script:Failed -gt 0) {
  Write-Host "$script:Failed/$script:Total assertions FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "all $script:Total assertions passed" -ForegroundColor Green
exit 0
