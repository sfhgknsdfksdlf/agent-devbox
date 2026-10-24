# PS 5.1 regression gate: segmented-download join order.
#
# Verifies that Get-SegmentFileOrder orders out-of-order hashtable records by
# their integer Index, and that Join-Segments concatenates the segments in that
# order. Sort-Object -Property over Hashtable entries is wrong on 5.1
# (Index 0,1,2,3 is returned as 2,3,0,1), so this gate is the contract.
#
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File ps51-order.ps1
# Exit 0 and print "ps51-order ok" only when both checks hold.

$ErrorActionPreference = 'Stop'

# Resolve the repository root without PS 7 only parameters (no -AdditionalChildPath).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path (Join-Path $root 'windows') 'wsl-ensure.ps1')

function Write-ByteFile {
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][int] $Value
  )
  $one = New-Object byte[] 1
  $one[0] = [byte]$Value
  [System.IO.File]::WriteAllBytes($Path, $one)
}

$exitCode = 0
$tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'adbox-ps51-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempDir)

try {
  $f0 = Join-Path $tempDir 'seg-0'
  $f1 = Join-Path $tempDir 'seg-1'
  $f2 = Join-Path $tempDir 'seg-2'
  $f3 = Join-Path $tempDir 'seg-3'
  Write-ByteFile -Path $f0 -Value 0x10
  Write-ByteFile -Path $f1 -Value 0x20
  Write-ByteFile -Path $f2 -Value 0x30
  Write-ByteFile -Path $f3 -Value 0x40

  # Same container and order the downloader builds: Save-DownloadSegmented does
  #   $segments = New-Object System.Collections.Generic.List[object]
  #   foreach ($p in $plan) { $segments.Add(@{ ... Index = [int]$p.Index ... }) }
  # so the list arrives in plan order 0,1,2,3 and only the helper may reorder it.
  # Sort-Object -Property Index cannot see hashtable keys on 5.1 (keys are not
  # PSObject properties), so every key is null and the unstable sort permutes
  # 0,1,2,3 into 2,3,0,1. Feeding a pre-scrambled 2,3,0,1 list would hide that
  # bug (the same permutation lands back on 0,1,2,3), so do NOT reorder these
  # Add calls and do NOT use an array literal here.
  $segs = New-Object System.Collections.Generic.List[object]
  $segs.Add(@{ Index = 0; File = $f0 })
  $segs.Add(@{ Index = 1; File = $f1 })
  $segs.Add(@{ Index = 2; File = $f2 })
  $segs.Add(@{ Index = 3; File = $f3 })

  $orderError = $null
  $ordered = @()
  try {
    $ordered = @(Get-SegmentFileOrder -Segments $segs)
  } catch {
    $orderError = $_.Exception.Message
  }

  if ($null -ne $orderError) {
    Write-Host ('GET_SEGMENT_ORDER_BAD: ' + $orderError)
    $exitCode = 1
  } else {
    $expected = @($f0, $f1, $f2, $f3)
    $actual = @($ordered | ForEach-Object { [string]$_ })
    if ($actual.Count -ne $expected.Count -or (($actual -join '|') -ne ($expected -join '|'))) {
      Write-Host ('GET_SEGMENT_ORDER_BAD: ' + ($actual -join '|'))
      $exitCode = 1
    } else {
      $out = Join-Path $tempDir 'joined.bin'
      Join-Segments -Segments $ordered -Dest $out | Out-Null
      $bytes = [System.IO.File]::ReadAllBytes($out)
      $expectedBytes = @(0x10, 0x20, 0x30, 0x40)
      $ok = ($bytes.Length -eq $expectedBytes.Count)
      if ($ok) {
        for ($i = 0; $i -lt $expectedBytes.Count; $i++) {
          if ([int]$bytes[$i] -ne [int]$expectedBytes[$i]) {
            $ok = $false
            break
          }
        }
      }
      if (-not $ok) {
        $hex = if ($bytes.Length -eq 0) {
          '(empty)'
        } else {
          (($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
        Write-Host ('JOIN_SEGMENTS_BAD: ' + $hex)
        $exitCode = 1
      } else {
        Write-Host 'ps51-order ok'
      }
    }
  }
} catch {
  Write-Host ('JOIN_SEGMENTS_BAD: ' + $_.Exception.Message)
  $exitCode = 1
} finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

exit $exitCode
