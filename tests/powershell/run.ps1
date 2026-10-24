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

# --- Resolve-UpgradeAnswer (Workstream A) ---------------------------------
# Deliberately NOT a y/N prompt: Enter (or blank) is the only affirmative;
# anything unrecognised is re-asked once by Confirm-Upgrade, then treated as cancel.
Assert-Equal 'upgrade' (Resolve-UpgradeAnswer '') 'upgrade-answer: Enter -> upgrade'
Assert-Equal 'upgrade' (Resolve-UpgradeAnswer '   ') 'upgrade-answer: blank -> upgrade'
Assert-Equal 'cancel' (Resolve-UpgradeAnswer 'n') 'upgrade-answer: n -> cancel'
Assert-Equal 'cancel' (Resolve-UpgradeAnswer 'N') 'upgrade-answer: N -> cancel'
Assert-Equal 'cancel' (Resolve-UpgradeAnswer 'no') 'upgrade-answer: no -> cancel'
Assert-Equal 'cancel' (Resolve-UpgradeAnswer ' NO ') 'upgrade-answer: trimmed/case-insensitive no -> cancel'
Assert-Equal 'again' (Resolve-UpgradeAnswer 'yes') 'upgrade-answer: yes is not affirmative -> again'
Assert-Equal 'again' (Resolve-UpgradeAnswer 'y') 'upgrade-answer: y is not affirmative -> again'
Assert-Equal 'again' (Resolve-UpgradeAnswer 'x') 'upgrade-answer: unknown -> again'

# --- Write-CancelRelay (Workstream A) -------------------------------------
$relayBase = Join-Path ([System.IO.Path]::GetTempPath()) ('adbox-cancel-' + [guid]::NewGuid().ToString('N'))
$relayLog  = Join-Path (Join-Path $relayBase 'sub') 'install.log'
try {
  Write-CancelRelay -LogPath $relayLog -Message '已取消升级：未下载、未注销、未做任何更改。'
  Assert-True (Test-Path -LiteralPath $relayLog) 'cancel: the relay log (and its parent dir) is created'
  Assert-Equal '已取消升级：未下载、未注销、未做任何更改。' ((Get-Content -LiteralPath $relayLog -Raw).Trim()) 'cancel: the message is appended to the relay log'
  Assert-Equal '0' (Get-Content -LiteralPath "$relayLog.rc" -Raw) 'cancel: the rc marker is 0 (nothing failed)'
  Assert-Equal '1' (Get-Content -LiteralPath "$relayLog.cancel" -Raw) 'cancel: the cancel marker is 1'
  $relayBytes = [System.IO.File]::ReadAllBytes($relayLog)
  Assert-True (-not ($relayBytes.Length -ge 3 -and $relayBytes[0] -eq 0xEF -and $relayBytes[1] -eq 0xBB -and $relayBytes[2] -eq 0xBF)) 'cancel: the relay log has no BOM'
  Write-CancelRelay -LogPath $relayLog -Message '第二次取消'
  Assert-Equal 2 (@(Get-Content -LiteralPath $relayLog).Count) 'cancel: a later cancel appends instead of overwriting'
  Write-CancelRelay -LogPath '' -Message 'no-op'
  Assert-True $true 'cancel: an empty LogPath is a no-op (no throw)'
} finally {
  Remove-Item -LiteralPath $relayBase -Recurse -Force -ErrorAction SilentlyContinue
}

# --- UI 宽度 / 换行（Workstream B，S11）-------------------------------------
# 显示宽度必须按「单元格」算：全角中文 2 格、ASCII 1 格。String.Length 是字符数，
# 拿它当宽度会让中文行溢出。
Assert-Equal 7 (Get-UiTextWidth '中文abc') 'ui: CJK = 2 cells, ASCII = 1 cell'
Assert-Equal 3 (Get-UiTextWidth 'abc') 'ui: ASCII width == character count'
Assert-Equal 4 (Get-UiTextWidth '中文') 'ui: each CJK character is 2 cells'
Assert-Equal 0 (Get-UiTextWidth '') 'ui: empty text has zero width'
$uiLineW = Get-UiLineWidth
Assert-True ($uiLineW -ge 60 -and $uiLineW -le 100) "ui: Get-UiLineWidth is clamped to [60,100] (got $uiLineW)"

$cjkText = '这是一段很长的中文句子，用来测试自动换行是否遵守宽度限制，并且避免行首出现标点符号。'
$cjkLines = @(Split-UiText -Text $cjkText -Width 12)
$cjkWide = @($cjkLines | Where-Object { (Get-UiTextWidth $_) -gt 12 })
Assert-Equal 0 $cjkWide.Count "ui: every wrapped line fits 12 cells (found: $($cjkWide -join ' | '))"
$cjkBadStart = @($cjkLines | Where-Object { $_ -match '^[。，、；：！？）》」』】〕〉…,.;:!?\)\]\}]' })
Assert-Equal 0 $cjkBadStart.Count "ui: no line starts with closing punctuation (found: $($cjkBadStart -join ' | '))"
Assert-True (@($cjkLines).Count -gt 1) 'ui: a long Chinese sentence actually wraps'

# 保护词永不被拆开（即使宽于目标宽度）。
$keepDisk = @(Split-UiText -Text '磁盘空间不足，请清理后重试' -Width 6)
Assert-Equal 1 (@($keepDisk | Where-Object { $_.Contains('磁盘空间不足') }).Count) 'ui: 磁盘空间不足 stays whole'
$keepStep = @(Split-UiText -Text '请运行 [1/10] 步骤' -Width 4)
Assert-Equal 1 (@($keepStep | Where-Object { $_.Contains('[1/10]') }).Count) 'ui: [n/10] stays whole'

# 未受保护的长路径允许按单元格硬切，但每行仍不得超过宽度。
$longPath = 'D:\WSL\agent-devbox\data\rootfs-amd64.tar.zst'
$pathLines = @(Split-UiText -Text "安装目录：$longPath" -Width 12)
$pathWide = @($pathLines | Where-Object { (Get-UiTextWidth $_) -gt 12 })
Assert-Equal 0 $pathWide.Count "ui: a long path is hard-split within the width (found: $($pathWide -join ' | '))"
Assert-Equal 1 (@($pathLines | Where-Object { $_.Contains('rootfs') }).Count) 'ui: the hard split still yields the path fragments'

# 已有的换行符原样保留为独立输出行。
Assert-Equal 2 (@(Split-UiText -Text "a`nb" -Width 80).Count) 'ui: embedded newlines become separate lines'

# --- Workstream C：导入清理计划（S10）--------------------------------------
# 纯决策：网络/导入失败必须保留分片+sidecar 让下一次续传；只有「已导入」或
# 「内容可疑」才删除本次下载的分片；预置分片永不由清理删除。
$plan = Get-ImportCleanupPlan -Attempted $true -Imported $true -PartsWerePreexisting $false -ContentSuspect $false
Assert-True ($plan.RemoveMerged -and $plan.RemoveParts -and -not $plan.KeepParts) 'cleanup: success removes this run''s parts'
$plan = Get-ImportCleanupPlan -Attempted $true -Imported $false -PartsWerePreexisting $false -ContentSuspect $false
Assert-True ($plan.RemoveMerged -and -not $plan.RemoveParts -and $plan.KeepParts) 'cleanup: import failure keeps parts for identity-checked resume'
$plan = Get-ImportCleanupPlan -Attempted $true -Imported $true -PartsWerePreexisting $true -ContentSuspect $false
Assert-True ($plan.RemoveMerged -and -not $plan.RemoveParts -and -not $plan.KeepParts) 'cleanup: pre-existing parts are never removed'
$plan = Get-ImportCleanupPlan -Attempted $true -Imported $false -PartsWerePreexisting $false -ContentSuspect $true
Assert-True ($plan.RemoveMerged -and $plan.RemoveParts -and -not $plan.KeepParts) 'cleanup: content-suspect parts are removed'

# --- Workstream C：下载诊断（代理身份不落地）-------------------------------
$diagText = Format-DownloadDiagnostics -Attempt 3 -Retries 12 -Offset 12582912 -Total 104857600 `
  -AverageBytesPerSec 1572864 -ProxyMode 'http://user:pass@127.0.0.1:7890' -CredentialPresent 'yes' `
  -StatusCode 200 -Connections 4
Assert-True ($diagText -match 'MiB/s') 'diag: includes the average speed in MiB/s'
Assert-True ($diagText -match 'HTTP 200') 'diag: includes the last HTTP status'
Assert-True ($diagText -match '127\.0\.0\.1:7890') 'diag: proxy is reduced to host:port'
Assert-True ($diagText -notmatch 'user:pass') 'diag: proxy userinfo is never printed'
Assert-True ($diagText -notmatch 'user\b' -and $diagText -notmatch 'pass\b') 'diag: neither credential component leaks'
Assert-True ($diagText -match '凭据 yes') 'diag: credential presence is yes/no only'
Assert-True ($diagText -match '连接 4') 'diag: includes the configured connection count'
$diagNoProxy = Format-DownloadDiagnostics -Attempt 1 -Retries 12 -Offset 0 -Total 0 -AverageBytesPerSec 0 -ProxyMode '' -StatusCode '' -Connections 1
Assert-True ($diagNoProxy -match '代理 none' -and $diagNoProxy -match 'HTTP n/a') 'diag: missing proxy/status render explicitly'

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
$segmented = Get-RequiredDiskBytes -CompressedBytes $c -UncompressedBytes $u -Tier Segmented
Assert-True ($stream -lt $merge) 'disk: Stream < Merge'
Assert-True ($merge -lt $legacy) 'disk: Merge < Legacy'
Assert-Equal $legacy ($stream + $c + $u) 'disk: Legacy - Stream = C + U'
Assert-Equal ([long]((2 * $c) + 2147483648 + 3221225472)) $segmented 'disk: Segmented = 2C + reserve + margin'
Assert-True (Test-DiskSpace -RequiredBytes 100 -AvailableBytes 100) 'disk: equal available passes'
Assert-True (-not (Test-DiskSpace -RequiredBytes 100 -AvailableBytes 99)) 'disk: short available fails'

# --- Workstream D：纯分段计划（S5-S9 的基础） ------------------------------
$plan10 = @(Get-SegmentPlan -TotalBytes 10 -Connections 4)
Assert-Equal 4 $plan10.Count 'segplan: 10/4 -> four ranges'
Assert-Equal ([long]3) $plan10[0].Length 'segplan: 10/4 first length'
Assert-Equal ([long]1) $plan10[3].Length 'segplan: 10/4 last short range'
Assert-Equal ([long]9) $plan10[3].Start 'segplan: 10/4 last start'
Assert-Equal ([long]9) $plan10[3].End 'segplan: 10/4 last end'
$plan12 = @(Get-SegmentPlan -TotalBytes 12 -Connections 4)
Assert-Equal 4 $plan12.Count 'segplan: 12/4 -> four equal ranges'
Assert-Equal ([long]3) $plan12[1].Length 'segplan: 12/4 all lengths are 3'
Assert-Equal ([long]3) $plan12[1].Start 'segplan: 12/4 second start'
$plan1 = @(Get-SegmentPlan -TotalBytes 1 -Connections 4)
Assert-Equal 1 $plan1.Count 'segplan: total smaller than connections yields one range'
Assert-Equal ([long]1) $plan1[0].SegmentSize 'segplan: one byte -> one-byte segments'
$plan5 = @(Get-SegmentPlan -TotalBytes 5 -Connections 4)
Assert-Equal 3 $plan5.Count 'segplan: 5/4 -> 2+2+1 ranges'
Assert-Equal ([long]4) $plan5[2].Start 'segplan: 5/4 last start'
Assert-Equal ([long]4) $plan5[2].End 'segplan: 5/4 last end'
Assert-Equal 0 @(Get-SegmentPlan -TotalBytes 0 -Connections 4).Count 'segplan: zero total -> no ranges'

# --- 分段顺序：不依赖排序的文化相关比较（回归门）---------------------------
# 合并分片必须按 Index 升序；直接 Sort-Object 的数字/文化比较在极端情况下
# 会把顺序弄反，所以顺序由纯函数决定。数组和 List[object] 都必须成立。
# 输入刻意打乱为 1,3,0,2：PS 5.1 上 Sort-Object -Property Index 对 Hashtable
# 的不稳定排序是固定置换（0,1,2,3 -> 2,3,0,1），若输入也用 2,3,0,1 会被置换
# 还原成 0,1,2,3 而假绿；恒等实现或 Hashtable 的 -Property 置换在这里必须失败。
$segOrderInput = @(
  @{ Index = 1; File = 'seg-1' }
  @{ Index = 3; File = 'seg-3' }
  @{ Index = 0; File = 'seg-0' }
  @{ Index = 2; File = 'seg-2' }
)
if (Get-Command Get-SegmentFileOrder -ErrorAction SilentlyContinue) {
  Assert-Equal 'seg-0,seg-1,seg-2,seg-3' (@(Get-SegmentFileOrder -Segments $segOrderInput) -join ',') 'seg-order: array input is ordered by Index'
  $segOrderList = [System.Collections.Generic.List[object]]::new()
  foreach ($segOrderItem in $segOrderInput) { $segOrderList.Add($segOrderItem) }
  Assert-Equal 'seg-0,seg-1,seg-2,seg-3' (@(Get-SegmentFileOrder -Segments $segOrderList) -join ',') 'seg-order: List[object] input is ordered by Index'
} else {
  Assert-True $false 'seg-order: Get-SegmentFileOrder is not defined (array + List[object] order unverified)'
}

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
Assert-True ($ciText -match 'rootfs-\*-\*\.tar\.zst\.part-\*') 'converge: build.yml keeps the rootfs parts'
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
Assert-True ($pdIdx -ge 0 -and $dlCallIdx -ge 0 -and $pdIdx -lt $dlCallIdx) 'dl: the part is registered before the download so cleanup can find it'

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
Assert-True ($ciText -match 'sha256sum rootfs-\*-\*\.tar\.zst\.part-\*') 'ci: publishes one merged SHA256SUMS'
Assert-True ($ciText -match '(?m)^\s*SHA256SUMS\s*$') 'ci: uploads SHA256SUMS as a Release asset'

# --- Workstream C structural pins (retention / slow abort / diagnostics / local parts) ---
$trapBody = [regex]::Match($mainText, '(?m)^trap \{[\s\S]*?\r?\n\}').Value
Assert-True ($trapBody -ne '') 'retain: the installer still has a script-scope trap'
Assert-True ($trapBody -notmatch 'Remove-DownloadArtifacts') 'retain: the trap never deletes downloaded parts'
Assert-True ($trapBody -match '分片' -and $trapBody -match '续传') 'retain: the trap prints the part directory + resume hint'
Assert-True ($mainText -match '\$script:ContentSuspect\s*=\s*\$false') 'retain: ContentSuspect is initialized'
Assert-True ($ensureText -match '\$script:ContentSuspect\s*=\s*\$true') 'retain: a terminal hash failure marks the content suspect'
Assert-True ($mainText -match 'Get-ImportCleanupPlan') 'retain: the import finally uses the cleanup plan'
Assert-True ($ensureText -match '\$SlowSpeedBytesPerSec') 'slow: Save-Download accepts a speed threshold'
Assert-True ($ensureText -match '\$SlowWindowSeconds') 'slow: Save-Download accepts a window length'
Assert-True ($ensureText -match '\$SegmentMinBytes') 'slow: Save-Download accepts the segment threshold (plumbed for D)'
Assert-True ($ensureText -match '传输过慢') 'slow: a low-speed attempt aborts with 传输过慢'
Assert-True ($ensureText -match 'Format-DownloadDiagnostics') 'diag: diagnostics helper exists and is used'
Assert-True ($ensureText -match '仍在等待数据') 'diag: a heartbeat is printed while waiting for data'
Assert-True ($ensureText -match '\.Wait\(1000\)') 'diag: ReadAsync is polled in 1 s slices'
Assert-True ($mainText -match '\$InstallDir -Filter') 'local: seeded parts are looked up in the install dir'
Assert-True ($mainText -notmatch '\$PSScriptRoot -Filter') 'local: the $PSScriptRoot part-glob bug is gone'
Assert-True ($mainText -match 'Get-FileSha256') 'local: seeded parts are verified by SHA256'
Assert-True ($mainText -match 'Get-MissingSha256Parts') 'local: a partial manifest is detected'
Assert-True ($mainText -notmatch '分片已保留在安装目录，重跑安装器不会重新下载') 'wording: the stale unconditional claim is gone'
Assert-True ($mainText -match '分片已保留') 'wording: the conditional retention notice is printed'
Assert-True ($mainText -match '分片会保留') 'wording: the post-unregister warning is conditional, not a promise'

# --- Workstream D 结构钉（S5-S9） ------------------------------------------
Assert-True ($ensureText -match 'function Get-SegmentPlan') 'seg: Get-SegmentPlan exists'
Assert-True ($ensureText -match 'function Get-DownloadSegmentDir') 'seg: segment dir helper exists'
Assert-True ($ensureText -match 'function Get-DownloadSegmentPath') 'seg: segment path helper exists'
Assert-True ($ensureText -match 'function Test-SegmentStateCompatible') 'seg: layout compatibility helper exists'
Assert-True ($ensureText -match 'function Join-Segments') 'seg: streaming join helper exists'
Assert-True ($ensureText -match 'function Save-DownloadSegmented') 'seg: segmented downloader exists'
Assert-True ($ensureText -match 'ValidateRange\(1,\s*8\)') 'seg: -Connections is constrained to 1..8'
Assert-True ($ensureText -match 'DefaultConnectionLimit') 'seg: raises the .NET connection limit before clients'
Assert-True ($ensureText -match '\$SegmentMinBytes\s*=\s*16777216') 'seg: has the 16 MiB segment threshold'
Assert-True ($ensureText -match '\$Connections\s*=\s*4') 'seg: defaults to four connections'
Assert-True ($ensureText -match '-eq 206') 'seg: only 206 is accepted as a partial body'
Assert-True ($ensureText -match 'SEGMENT_UNSUPPORTED') 'seg: HTTP 200 is a fallback marker'
Assert-True ($ensureText -match '服务器不支持分段下载') 'seg: the 200 fallback is explained to the user'
Assert-True ($ensureText -match 'Connections 1') 'seg: the 200 fallback restarts the single-stream path'
Assert-True ($ensureText -match '\b429\b' -and $ensureText -match '\b403\b' -and $ensureText -match '\b407\b') 'seg: rate-limit statuses are handled'
Assert-True ($ensureText -match 'SEGMENT_IDENTITY_CHANGED') 'seg: HTTP 412 has a restart path'
Assert-True ($ensureText -match 'SEGMENT_CONTENT_BAD') 'seg: final length/SHA failures are retryable but bounded'
Assert-True ($ensureText -match 'segmentState') 'seg: sidecar v2 carries segmentState'
Assert-True ($ensureText -match 'connections\s*=\s*\$connections') 'seg: sidecar v2 carries connections'
Assert-True ($ensureText -match 'segmentSize\s*=\s*\[long\]\$o\.segmentSize') 'seg: sidecar v2 carries segmentSize'
Assert-True ($ensureText -match 'segmentCount\s*=\s*\[int\]\$o\.segmentCount') 'seg: sidecar v2 carries segmentCount'
Assert-True ($ensureText -match 'AgentDevboxConnectionLimitSet') 'seg: the connection limit is set once per process'
Assert-True ($mainText -match "-Tier 'Segmented'") 'disk: installer computes the segmented peak'
Assert-True ($mainText -match '\[Math\]::Max\(\[long\]\$needStream, \[long\]\$needSegmented\)') 'disk: installer asserts max(Segmented, Stream)'
Assert-True ($mainText -match 'Save-Download[^\r\n]*-Connections \$Connections') 'seg: installer forwards -Connections to Save-Download'

# --- Workstream D 回归：分段顺序、统计回传（红门）---------------------------
# 旧的合并路径直接 Sort-Object -Property Index，且分段执行器的进度/状态只留在
# 局部变量里，Save-Download 无法在每轮重试后判断该走哪条路径。修复 = 纯函数定序
# + 调用方传入的 [hashtable] $Stats，由分段执行器写回统计。
Assert-True ($ensureText -match 'function Get-SegmentFileOrder') 'seg-order: Get-SegmentFileOrder exists'
Assert-True ($ensureText -notmatch 'Sort-Object\s+-Property\s+Index') 'seg-order: no culture-sensitive Sort-Object -Property Index'
Assert-True ($ensureText.Contains('Get-SegmentFileOrder -Segments $segments')) 'seg-order: the join list is ordered via Get-SegmentFileOrder -Segments $segments'
$segFnText = [regex]::Match($ensureText, '(?s)function Save-DownloadSegmented\b[\s\S]*?\r?\n\}').Value
Assert-True ($segFnText -match '\[hashtable\]\s+\$Stats\b') 'seg-stats: Save-DownloadSegmented takes a [hashtable] $Stats'
Assert-True ($ensureText -match 'Save-DownloadSegmented[\s\S]{0,500}?-Stats\s+\$stats\b') 'seg-stats: the caller passes -Stats $stats to Save-DownloadSegmented'
$saveDlText = [regex]::Match($ensureText, '(?s)function Save-Download\b[\s\S]*?\r?\n\}').Value
Assert-True ($saveDlText -match '\$Stats\.Segmented\b') 'seg-stats: Save-Download reads $Stats.Segmented'
Assert-True ($saveDlText -match '\$Stats\.(Offset|Bytes|LastStatus|Connections)\b') 'seg-stats: Save-Download reads $Stats.Offset/Bytes/LastStatus/Connections'
foreach ($statProp in @('Segmented', 'Offset', 'Bytes', 'LastStatus', 'Connections')) {
  Assert-True ($segFnText -match ('\$Stats\.{0}\s*=' -f $statProp)) "seg-stats: Save-DownloadSegmented assigns `$Stats.$statProp"
}
Assert-True ($segFnText -notmatch '\$Stats\s*=') 'seg-stats: Save-DownloadSegmented never reassigns $Stats (only its properties)'
$segOrderFnIdx   = $ensureText.IndexOf('function Get-SegmentFileOrder')
$segOrderCallIdx = $ensureText.IndexOf('Get-SegmentFileOrder -Segments $segments')
Assert-True ($segOrderFnIdx -ge 0 -and $segOrderCallIdx -ge 0 -and $segOrderFnIdx -lt $segOrderCallIdx) 'seg-order: the ordering helper is defined before it is called'

# --- 升级是幂等的：不重设密码、不需要按 y ----------------------------------
# 密码唯一来源是数据盘（跨升级保留）。旧系统盘的 conf 读取已删除：它会为了 cat 一个文件
# 把旧发行版整机拉起（[boot] 顺带 mount 数据盘 + 起 paseo），升级时多一次无谓的启停。
Assert-True ($mainText -notmatch 'existingPw') 'upgrade: the installer no longer reads the old system-disk conf'
Assert-True ($mainText -match "'--unregister'") 'upgrade: the old distro is unregistered for the upgrade'
Assert-True ($mainText -notmatch 'Read-Host[^\r\n]*\[Y/n\]') 'upgrade: no interactive [Y/n] reinstall prompt'
Assert-True ($mainText -match 'KeepExisting') 'upgrade: overwrite is the default (-KeepExisting opts out)'
# 交互式升级确认：单一实现（Confirm-Upgrade）在共享 helper 里，入口只调用它。
# 决策必须发生在注销/下载之前，否则「取消」会先破坏已有的安装。
Assert-True ($ensureText -match 'function Test-InteractiveConsole') 'upgrade: interactive-console detection lives in the shared helper'
Assert-True ($ensureText -match 'function Resolve-UpgradeAnswer') 'upgrade: answer parsing is a pure helper'
Assert-True ($ensureText -match 'function Confirm-Upgrade') 'upgrade: a single shared confirmation helper'
# 提示文案必须是纯函数（同一份文本被两处复用），且升级确认要拿到安装目录 +
# 数据盘是否存在，才能区分「保留数据盘」和「新建空数据盘、不会迁移」。
$confirmFnText = [regex]::Match($ensureText, '(?s)function Confirm-Upgrade\b[\s\S]*?\r?\n\}').Value
Assert-True ($confirmFnText -match '\[string\]\s+\$InstallDir') 'upgrade-prompt: Confirm-Upgrade accepts [string] $InstallDir'
Assert-True ($confirmFnText -match 'Format-UpgradePrompt') 'upgrade-prompt: Confirm-Upgrade calls Format-UpgradePrompt'
Assert-True ($confirmFnText -match '-DataDiskPresent') 'upgrade-prompt: Confirm-Upgrade passes -DataDiskPresent'
Assert-True ($ensureText -match '已取消升级') 'upgrade: cancel writes an explicit message'
Assert-True ($ensureText -match 'Test-WslDistroExists') 'upgrade: distro existence is probed by the shared helper'
Assert-True ($mainText -match 'Test-WslDistroExists') 'upgrade: the installer uses the shared existence probe'
Assert-True ($mainText -match 'if \(\$decision -eq ''cancel''\) \{ return \}') 'upgrade: the installer returns on cancel'
Assert-True ($mainText -match '\$import = \$decision -ne ''keep''') 'upgrade: keep/upgrade decides the import'
Assert-True ($mainText -match '\$reinstall = \$distroExists -and \$import') 'upgrade: -KeepExisting still skips the reinstall'
Assert-True ($mainText -match 'UpgradeConfirmed') 'upgrade: the installer accepts the entry''s prior confirmation'
$confirmIdx = $mainText.IndexOf('Confirm-Upgrade')
$unregIdx   = $mainText.IndexOf("'--unregister'")
$dlIdx      = $mainText.IndexOf('Save-Download -Url')
Assert-True ($confirmIdx -ge 0 -and $unregIdx -ge 0 -and $dlIdx -ge 0) 'upgrade: unregister and download calls are present'
Assert-True ($confirmIdx -ge 0 -and $confirmIdx -lt $unregIdx) 'upgrade: the decision is taken BEFORE unregister'
Assert-True ($confirmIdx -ge 0 -and $confirmIdx -lt $dlIdx) 'upgrade: the decision is taken BEFORE download'
$wtIdx      = $mainText.IndexOf('Write-AgentDevboxTerminalProfile')
$instDirIdx = $mainText.IndexOf('New-Item -ItemType Directory -Force -Path $InstallDir')
$ensureIdx  = $mainText.IndexOf('$__r = Ensure-Wsl')
$mirrorIdx  = $mainText.IndexOf('Set-MirroredNetworking -Yes:$Yes')
Assert-True ($wtIdx -ge 0 -and $instDirIdx -ge 0 -and $ensureIdx -ge 0 -and $mirrorIdx -ge 0) 'upgrade: the installer still writes the WT profile and runs the preflight'
Assert-True ($confirmIdx -lt $wtIdx -and $confirmIdx -lt $instDirIdx) 'upgrade: cancel precedes the WT profile and the InstallDir creation'
Assert-True ($confirmIdx -lt $ensureIdx -and $confirmIdx -lt $mirrorIdx) 'upgrade: cancel precedes every WSL-config change'
Assert-True ($mainText -notmatch '(?m)^\s*\$distroExists = Test-DistroExists\s*$') 'upgrade: the old silent decision block is gone'
Assert-True ($mainText -match '\.paseo-password') 'upgrade: the password is stored on the data disk'
Assert-True ($mainText -match 'blkid -U') 'upgrade: the data disk is mounted by UUID to read/write the password'
Assert-True ($mainText -match 'mountpoint -q') 'upgrade: mounting is idempotent (mountpoint -q)'
Assert-True ($mainText -match 'findmnt -rno UUID --mountpoint') 'upgrade: the password step verifies the mounted data-disk UUID'
Assert-True ($mainText -match 'DATA_DISK_WRITE_MISMATCH') 'upgrade: the password is read back from the data disk after writing'
Assert-True ($mainText -notmatch '\$dataDiskMounted -and \$pw') 'upgrade: the password write no longer trusts a stale mount flag'

# --- 升级提示文案（纯函数，红门）-------------------------------------------
# 空 -InstallDir 必须与旧文案逐字一致（老入口/无人值守路径不能变）；
# 非空且数据盘存在 -> 明确「数据盘/密码保留」；非空且数据盘缺失 -> 明确
# 「新建空数据盘」「不会迁移」「data.vhdx」，不能让用户误以为旧数据会跟过来。
if (Get-Command Format-UpgradePrompt -ErrorAction SilentlyContinue) {
  Assert-Equal '发行版 ''agent-devbox'' 已存在。回车 = 覆盖升级（数据盘/密码保留），n = 取消' `
    (Format-UpgradePrompt -Distro 'agent-devbox' -InstallDir '' -DataDiskPresent $false) `
    'upgrade-prompt: empty -InstallDir keeps the legacy text verbatim'
  $promptPresent = Format-UpgradePrompt -Distro 'agent-devbox' -InstallDir 'D:\WSL\agent-devbox' -DataDiskPresent $true
  Assert-True ($promptPresent -match '数据盘/密码保留') 'upgrade-prompt: existing data disk -> 数据盘/密码保留'
  Assert-True ($promptPresent -notmatch '不会迁移') 'upgrade-prompt: existing data disk -> no 不会迁移 warning'
  $promptMissing = Format-UpgradePrompt -Distro 'agent-devbox' -InstallDir 'D:\WSL\agent-devbox' -DataDiskPresent $false
  Assert-True ($promptMissing -match '新建空数据盘') 'upgrade-prompt: missing data disk -> 新建空数据盘'
  Assert-True ($promptMissing -match '不会迁移') 'upgrade-prompt: missing data disk -> 不会迁移'
  Assert-True ($promptMissing -match 'data\.vhdx') 'upgrade-prompt: missing data disk -> names data.vhdx'
} else {
  Assert-True $false 'upgrade-prompt: Format-UpgradePrompt is not defined (legacy/present/missing text unverified)'
}

# --- 安装器不变量（原先重复写在 build.yml 的 tripwire 里，已合并到这里）-----
Assert-True ($mainText -notmatch 'Read-Host[^\r\n]*重装') 'inv: no interactive reinstall prompt'
# 入口只调用共享的 Confirm-Upgrade；升级提问不能写在 install.ps1 里，
# 且必须在 Ensure-Wsl / Set-MirroredNetworking 之前（取消不得改 .wslconfig）。
Assert-True ($webText -match 'Confirm-Upgrade') 'inv: install.ps1 calls the shared confirmation'
Assert-True ($webText -notmatch 'Read-Host[^\r\n]*覆盖升级') 'inv: install.ps1 never prompts for the upgrade itself'
Assert-True ($webText -notmatch 'Read-Host[^\r\n]*取消') 'inv: install.ps1 never asks to cancel directly'
$webConfirmIdx = $webText.IndexOf('$decision = Confirm-Upgrade')
$webEnsureIdx  = $webText.IndexOf('$r = Ensure-Wsl')
$webMirrorIdx  = $webText.IndexOf('Set-MirroredNetworking -Yes')
Assert-True ($webConfirmIdx -ge 0 -and $webEnsureIdx -ge 0 -and $webMirrorIdx -ge 0) 'inv: the entry still runs the preflight'
Assert-True ($webConfirmIdx -ge 0 -and $webConfirmIdx -lt $webEnsureIdx -and $webEnsureIdx -lt $webMirrorIdx) 'inv: the entry confirms BEFORE Ensure-Wsl / Set-MirroredNetworking'

# --- 安装目录：提问顺序 / 传参（红门）--------------------------------------
# 旧实现先 UAC 提权、在提权窗口里才问安装目录（core 变体甚至在升级确认之后），
# 于是「取消升级」之前就已经创建了目录；入口也无法把目录传给子进程。现在两个
# 脚本都在提权/确认之前问一次，并把 -InstallDir 一路传下去；install.ps1 还要在
# UAC argv 与安装器参数里都带上它。
$webInstallDirIdx = $webText.IndexOf('安装目录 [')
$webStartProcIdx  = $webText.IndexOf("Start-Process -FilePath 'powershell.exe'")
Assert-True ($webInstallDirIdx -ge 0) 'order: install.ps1 asks for 安装目录'
Assert-True ($webInstallDirIdx -ge 0 -and $webStartProcIdx -ge 0 -and $webInstallDirIdx -lt $webStartProcIdx) 'order: install.ps1 asks for 安装目录 BEFORE the UAC hand-off'
Assert-True ($webInstallDirIdx -ge 0 -and $webConfirmIdx -ge 0 -and $webInstallDirIdx -lt $webConfirmIdx) 'order: install.ps1 asks for 安装目录 BEFORE the upgrade confirmation'

$mainInstallDirIdx = $mainText.IndexOf('安装目录 [')
$mainStartProcIdx  = $mainText.IndexOf("Start-Process -FilePath 'powershell.exe' -Verb RunAs")
Assert-True ($mainInstallDirIdx -ge 0) 'order: install-agent-devbox.ps1 asks for 安装目录'
Assert-True ($mainInstallDirIdx -ge 0 -and $mainStartProcIdx -ge 0 -and $mainInstallDirIdx -lt $mainStartProcIdx) 'order: install-agent-devbox.ps1 asks for 安装目录 BEFORE the UAC hand-off'
Assert-True ($mainInstallDirIdx -ge 0 -and $confirmIdx -ge 0 -and $mainInstallDirIdx -lt $confirmIdx) 'order: install-agent-devbox.ps1 asks for 安装目录 BEFORE the upgrade confirmation'

Assert-Equal 1 ([regex]::Matches($webText, 'Read-Host\s+"安装目录').Count) 'order: install.ps1 asks for 安装目录 exactly once'
Assert-Equal 1 ([regex]::Matches($mainText, 'Read-Host\s+"安装目录').Count) 'order: install-agent-devbox.ps1 asks for 安装目录 exactly once'

Assert-True ($webText -match 'InstallDir\s*=\s*\$InstallDir') 'dir: install.ps1 puts InstallDir into the installer args'
Assert-True ($webText -match '\$argList[\s\S]{0,600}?-InstallDir') 'dir: install.ps1 forwards -InstallDir in the UAC argv'
$webInstallDirMentions = ([regex]::Matches($webText, '-InstallDir')).Count
Assert-True ($webInstallDirMentions -ge 2) "dir: install.ps1 mentions -InstallDir at least twice (got $webInstallDirMentions)"

Assert-True ($webText -match 'Confirm-Upgrade[\s\S]{0,200}?-InstallDir\s+\$InstallDir') 'dir: install.ps1 passes -InstallDir to Confirm-Upgrade'
Assert-True ($mainText -match 'Confirm-Upgrade[\s\S]{0,200}?-InstallDir\s+\$InstallDir') 'dir: install-agent-devbox.ps1 passes -InstallDir to Confirm-Upgrade'
Assert-True ($mainText -match "'-InstallDir'") 'dir: install-agent-devbox.ps1 forwards -InstallDir in its UAC argv'

$mainInstallDirCreateIdx = $mainText.IndexOf('New-Item -ItemType Directory -Force -Path $InstallDir')
Assert-True ($mainInstallDirCreateIdx -ge 0 -and $confirmIdx -ge 0 -and $mainInstallDirCreateIdx -gt $confirmIdx) 'order: InstallDir is created only AFTER the upgrade decision'

# --- 数据盘：只有真正导入且没有现存 VHDX 时才创建（红门）-------------------
# 升级 = 换系统盘但保留数据盘；导入失败/保留现有时若还无条件建盘，会留下空盘
# 或者覆盖已有盘。提示也必须先说明「不会迁移」，再创建。
$distroVhdxIdx = $mainText.IndexOf('$distroExists -and -not (Test-Path -LiteralPath $VhdxPath)')
$step6Idx      = $mainText.IndexOf("Step '[6/10]")
$createDiskIdx = $mainText.IndexOf('正在创建数据磁盘')
$diskBlock = if ($step6Idx -ge 0 -and $createDiskIdx -gt $step6Idx) { $mainText.Substring($step6Idx, $createDiskIdx - $step6Idx) } else { '' }
Assert-True ($distroVhdxIdx -ge 0) 'disk: creation is gated on an existing distro with no existing VHDX'
Assert-True ($diskBlock -match '不会迁移') 'disk: 不会迁移 is announced in [6/10] BEFORE creating the disk'

# --- 镜像网络：调用结果不得泄漏到输出（红门）-------------------------------
# Set-MirroredNetworking 返回 bool/字符串；裸调用会把 True 混进安装输出，
# 也会让 redirect 的日志出现伪错误行。每次调用必须在同一行接 | Out-Null。
$mirrorCalls = @()
$mirrorBad   = @()
foreach ($mirrorFile in @('install.ps1', 'install-agent-devbox.ps1')) {
  $mirrorText = if ($mirrorFile -eq 'install.ps1') { $webText } else { $mainText }
  $fileCalls = @($mirrorText -split "`r?`n" | Where-Object { $_ -match '^\s*Set-MirroredNetworking\b' })
  $mirrorCalls += $fileCalls
  $mirrorBad += @($fileCalls | Where-Object { $_ -notmatch '\|\s*Out-Null' } | ForEach-Object { "${mirrorFile}: $_" })
}
Assert-True ($mirrorCalls.Count -ge 2) "net: both installers call Set-MirroredNetworking (got $($mirrorCalls.Count))"
Assert-Equal 0 $mirrorBad.Count "net: every Set-MirroredNetworking call pipes to Out-Null (found: $($mirrorBad -join ' | '))"

# --- 取消中继：取消写成 .cancel，父窗口不得把它当成成功 ----------------------
Assert-True ($ensureText -match 'function Write-CancelRelay') 'cancel: the relay writer lives in the shared helper'
Assert-True ($ensureText -match '\[System\.IO\.File\]::WriteAllText\("\$LogPath\.rc", ''0''\)') 'cancel: rc is written as 0'
Assert-True ($ensureText -match '\[System\.IO\.File\]::WriteAllText\("\$LogPath\.cancel", ''1''\)') 'cancel: the cancel marker is written'
Assert-True ($mainText -match '\$parentLog\.cancel') 'cancel: the installer parent checks the marker'
Assert-True ($webText -match '\$log\.cancel') 'cancel: the entry checks the marker in the original window'
Assert-True ($webText -match '\$LogPath\.cancel') 'cancel: the elevated wrapper returns after a cancel'
$mainCancelIdx = $mainText.IndexOf('$parentLog.cancel')
$mainDoneIdx   = $mainText.IndexOf('安装完成')
Assert-True ($mainCancelIdx -ge 0 -and $mainDoneIdx -ge 0 -and $mainCancelIdx -lt $mainDoneIdx) 'cancel: the installer checks the marker BEFORE printing 安装完成'
Assert-True ($mainText -match 'Remove-Item -LiteralPath "\$parentLog\.cancel"') 'cancel: the installer parent removes the marker'
Assert-True ($webText -match 'Remove-Item -LiteralPath "\$log\.cancel"') 'cancel: the entry original window removes the marker'
Assert-True ($webText -notmatch '安装完成') 'cancel: install.ps1 never claims 安装完成'
Assert-True ($webText -match '已取消升级') 'cancel: install.ps1 prints the cancel result'
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
  if ($pwWriteIdx -lt 0 -and $dlLines[$i] -match 'printf %s \{2\} > \{3\}') { $pwWriteIdx = $i }
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
  Assert-Equal 1 $s.version 'id: a v1 sidecar still reads with version 1'
  Assert-Equal 0 $s.connections 'id: a v1 sidecar defaults connections to 0'
  Assert-Equal '' $s.segmentState 'id: a v1 sidecar defaults segmentState to empty'
  $segDir = Get-DownloadSegmentDir -Dest $part
  $segPath = Get-DownloadSegmentPath -Dest $part -Index 0
  Assert-True ($segDir.EndsWith((Join-Path '.agent-devbox-download' (Join-Path 'segments' 'rootfs-core-amd64.tar.zst.part-00')))) 'id: segment dir is below .agent-devbox-download/segments/<leaf>'
  Assert-True ($segPath.StartsWith($segDir, [System.StringComparison]::Ordinal)) 'id: segment path is contained in its segment dir'
  Assert-Equal 'seg-000' (Split-Path -Leaf $segPath) 'id: segment files are named seg-NNN'
  New-Item -ItemType Directory -Path $segDir -Force | Out-Null
  [System.IO.File]::WriteAllText($segPath, 'x')
  $globbed = @(Get-ChildItem -Path $qa -Filter 'rootfs-core-amd64.tar.zst.part-*')
  Assert-Equal 1 $globbed.Count 'id: nested segment files are invisible to the rootfs part glob'
  Write-DownloadSidecar -Path $meta -Url 'http://h/a' -ETag '"v2"' -Length 12 -Sha256 $shaA -Complete $false `
    -Connections 4 -SegmentSize 3 -SegmentCount 4 -SegmentState 'active'
  $s2 = Read-DownloadSidecar -Path $meta
  Assert-Equal 2 $s2.version 'id: a segmented sidecar is version 2'
  Assert-Equal 4 $s2.connections 'id: sidecar v2 round-trips connections'
  Assert-Equal ([long]3) $s2.segmentSize 'id: sidecar v2 round-trips segmentSize'
  Assert-Equal 4 $s2.segmentCount 'id: sidecar v2 round-trips segmentCount'
  Assert-Equal 'active' $s2.segmentState 'id: sidecar v2 round-trips segmentState'
  Assert-True (Test-SegmentStateCompatible -Sidecar $s2 -Connections 4 -SegmentSize 3) 'segplan: matching layout is compatible'
  Assert-True (-not (Test-SegmentStateCompatible -Sidecar $s2 -Connections 2 -SegmentSize 3)) 'segplan: changed connections invalidates segments'
  Assert-True (-not (Test-SegmentStateCompatible -Sidecar $s2 -Connections 4 -SegmentSize 4)) 'segplan: changed segment size invalidates segments'
  Assert-True (-not (Test-SegmentStateCompatible -Sidecar $null -Connections 4 -SegmentSize 3)) 'segplan: a missing sidecar is incompatible'
  Assert-True (-not (Test-SegmentStateCompatible -Sidecar $s -Connections 4 -SegmentSize 3)) 'segplan: a v1 sidecar is incompatible with segments'
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
Assert-True ($ensureText -match "'\{6f4a1c2e-8b3d-4a97-9c51-0e7d2b8f3a64\}'") 'wt: the agents profile GUID is fixed'
Assert-True ($ensureText -match "'\{c2d7e9a4-3f61-4b08-8e52-7a1d9c4b6f30\}'") 'wt: the core profile GUID is fixed'
$writeIdx = $mainText.IndexOf('Write-AgentDevboxTerminalProfile -Distro $Distro -ProfileGuid $v.TerminalGuid -HideGuid $v.HideGuid')
$importIdx = $mainText.IndexOf("Step '[4/10]")
Assert-True ($writeIdx -ge 0 -and $importIdx -gt $writeIdx) 'wt: the fragment is written BEFORE the import'
Assert-True ($mainText -match 'Write-AgentDevboxTerminalProfile -Distro \$Distro -ProfileGuid \$v\.TerminalGuid -HideGuid \$v\.HideGuid') 'wt: installer passes the per-channel GUIDs'
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

# --- Naming-model tripwires (distro / dir / data-disk identity) -----------
# The WSL/Windows paths cannot execute on Linux, so these structural pins are
# the tests of record for the final naming model:
#   agents = distro agent-devbox      dir D:\WSL\agent-devbox
#   core   = distro agent-devbox-core dir D:\WSL\agent-devbox-core
#   data   = ext4 label AND mount name: `devbox-data` (stable) / `devbox-data-beta` (beta)
$dataInitText = Get-Content -Raw (Join-Path $here '..' '..' 'scripts' 'datadisk-init.sh')

# Data-disk identity is channel-scoped (label == mount name within a channel).
Assert-True ($mainText -match 'devbox-data') 'name: installer uses devbox-data'
Assert-True ($mainText -match 'DATA_MNTNAME') 'name: installer writes DATA_MNTNAME'
Assert-True ($mainText -notmatch 'agent-devbox-data') 'name: installer drops the old agent-devbox-data'

# The manual repair helpers are pure batch now: no scheduled task exists, the
# guest boot script attaches the disk, and a failed boot prints the install-dir
# mount-datadisk.cmd. Both helpers call wsl.exe directly, log every attempt and
# exit with wsl's real code. A .ps1 wrapper (and its self-elevation) must not
# come back.
$mountHelper = Get-Content -Raw (Join-Path $winDir 'mount-datadisk.cmd')
Assert-True ($mountHelper -match '--mount') 'name: attach helper uses wsl --mount'
Assert-True ($mountHelper -match '--vhd') 'name: attach helper passes --vhd'
Assert-True ($mountHelper -match '--bare') 'name: attach helper uses --bare'
Assert-True ($mountHelper -match 'datadisk-attach\.log') 'name: attach helper logs every attempt'
Assert-True ($mountHelper -match '%ERRORLEVEL%') 'name: attach helper reads the real exit code'
Assert-True ($mountHelper -match 'exit /b') 'name: attach helper propagates the real exit code'
Assert-True ($mountHelper -notmatch '(?i)powershell') 'name: attach helper has no PowerShell'
Assert-True ($mountHelper -notmatch 'RunAs') 'name: attach helper never self-elevates'
$unmountHelper = Get-Content -Raw (Join-Path $winDir 'unmount-datadisk.cmd')
Assert-True ($unmountHelper -match '--unmount') 'name: detach helper uses wsl --unmount'
Assert-True ($unmountHelper -match [regex]::Escape('\\?\%VHDX%')) 'name: detach helper uses the \\?\ device path'
Assert-True ($unmountHelper -notmatch '(?i)powershell') 'name: detach helper has no PowerShell'
Assert-True ($unmountHelper -notmatch 'RunAs') 'name: detach helper never self-elevates'
foreach ($goneHelper in @('mount-datadisk.ps1', 'unmount-datadisk.ps1')) {
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $winDir $goneHelper))) "converge: $goneHelper stays deleted"
}
Assert-True ($mainText -match '@\(''--mount'', ''--vhd'', \$VhdxPath, ''--bare''\)') 'name: installer attaches the disk itself before restarting'
Assert-True ($mainText -match 'for \(\$i = 1; \$i -le 3; \$i\+\+\)') 'name: the installer retries the attach 3 times'
Assert-True ($mainText -match 'Join-Path \$InstallDir ''mount-datadisk\.cmd''') 'name: the failure message points at mount-datadisk.cmd'
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
Assert-True ($mainText -notmatch 'New-ScheduledTaskAction') 'task: no New-ScheduledTaskAction'
Assert-True ($mainText -notmatch '(?<!Un)Register-ScheduledTask') 'task: no Register-ScheduledTask call'
Assert-True ($mainText -notmatch 'Start-ScheduledTask') 'task: no Start-ScheduledTask call'
Assert-True ($mainText -notmatch 'New-ScheduledTaskTrigger') 'task: no task trigger is created'
Assert-True ($mainText -notmatch 'New-ScheduledTaskSettingsSet') 'task: no task settings are created'
Assert-True ($mainText -notmatch '\$NoTask') 'task: the -NoTask switch is gone'
Assert-True ($mainText -notmatch '\$TaskName') 'task: the per-variant $TaskName variable is gone'
Assert-True ($mainText -match 'Unregister-ScheduledTask -TaskName \$oldTask\.TaskName') 'task: legacy tasks are still removed'
Assert-True ($mainText -match 'agent-devbox\.\*-mount-datadisk') 'task: legacy tasks are discovered by name'

# Manual mount/unmount helpers are copied into the install dir and fetched by install.ps1.
Assert-True ($mainText -match 'mount-datadisk\.cmd') 'name: installer copies the mount helper'
Assert-True ($mainText -match 'unmount-datadisk\.cmd') 'name: installer copies the unmount helper'
foreach ($h in @('mount-datadisk.cmd', 'unmount-datadisk.cmd')) {
  Assert-True ($webText -match [regex]::Escape($h)) "converge: install.ps1 fetches $h"
}
Assert-True ($webText -match 'mount-datadisk\.cmd') 'converge: install.ps1 fetches the pure-batch mount helper'
Assert-True ($webText -notmatch 'mount-datadisk\.ps1') 'converge: install.ps1 no longer fetches mount-datadisk.ps1'
Assert-True ($webText -notmatch 'unmount-datadisk\.ps1') 'converge: install.ps1 no longer fetches unmount-datadisk.ps1'

# The core variant names are wired through the installer.
Assert-True ($mainText -match 'agent-devbox-core') 'name: installer knows agent-devbox-core'
Assert-True ($mainText -match [regex]::Escape('D:\WSL\agent-devbox-core')) 'name: installer knows the core dir'

# install.ps1 derives $Distro from $Variant.
Assert-True ($webText -match "'agent-devbox-core'") 'name: install.ps1 derives the core distro name'

# --- 通道身份（stable / beta）：独立安装，绝不碰正式安装 ------------------
# channel = beta iff ref != main。stable 必须与今天逐字一致；beta 换发行版、
# 安装目录、ext4 标签、挂载名和 WT GUID，所以既不会注销也不会挂载正式安装。
$identAgentsStable = Get-AgentDevboxChannelIdentity -Variant 'agents' -Channel 'stable'
$identAgentsBeta   = Get-AgentDevboxChannelIdentity -Variant 'agents' -Channel 'beta'
$identCoreStable   = Get-AgentDevboxChannelIdentity -Variant 'core' -Channel 'stable'
$identCoreBeta     = Get-AgentDevboxChannelIdentity -Variant 'core' -Channel 'beta'

# 4-row matrix (the stable rows are today's literals, byte for byte).
Assert-Equal 'agents' $identAgentsStable.Variant 'chan: agents/stable variant'
Assert-Equal 'stable' $identAgentsStable.Channel 'chan: agents/stable channel'
Assert-Equal 'agent-devbox' $identAgentsStable.Distro 'chan: agents/stable distro'
Assert-Equal 'D:\WSL\agent-devbox' $identAgentsStable.InstallDir 'chan: agents/stable install dir'
Assert-Equal 'devbox-data' $identAgentsStable.Label 'chan: agents/stable label'
Assert-Equal 'devbox-data' $identAgentsStable.MountName 'chan: agents/stable mount name'
Assert-Equal '{6f4a1c2e-8b3d-4a97-9c51-0e7d2b8f3a64}' $identAgentsStable.TerminalGuid 'chan: agents/stable terminal GUID'
Assert-Equal '{04014822-8112-5520-a687-27d5f19a9da6}' $identAgentsStable.HideGuid 'chan: agents/stable hide GUID'

Assert-Equal 'agents' $identAgentsBeta.Variant 'chan: agents/beta variant'
Assert-Equal 'beta' $identAgentsBeta.Channel 'chan: agents/beta channel'
Assert-Equal 'agent-devbox-beta' $identAgentsBeta.Distro 'chan: agents/beta distro'
Assert-Equal 'D:\WSL\agent-devbox-beta' $identAgentsBeta.InstallDir 'chan: agents/beta install dir'
Assert-Equal 'devbox-data-beta' $identAgentsBeta.Label 'chan: agents/beta label'
Assert-Equal 'devbox-data-beta' $identAgentsBeta.MountName 'chan: agents/beta mount name'
Assert-Equal '{2af7958c-5167-48b1-a6bd-acaabdca12d2}' $identAgentsBeta.TerminalGuid 'chan: agents/beta terminal GUID'
Assert-Equal '{0c3f8933-9ad0-429b-a9b8-43861e7fa812}' $identAgentsBeta.HideGuid 'chan: agents/beta hide GUID'

Assert-Equal 'core' $identCoreStable.Variant 'chan: core/stable variant'
Assert-Equal 'stable' $identCoreStable.Channel 'chan: core/stable channel'
Assert-Equal 'agent-devbox-core' $identCoreStable.Distro 'chan: core/stable distro'
Assert-Equal 'D:\WSL\agent-devbox-core' $identCoreStable.InstallDir 'chan: core/stable install dir'
Assert-Equal 'devbox-data' $identCoreStable.Label 'chan: core/stable label'
Assert-Equal 'devbox-data' $identCoreStable.MountName 'chan: core/stable mount name'
Assert-Equal '{c2d7e9a4-3f61-4b08-8e52-7a1d9c4b6f30}' $identCoreStable.TerminalGuid 'chan: core/stable terminal GUID'
Assert-Equal '{82ea5eb7-e460-5790-9192-d6a59b44f009}' $identCoreStable.HideGuid 'chan: core/stable hide GUID'

Assert-Equal 'core' $identCoreBeta.Variant 'chan: core/beta variant'
Assert-Equal 'beta' $identCoreBeta.Channel 'chan: core/beta channel'
Assert-Equal 'agent-devbox-core-beta' $identCoreBeta.Distro 'chan: core/beta distro'
Assert-Equal 'D:\WSL\agent-devbox-core-beta' $identCoreBeta.InstallDir 'chan: core/beta install dir'
Assert-Equal 'devbox-data-beta' $identCoreBeta.Label 'chan: core/beta label'
Assert-Equal 'devbox-data-beta' $identCoreBeta.MountName 'chan: core/beta mount name'
Assert-Equal '{9c0a398c-65c5-4a2f-85e5-220af66bac1b}' $identCoreBeta.TerminalGuid 'chan: core/beta terminal GUID'
Assert-Equal '{e6647892-a55a-456d-841d-4c4faed607b9}' $identCoreBeta.HideGuid 'chan: core/beta hide GUID'

# ext4 labels are limited to 16 bytes: `devbox-data-beta` is exactly 16.
Assert-Equal 16 $identAgentsBeta.Label.Length 'chan: beta label is exactly 16 chars'
Assert-Equal 'devbox-data-beta' "$($identCoreBeta.Label)" 'chan: both variants share the beta label'

# Channel identities must not collide with each other or across variants.
$stablePairs = @(
  @($identAgentsStable, $identAgentsBeta),
  @($identCoreStable, $identCoreBeta)
)
foreach ($pair in $stablePairs) {
  $s = $pair[0]; $b = $pair[1]
  Assert-True ($s.Distro -ne $b.Distro) "chan: $($s.Variant) stable/beta distro differs"
  Assert-True ($s.InstallDir -ne $b.InstallDir) "chan: $($s.Variant) stable/beta install dir differs"
  Assert-True ($s.Label -ne $b.Label) "chan: $($s.Variant) stable/beta label differs"
  Assert-True ($s.MountName -ne $b.MountName) "chan: $($s.Variant) stable/beta mount name differs"
  Assert-True ($s.TerminalGuid -ne $b.TerminalGuid) "chan: $($s.Variant) stable/beta terminal GUID differs"
  Assert-True ($s.HideGuid -ne $b.HideGuid) "chan: $($s.Variant) stable/beta hide GUID differs"
}
$allGuids = @(
  $identAgentsStable.TerminalGuid, $identAgentsBeta.TerminalGuid, $identCoreStable.TerminalGuid, $identCoreBeta.TerminalGuid,
  $identAgentsStable.HideGuid, $identAgentsBeta.HideGuid, $identCoreStable.HideGuid, $identCoreBeta.HideGuid
)
Assert-Equal 8 (@($allGuids | Select-Object -Unique).Count) 'chan: all four rows use distinct Terminal/Hide GUIDs'

# Entry: channel before default dir, default dir before the install-dir prompt.
$channelIdx    = $webText.IndexOf("`$Channel = if (`$Ref -ne 'main')")
$defaultDirIdx = $webText.IndexOf('$DefaultInstallDir =')
$dirPromptIdx  = $webText.IndexOf('Read-Host "安装目录')
Assert-True ($channelIdx -ge 0) 'chan: the entry derives the channel'
Assert-True ($channelIdx -ge 0 -and $defaultDirIdx -gt $channelIdx) 'chan: the channel is derived before the default dir'
Assert-True ($defaultDirIdx -ge 0 -and $dirPromptIdx -gt $defaultDirIdx) 'chan: the default dir is known before the 安装目录 prompt'
Assert-True ($webText -match '\$Channel = if \(\$Ref -ne ''main''\) \{ ''beta'' \} else \{ ''stable'' \}') 'chan: non-main refs get the beta channel'
Assert-True ($webText -match '\$ChannelSuffix = if \(\$Channel -eq ''beta''\) \{ ''-beta'' \} else \{ '''' \}') 'chan: only beta gets a suffix'
Assert-True ($webText -match '\$BaseDistro = if \(\$Variant -eq ''core''\)') 'chan: the base distro is variant-scoped'
Assert-True ($webText -match '\$Distro = "\$BaseDistro\$ChannelSuffix"') 'chan: the distro is base + channel suffix'
Assert-True ($webText -match '\$DefaultInstallDir = "D:\\WSL\\\$Distro"') 'chan: the default dir derives from the channel distro'
Assert-True ($webText -notmatch '\$Distro\s*=\s*if \(\$Variant -eq ''core''\)') 'chan: the old variant-only distro assignment is gone'
Assert-True ($webText -notmatch '\$InstallDir[^\r\n]*\$ChannelSuffix') 'chan: an explicit -InstallDir is never suffixed'
Assert-Equal 2 ([regex]::Matches($webText, '\$ChannelSuffix').Count) 'chan: the suffix is only defined and used by the default dir'
Assert-True ($webText -match 'Channel = \$Channel') 'chan: the entry passes Channel to the installer splat'
Assert-True ($webText -match 'Write-Host "beta 通道：.*" -ForegroundColor Yellow') 'chan: the entry prints a yellow beta banner'

# Installer: -Channel in, UAC argv forwarding, helper identity, no -Ref.
Assert-True ($mainText -match '\[ValidateSet\(''stable'', ''beta''\)\]\s*\[string\]\s*\$Channel\s*=\s*''stable''') 'chan: installer declares -Channel (stable default)'
Assert-True ($mainText -match '\$argv \+= @\(''-Channel'', \$Channel\)') 'chan: installer forwards -Channel to its UAC child'
Assert-True ($mainText -match 'Get-AgentDevboxChannelIdentity -Variant \$Variant -Channel \$Channel') 'chan: installer resolves the channel identity from the helper'
Assert-True ($mainText -match 'Get-Command Get-AgentDevboxChannelIdentity') 'chan: a missing helper is detected'
Assert-True ($mainText -match '请通过 install.ps1 安装') 'chan: the missing-helper error points at install.ps1'
Assert-True ($mainText -notmatch '\$VariantMap') 'chan: the hardcoded variant map is gone'
Assert-True ($mainText -notmatch '\$Ref\b') 'chan: the installer never learns -Ref'
Assert-True ($mainText -notmatch '\$Label\s*=\s*''devbox-data''') 'chan: the label is never hardcoded'
Assert-True ($mainText -notmatch '\$MountName\s*=\s*''devbox-data''') 'chan: the mount name is never hardcoded'
Assert-True ($mainText -match '\$Label = \$v\.Label') 'chan: the label comes from the identity'
Assert-True ($mainText -match '\$MountName = \$v\.MountName') 'chan: the mount name comes from the identity'

# Channel ownership valve: before UAC, marker written without a BOM.
$markerIdx = $mainText.IndexOf('.agent-devbox-channel')
$uacIdx    = $mainText.IndexOf('if (-not (Test-Admin))')
$newDirIdx = $mainText.IndexOf('New-Item -ItemType Directory -Force -Path $InstallDir')
$writeIdxM = $mainText.IndexOf('WriteAllText($ChannelMarker, $Channel')
Assert-True ($markerIdx -ge 0) 'chan: the channel marker exists'
Assert-True ($markerIdx -ge 0 -and $uacIdx -gt $markerIdx) 'chan: the ownership valve runs BEFORE the UAC hand-off'
Assert-True ($newDirIdx -ge 0 -and $writeIdxM -gt $newDirIdx) 'chan: the marker is written after the install dir exists'
Assert-True ($mainText -match 'WriteAllText\(\$ChannelMarker, \$Channel, \(New-Object System\.Text\.UTF8Encoding\(\$false\)\)\)') 'chan: the marker is written without a BOM'
Assert-True ($mainText -match '\$markedChannel = ''stable''') 'chan: a missing marker defaults to the legacy stable channel'

# Ownership = data.vhdx OR ext4.vhdx. A legacy stable install that failed BEFORE
# the data disk was created still holds ext4.vhdx (its system disk) and no
# data.vhdx; importing beta into that dir would clobber the stable system disk.
$ownedStart = $mainText.IndexOf('$ownedByDisk =')
$ownedGate  = $mainText.IndexOf('if ($ownedByDisk)')
$ownedBlock = if ($ownedStart -ge 0 -and $ownedGate -gt $ownedStart) { $mainText.Substring($ownedStart, $ownedGate - $ownedStart) } else { '' }
Assert-True ($ownedStart -ge 0 -and $ownedStart -lt $uacIdx) 'chan: the ownership probe stays before the UAC hand-off'
Assert-True ($ownedBlock -match 'Test-Path -LiteralPath \(Join-Path \$InstallDir \$VhdxName\)') 'chan: the valve checks data.vhdx'
Assert-True ($ownedBlock -match 'Test-Path -LiteralPath \(Join-Path \$InstallDir ''ext4\.vhdx''\)') 'chan: the valve also checks ext4.vhdx'
Assert-True ($ownedBlock -match '-or') 'chan: both ownership probes feed one gate'
Assert-True ($mainText -match '数据盘（data\.vhdx）或系统盘（ext4\.vhdx') 'chan: the combined ownership rule is documented'
Assert-True ($mainText -notmatch '\$existingVhdx') 'chan: the old data.vhdx-only probe is gone'

# Fatal datadisk-init: after the arch throw, before printing its output.
$archThrowIdx = $mainText.IndexOf('导入的 rootfs 架构与主机不匹配')
$initFailIdx  = $mainText.IndexOf('数据盘初始化失败')
$initOutIdx   = $mainText.IndexOf('Write-Host $initOut')
Assert-True ($initFailIdx -ge 0) 'chan: a failed datadisk-init is fatal'
Assert-True ($archThrowIdx -ge 0 -and $initFailIdx -gt $archThrowIdx) 'chan: the init failure check follows the arch-mismatch throw'
Assert-True ($initOutIdx -gt $initFailIdx) 'chan: the failure check runs BEFORE writing the init output'
Assert-True ($mainText -match '数据盘初始化失败（标签 \$Label，退出码 \$initExit）') 'chan: the init failure names the label and the real exit code'
Assert-True ($mainText -match 'data\.vhdx 已保留') 'chan: the init failure says the data disk is kept'

# Beta rootfs boot-support gate: an old rootfs whose wsl-boot.sh lacks DATA_LABEL
# falls back to the shared `devbox-data` label when the beta disk is not attached,
# so it could mount the production data disk. The probe must refuse it BEFORE
# datadisk-init runs, and the handler must unregister and throw (mkfs never runs).
$guardVarIdx   = $mainText.IndexOf('$channelBootGuard =')
$guardEndIdx   = $mainText.IndexOf("`$initOut = Invoke-Native 'wsl.exe'")
$guardBlock    = if ($guardVarIdx -ge 0 -and $guardEndIdx -gt $guardVarIdx) { $mainText.Substring($guardVarIdx, $guardEndIdx - $guardVarIdx) } else { '' }
$guardThrowIdx = $mainText.IndexOf('beta 通道需要包含 DATA_LABEL 支持的 rootfs')
$guardGrepRel  = $guardBlock.IndexOf('grep -q "DATA_LABEL" /usr/local/bin/wsl-boot.sh')
$guardInitRel  = $guardBlock.IndexOf('/usr/local/bin/datadisk-init.sh')
Assert-True ($guardBlock -match '\$Channel -eq ''beta''') 'chan-boot: the guard is beta-gated'
Assert-True ($guardBlock -match "else \{ '' \}") 'chan-boot: the guard is empty for stable (stable probe unchanged)'
Assert-True ($guardGrepRel -ge 0) 'chan-boot: the guard greps DATA_LABEL in wsl-boot.sh'
Assert-True ($guardBlock -match 'CHANNEL_BOOT_UNSUPPORTED') 'chan-boot: the guard reports CHANNEL_BOOT_UNSUPPORTED'
Assert-True ($guardBlock -match 'exit 43') 'chan-boot: the guard exits 43'
Assert-True ($guardBlock -match '\$probe = \$channelBootGuard \+') 'chan-boot: the guard is prepended to the probe'
Assert-True ($guardGrepRel -ge 0 -and $guardInitRel -gt $guardGrepRel) 'chan-boot: the guard runs BEFORE datadisk-init in the probe'
Assert-True ($mainText -match '\$initExit -eq 43') 'chan-boot: exit 43 is handled explicitly'
Assert-True ($guardThrowIdx -ge 0 -and $initOutIdx -gt $guardThrowIdx) 'chan-boot: the throw runs BEFORE writing the init output'
Assert-True ($mainText -match '请用 -ReleaseTag beta') 'chan-boot: the throw hints -ReleaseTag beta'

# Conf: exactly six keys, DATA_LABEL third.
Assert-Equal 6 ([regex]::Matches($mainText, '(?:DATA_[A-Z]+|PASEO_PASSWORD)=\$\(Quote-Bash').Count) 'conf: exactly six keys are written'
Assert-True ($mainText -match 'DATA_VHDX=\$\(Quote-Bash \$VhdxPath\)`nDATA_UUID=\$\(Quote-Bash \$uuid\)`nDATA_LABEL=\$\(Quote-Bash \$Label\)`nPASEO_PASSWORD=\$\(Quote-Bash \$pw\)`nDATA_MNTNAME=\$\(Quote-Bash \$MountName\)`nDATA_DISTRO=\$\(Quote-Bash \$Distro\)`n') 'conf: DATA_LABEL is the third key (DATA_VHDX, DATA_UUID, DATA_LABEL, PASEO_PASSWORD, DATA_MNTNAME, DATA_DISTRO)'

# Summary banner names the channel.
Assert-True ($mainText -match '通道=\$Channel') 'chan: the install summary shows 通道=$Channel'

# datadisk-init takes the ext4 label as its first argument (no hardcoded name).
Assert-True ($dataInitText -match 'LABEL="\$\{1') 'name: datadisk-init takes the label as $1'
Assert-True ($dataInitText -notmatch 'LABEL=agent-devbox-data') 'name: datadisk-init has no hardcoded label'

# --- [7/10] 数据盘 UUID 解析：标签优先，旧 conf 只作兜底（两个变体可互换 data.vhdx） ---
# 复制另一个变体的 data.vhdx 时，复制盘保留源盘 UUID；若先信旧 conf 就会拿到过期 UUID，
# 永远走不到标签查找。顺序必须是「datadisk-init UUID -> 标签 -> 旧 conf」。
Assert-True ($mainText -match '数据盘 UUID 已变化') 'disk: a changed data-disk UUID is reported (cross-variant copy)'
Assert-True ($mainText -match '\$confUuid') 'disk: the old conf UUID is kept separately as a hint'
$labelIdx = $mainText.IndexOf('blkid -t LABEL=')
$confIdx  = $mainText.IndexOf("sed -n 's/^DATA_UUID=//p'")
Assert-True ($labelIdx -ge 0) 'disk: the label lookup is present'
Assert-True ($confIdx -ge 0) 'disk: the old-conf hint is still read'
Assert-True ($labelIdx -ge 0 -and $confIdx -ge 0 -and $labelIdx -lt $confIdx) 'disk: the label lookup is tried BEFORE the old-conf hint'
Assert-True ($mainText -match '匹配到多个不同的 UUID') 'disk: ambiguous label matches fail closed'

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
Assert-True ($mainText -match 'Start-Sleep -Seconds 10') 'task: interactive hold is present'
Assert-True ($mainText -notmatch '火绒') 'task: the stale AV allow prompt is gone (there is no scheduled task)'
Assert-True ($mainText -match '-not \$Yes') 'task: hold is gated on -not $Yes'
# 计划任务已彻底移除：安装器只清理旧版本注册的任务，并自己 attach 一次。
# conf 现在正好 5 个键（DATA_TASK 已随计划任务一起删除）。
Assert-True ($mainText -match 'DATA_DISTRO=\$\(Quote-Bash \$Distro\)') 'conf: installer writes DATA_DISTRO'
Assert-True ($mainText -notmatch 'DATA_TASK') 'conf: installer no longer writes DATA_TASK'

# --- boot failed 立即失败 + 可粘贴的修复命令 ------------------------------
$diskFn = [regex]::Match($ensureText, 'function Assert-DataDiskMounted[\s\S]*?\r?\n\}').Value
Assert-True ($diskFn -ne '') 'repair: Assert-DataDiskMounted 仍存在'
Assert-True ($diskFn -match '\[Parameter\(Mandatory\)\]\[string\] \$InstallDir') 'repair: Assert-DataDiskMounted 接收 -InstallDir'
Assert-True ($diskFn -match "'FATAL\|boot failed'") 'repair: boot failed 立即判定失败（不再空等 45 秒）'
Assert-True ($diskFn -match 'Join-Path \$InstallDir ''mount-datadisk\.cmd''') 'repair: 失败消息给出 mount-datadisk.cmd 的绝对路径'
Assert-True ($diskFn -match 'wsl --terminate') 'repair: 失败消息给出 wsl --terminate <发行版>'
Assert-True ($mainText -match 'Assert-DataDiskMounted[^\r\n]*-InstallDir \$InstallDir') 'repair: 安装器把安装目录传给挂载断言'

# --- PS 5.1 分片顺序脚本（无 BOM / 纯 ASCII，红门）------------------------
# run.ps1 由 pwsh 跑，但生产主机是 PS 5.1；顺序逻辑必须在 5.1 下单独验证。
# 这里只钉住该脚本的交付形态：存在、无 BOM、纯 ASCII（非 ASCII 在 5.1 的
# ANSI 解码下会被破坏）。
$ps51OrderPath  = Join-Path $here 'ps51-order.ps1'
$ps51OrderBytes = if (Test-Path -LiteralPath $ps51OrderPath) { [System.IO.File]::ReadAllBytes($ps51OrderPath) } else { $null }
Assert-True ($null -ne $ps51OrderBytes) 'ps51: tests/powershell/ps51-order.ps1 exists'
Assert-True ($null -ne $ps51OrderBytes -and -not ($ps51OrderBytes.Length -ge 3 -and $ps51OrderBytes[0] -eq 0xEF -and $ps51OrderBytes[1] -eq 0xBB -and $ps51OrderBytes[2] -eq 0xBF)) 'ps51: the order script has no UTF-8 BOM'
$ps51NonAscii = @()
if ($null -ne $ps51OrderBytes) { $ps51NonAscii = @($ps51OrderBytes | Where-Object { $_ -gt 0x7F }) }
Assert-Equal 0 $ps51NonAscii.Count "ps51: the order script is ASCII only (found $($ps51NonAscii.Count) non-ASCII bytes)"

# --- 架构探测（纯映射，fail closed）--------------------------------------
Assert-Equal 'amd64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'AMD64') 'arch: native x64 -> amd64'
Assert-Equal 'amd64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'x86_64') 'arch: x86_64 alias -> amd64'
Assert-Equal 'arm64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'ARM64') 'arch: native ARM64 -> arm64'
Assert-Equal 'arm64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'aarch64') 'arch: aarch64 alias -> arm64'
Assert-Equal 'amd64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'x86' -ProcessorArchitectureW6432 'AMD64') 'arch: 32-bit PS on x64 -> amd64'
Assert-Equal 'arm64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'x86' -ProcessorArchitectureW6432 'ARM64') 'arch: WOW64 on ARM64 -> arm64'
Assert-Equal 'arm64' (ConvertTo-AgentDevboxArch -ProcessorArchitecture 'AMD64' -MachineArchitecture 'ARM64') 'arch: x64-emulated PS on ARM64 -> arm64'
Assert-Equal 'arm64' (ConvertTo-AgentDevboxArch -CimArchitecture 12) 'arch: CIM 12 -> arm64'
Assert-Equal 'amd64' (ConvertTo-AgentDevboxArch -CimArchitecture 9) 'arch: CIM 9 -> amd64'
Assert-Equal 'arm64' (Get-AgentDevboxHostArch -ProcessorArchitectureW6432 '' -ProcessorArchitecture 'AMD64' -MachineArchitecture 'ARM64' -CimArchitecture 0) 'arch: host helper honours injected sources'
$archUnknown = $false
try { ConvertTo-AgentDevboxArch -ProcessorArchitecture 'x86' -CimArchitecture 0 | Out-Null } catch {
  $archUnknown = $true
  Assert-True ($_.Exception.Message -match '无法确定 Windows 处理器架构') 'arch: unknown names all sources'
}
Assert-True $archUnknown 'arch: unknown fails closed'
$hostUnknown = $false
try { Get-AgentDevboxHostArch -ProcessorArchitectureW6432 'x86' -MachineArchitecture 'x86' -ProcessorArchitecture 'x86' -CimArchitecture 0 | Out-Null } catch { $hostUnknown = $true }
Assert-True $hostUnknown 'arch: host helper fails closed'
Assert-True ($helperText -match 'Get-AgentDevboxHostArch') 'arch: wsl-ui uses the shared helper'
Assert-True ($helperText -notmatch '\$arch = if \(\$env:PROCESSOR_ARCHITECTURE') 'arch: wsl-ui no longer trusts process env alone'

# --- 按架构选择 rootfs（安装器）-----------------------------------------
Assert-True ($mainText -match '\$Arch\s*=\s*Get-AgentDevboxHostArch') 'arch: installer resolves host architecture'
Assert-True ($mainText -match 'rootfs-\$Variant-\$Arch\.tar\.zst') 'arch: rootfs stem uses $Arch'
Assert-True ($mainText -notmatch 'rootfs-\$Variant-amd64') 'arch: no hardcoded amd64 rootfs name'
Assert-True ($mainText -match '没有 ARM64 分片') 'arch: old amd64-only release is explained'
Assert-True ($mainText -match 'Windows 10 ARM64') 'arch: Windows 10 ARM64 rejected readably'
Assert-True ($mainText -match '\$osBuild -lt 22000') 'arch: ARM64 gate requires Windows 11 build 22000'
Assert-True ($mainText.Contains('在 ''$ReleaseTag'' Release 中未找到')) 'arch: non-ARM64 hosts keep the old missing-parts error'
$archIdx  = $mainText.IndexOf('$Arch = Get-AgentDevboxHostArch')
$dlIdx    = $mainText.IndexOf('Save-Download -Url')
$unregIdx = $mainText.IndexOf('--unregister')
Assert-True ($archIdx -ge 0 -and $dlIdx -ge 0 -and $archIdx -lt $dlIdx) 'arch: resolves before download'
Assert-True ($archIdx -ge 0 -and $unregIdx -ge 0 -and $archIdx -lt $unregIdx) 'arch: resolves before any unregister'

# --- ARM64 Tier 3 跳过与导入后架构探针 -----------------------------------
$skipIdx = $mainText.IndexOf('ARM64 不提供 Tier 3')
$zstdIdx = $mainText.IndexOf('Get-ZstdExe -InstallDir')
Assert-True ($skipIdx -ge 0 -and $zstdIdx -ge 0 -and $skipIdx -lt $zstdIdx) 'tier3: ARM64 skips before zstd.exe'
$skipText = if ($skipIdx -ge 0 -and $zstdIdx -gt $skipIdx) { $mainText.Substring($skipIdx, $zstdIdx - $skipIdx) } else { '' }
Assert-True ($skipText -notmatch 'ContentSuspect') 'tier3: skip keeps parts (no suspect flag)'
Assert-True ($mainText -match "\`$Arch -eq 'arm64'") 'tier3: skip is arch-gated'
$probeIdx = $mainText.IndexOf('uname -m')
$initIdx  = $mainText.IndexOf('/usr/local/bin/datadisk-init.sh')
Assert-True ($probeIdx -ge 0 -and $initIdx -ge 0 -and $probeIdx -lt $initIdx) 'arch: uname probe precedes datadisk-init'
Assert-True ($mainText -match 'aarch64') 'arch: expected ARM64 uname is aarch64'
Assert-True ($mainText -match 'x86_64') 'arch: expected x64 uname is x86_64'
Assert-True ($mainText -match 'ARCH_MISMATCH') 'arch: mismatch is reported'
Assert-True ($mainText -match 'Exec format error') 'arch: unexecutable rootfs is explained'
Assert-True ($mainText -match '\$expectedMachine = if \(\$Arch -eq ''arm64''\)') 'arch: expected uname is derived from the host arch'
Assert-True ($mainText -match '\$initExit -ne 0 -and') 'arch: mismatch throw requires a non-zero exit'

# --- CI: 原生双架构导出 + 合并发布 --------------------------------
Assert-True ($ciText -match 'upload-artifact') 'ci: per-arch rootfs artifact'
Assert-True ($ciText -match 'download-artifact') 'ci: publish downloads artifacts'
Assert-True ($ciText -match 'merge-multiple:\s*true') 'ci: artifacts merge into one dir'
Assert-True ($ciText -match 'usr/bin/dash') 'ci: export checks the rootfs ELF'
Assert-True ($ciText -match 'zstd -dc \| tar -xOf - usr/bin/dash') 'ci: split parts are arch-checked'
Assert-True ($ciText -notmatch '--platform linux/amd64') 'ci: no hardcoded amd64 platform'
Assert-True ($ciText -match 'retention-days:\s*3') 'ci: transient artifacts expire'
Assert-True ($ciText -match 'needs: \[plan, export\]') 'ci: publish waits for both exports'

Write-Host ''
if ($script:Failed -gt 0) {
  Write-Host "$script:Failed/$script:Total assertions FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "all $script:Total assertions passed" -ForegroundColor Green
exit 0
