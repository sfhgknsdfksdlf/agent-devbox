<#
.SYNOPSIS
  Lazily loaded download-and-execute helpers for the agent-devbox Windows installer.

.DESCRIPTION
  Loaded on demand by `wsl-ensure.ps1` via `Get-AgentDevboxDownloadHelperPath`;
  never dot-sourced on the happy path (WSL already present -> the Tier 1 streaming
  import needs neither function).

  Contains the only download-and-execute primitives:
    Install-WslUi          - download the wsl-ui NSIS installer and run it silently
    Get-ZstdExeFromRelease - fetch the pinned zstd.exe for the Tier 3 fallback

  Dot-source-safe: no param() block and no load-time code, only definitions.
  Kept separate from wsl-ensure.ps1 so the always-loaded working file carries no
  download-and-execute shape (Huorong static heuristics).

.NOTES
  Read via `-File`/dot-source, so this file is UTF-8 WITH a BOM (PS 5.1 would
  otherwise read it as ANSI and garble the Chinese strings).
#>

# ---------------------------------------------------------------------------
# Pinned upstream releases
# ---------------------------------------------------------------------------
# wsl-ui: an exact release tag + per-arch asset name + SHA256. This helper
# never resolves a moving "latest" release at runtime and never executes bytes
# it could not verify. An architecture missing from this table fails closed:
# no download, no unblock, no execution.
#
# Source (re-downloaded and hashed 2026-11-23 from the official GitHub Release):
#   https://github.com/octasoft-ltd/wsl-ui/releases/tag/v0.21.0
#   The GitHub Release asset API `digest` for both files is SHA256 and matched
#   the locally recomputed hashes:
#     x64   84f5c6d074fce27a26eba6a49a55d51f961152244b4bb8e6f6efcfd1fe5d3ece  3714767 bytes
#     arm64 2ede6da67790c38b76b9c1cb77fec222458b29cfa76243617402d449d8e25abe  3407405 bytes
function Get-WslUiReleaseSpec {
  [CmdletBinding()]
  param()
  [pscustomobject]@{
    Version = '0.21.0'
    Tag     = 'v0.21.0'
    Repo    = 'octasoft-ltd/wsl-ui'
    Assets  = @{
      'x64' = [pscustomobject]@{
        Name   = 'WSL.UI_0.21.0_x64-setup.exe'
        Length = [int64]3714767
        Sha256 = '84f5c6d074fce27a26eba6a49a55d51f961152244b4bb8e6f6efcfd1fe5d3ece'
      }
      'arm64' = [pscustomobject]@{
        Name   = 'WSL.UI_0.21.0_arm64-setup.exe'
        Length = [int64]3407405
        Sha256 = '2ede6da67790c38b76b9c1cb77fec222458b29cfa76243617402d449d8e25abe'
      }
    }
  }
}

# zstd 1.5.7 (win64) for the x64-only Tier 3 fallback. Both the zip and the
# extracted zstd.exe are pinned, and ONLY the reviewed in-archive path is
# accepted (no recursive same-name search).
#
# Source: https://github.com/facebook/zstd/releases/tag/v1.5.7 — that release
# exposes no asset `digest` in the GitHub API, so both SHA256 values were
# computed locally (2026-11-23) from the official release bytes:
#   zstd-v1.5.7-win64.zip          acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9  1747181 bytes
#   zstd-v1.5.7-win64/zstd.exe     8076aae03feac7c66b319579e82172eed168deed2a3f25e5e2d3c60f55e84111  1601409 bytes
function Get-ZstdReleaseSpec {
  [CmdletBinding()]
  param()
  [pscustomobject]@{
    Version   = '1.5.7'
    Url       = 'https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip'
    ZipName   = 'zstd-v1.5.7-win64.zip'
    ZipLength = [int64]1747181
    ZipSha256 = 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'
    ExeDir    = 'zstd-v1.5.7-win64'
    ExeName   = 'zstd.exe'
    ExeLength = [int64]1601409
    ExeSha256 = '8076aae03feac7c66b319579e82172eed168deed2a3f25e5e2d3c60f55e84111'
  }
}

# Normalize an architecture to the installer's amd64|arm64 vocabulary. Fails
# closed: an unknown machine value is returned as-is so callers reject it.
# Get-AgentDevboxHostArch already prefers the machine-scope registry value (an
# x64-emulated PowerShell on ARM64 reports AMD64), and it throws on unknown.
function Resolve-AgentDevboxDownloadArch {
  [CmdletBinding()]
  param([string] $Arch)
  $raw = $Arch
  if (-not $raw) {
    if (Get-Command Get-AgentDevboxHostArch -ErrorAction SilentlyContinue) {
      $raw = Get-AgentDevboxHostArch
    } else {
      $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
      if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $machine -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        $raw = 'arm64'
      } else {
        $raw = 'amd64'
      }
    }
  }
  switch (([string]$raw).ToLowerInvariant()) {
    'amd64' { 'amd64' }
    'x64' { 'amd64' }
    'arm64' { 'arm64' }
    default { ([string]$raw).ToLowerInvariant() }
  }
}

# Length first, then SHA256. Never treat a partial/failed download as usable.
function Assert-AgentDevboxDownloadFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Description,
    [Parameter(Mandatory)][string] $ExpectedSha256,
    [Parameter(Mandatory)][int64] $ExpectedLength
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Description 不存在：$Path"
  }
  $length = [int64](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
  if ($length -ne $ExpectedLength) {
    throw ('{0} 大小不符：期望 {1} 字节，实际 {2} 字节。' -f $Description, $ExpectedLength, $length)
  }
  $actual = [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
  if ($actual.ToLowerInvariant() -ne $ExpectedSha256.ToLowerInvariant()) {
    throw ('{0} SHA256 不符：期望 {1}，实际 {2}。' -f $Description, $ExpectedSha256.ToLowerInvariant(), $actual.ToLowerInvariant())
  }
}

function Install-WslUi {
  [CmdletBinding()]
  param([string] $Arch)

  $ErrorActionPreference = 'Stop'
  $resolved = Resolve-AgentDevboxDownloadArch -Arch $Arch
  $spec = Get-WslUiReleaseSpec
  $archKey = if ($resolved -eq 'amd64') { 'x64' } elseif ($resolved -eq 'arm64') { 'arm64' } else { $resolved }
  if (-not $spec.Assets.ContainsKey($archKey)) {
    throw ("没有可验证的 wsl-ui {0} 安装包（固定版本 {1}）：已停止，不会下载未校验的安装程序。" -f $resolved, $spec.Version)
  }
  $asset = $spec.Assets[$archKey]
  $url = "https://github.com/$($spec.Repo)/releases/download/$($spec.Tag)/$($asset.Name)"

  Write-Host "正在安装 wsl-ui $($spec.Version) ($archKey)…"
  # Private per-run scratch dir: verification happens here, never in InstallDir.
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wslui-' + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $exe = Join-Path $tmp $asset.Name
    Write-Host "  正在下载 $($asset.Name)…"
    Invoke-WebRequest -Uri $url -OutFile $exe
    # Length + SHA256 BEFORE the file is unblocked or executed. A mismatch
    # throws, so the finally block only deletes the scratch dir.
    Assert-AgentDevboxDownloadFile -Path $exe -Description "wsl-ui $archKey 安装包" -ExpectedSha256 $asset.Sha256 -ExpectedLength $asset.Length
    Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
    Write-Host '  正在静默安装…'
    $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "wsl-ui setup.exe 退出码 $($p.ExitCode)" }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'wsl-ui 已安装。'
}

# Fetch (once) the pinned zstd.exe for the x64-only Tier 3 fallback. An existing
# cached copy is re-verified on every call; a corrupt one is deleted, never
# reused. ARM64 must never fetch it (the published binary is win64-only).
function Get-ZstdExeFromRelease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $InstallDir,
    [string] $Arch
  )
  $ErrorActionPreference = 'Stop'
  $resolved = Resolve-AgentDevboxDownloadArch -Arch $Arch
  if ($resolved -eq 'arm64') {
    throw 'ARM64 不提供 Tier 3：win64 的 zstd.exe 无法在该架构运行，已跳过下载。'
  }
  if ($resolved -ne 'amd64') {
    throw ("无法确认可用于 zstd.exe 的架构（{0}），已停止，不会下载未校验的程序。" -f $resolved)
  }

  $spec = Get-ZstdReleaseSpec
  $zstdExe = Join-Path $InstallDir $spec.ExeName
  if (Test-Path -LiteralPath $zstdExe -PathType Leaf) {
    try {
      Assert-AgentDevboxDownloadFile -Path $zstdExe -Description '缓存的 zstd.exe' -ExpectedSha256 $spec.ExeSha256 -ExpectedLength $spec.ExeLength
      return $zstdExe
    } catch {
      Remove-Item -LiteralPath $zstdExe -Force -ErrorAction SilentlyContinue
    }
  }

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('zstd-' + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $zip = Join-Path $tmp $spec.ZipName
    Write-Host "正在获取 zstd $($spec.Version)（用于解压）…"
    Invoke-WebRequest -Uri $spec.Url -OutFile $zip
    Assert-AgentDevboxDownloadFile -Path $zip -Description 'zstd 压缩包' -ExpectedSha256 $spec.ZipSha256 -ExpectedLength $spec.ZipLength

    $expanded = Join-Path $tmp 'expanded'
    Expand-Archive -Path $zip -DestinationPath $expanded -Force
    # Exact reviewed path only: a same-name file elsewhere is never accepted.
    $entry = Join-Path (Join-Path $expanded $spec.ExeDir) $spec.ExeName
    Assert-AgentDevboxDownloadFile -Path $entry -Description '解压出的 zstd.exe' -ExpectedSha256 $spec.ExeSha256 -ExpectedLength $spec.ExeLength

    # Only replace the cache after the extracted exe verified, then re-verify
    # the installed copy.
    Copy-Item -LiteralPath $entry -Destination $zstdExe -Force
    Assert-AgentDevboxDownloadFile -Path $zstdExe -Description '安装的 zstd.exe' -ExpectedSha256 $spec.ExeSha256 -ExpectedLength $spec.ExeLength
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  return $zstdExe
}
