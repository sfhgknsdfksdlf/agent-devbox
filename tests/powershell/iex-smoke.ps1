# In-memory (irm | iex) smoke test for the Windows entry script.
#
# Why this exists: the AST parse in CI reads install.ps1 with -File, which never
# reproduces the web-entry path. A UTF-8 BOM (U+FEFF) survives the in-memory
# string and breaks parsing on PowerShell 5.1, and an `exit` would kill the
# caller's shell. This script executes install.ps1 from its text and stops at a
# mocked external boundary, so no network, UAC, or filesystem writes happen.
#
# Run under BOTH hosts (the production entry is PS 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/powershell/iex-smoke.ps1
#   pwsh       -NoProfile                            -File tests/powershell/iex-smoke.ps1

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Two-argument Join-Path only: PowerShell 5.1 has no -AdditionalChildPath, so a
# third positional argument is a runtime error ("positional parameter cannot be
# found") in the very host this smoke exists to cover.
$entry = Join-Path (Join-Path $repoRoot 'windows') 'install.ps1'
if (-not (Test-Path -LiteralPath $entry)) { throw "missing entry script: $entry" }

# A BOM would survive `Invoke-RestMethod` as U+FEFF and break [CmdletBinding()]
# on PS 5.1. Check the raw bytes, because Get-Content strips a BOM.
$bytes = [System.IO.File]::ReadAllBytes($entry)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
  throw 'install.ps1 must be UTF-8 WITHOUT a BOM (a BOM breaks the in-memory web entry on PS 5.1)'
}

$raw = Get-Content -Raw -LiteralPath $entry -Encoding UTF8

# Mock the first external boundary the entry reaches: Read-Host when interactive,
# Invoke-RestMethod when not. Start-Process is mocked so a future reordering can
# never pop UAC in CI. All mocks throw the same sentinel.
$sentinel = 'AGENT_DEVBOX_IEX_SMOKE_STOP'
function global:Read-Host { throw $sentinel }
function global:Invoke-RestMethod { throw $sentinel }
function global:Invoke-WebRequest { throw $sentinel }
function global:Start-Process { throw $sentinel }

$stopped = $false
try {
  $raw | Invoke-Expression
} catch {
  if ("$($_.Exception.Message)" -notlike "*$sentinel*") { throw }
  $stopped = $true
}

if (-not $stopped) {
  throw 'install.ps1 ran past the mocked network/elevation boundary (the smoke did not stop)'
}

Write-Host "iex smoke ok: PowerShell $($PSVersionTable.PSVersion) executed windows/install.ps1 from memory and stopped at the mocked boundary"
