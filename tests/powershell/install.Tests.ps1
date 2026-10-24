# Pester coverage for pure helpers that the dependency-free runner does not
# touch. These three are the last line of defence for Tier 2 merging, argv
# quoting, and partial-download cleanup.
#
#   Invoke-Pester -Path tests/powershell/install.Tests.ps1 -CI

#Requires -Version 5.1
BeforeAll {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path (Join-Path $repoRoot 'windows') 'wsl-ensure.ps1')
}

Describe 'Join-Parts' {
  It 'concatenates ordered parts byte-for-byte and overwrites the destination' {
    $p1 = Join-Path $TestDrive 'part-00'
    $p2 = Join-Path $TestDrive 'part-01'
    $dest = Join-Path $TestDrive 'merged.tar.zst'

    [System.IO.File]::WriteAllBytes($p1, [byte[]](0, 1, 2, 255))
    [System.IO.File]::WriteAllBytes($p2, [byte[]](9, 8, 7))
    [System.IO.File]::WriteAllBytes($dest, [byte[]](42, 42, 42, 42, 42, 42, 42, 42, 42))

    Join-Parts -Parts @($p1, $p2) -Dest $dest

    $actual = [System.IO.File]::ReadAllBytes($dest)
    ($actual -join ',') | Should -Be '0,1,2,255,9,8,7'
    $actual.Length | Should -Be 7
  }
}

Describe 'Join-Segments' {
  It 'concatenates in order, deletes each input and leaves unrelated files alone' {
    $p1 = Join-Path $TestDrive 'seg-000'
    $p2 = Join-Path $TestDrive 'seg-001'
    $dest = Join-Path $TestDrive 'joined.bin'
    $keep = Join-Path $TestDrive 'keep.txt'

    [System.IO.File]::WriteAllBytes($p1, [byte[]](0, 1, 2, 255))
    [System.IO.File]::WriteAllBytes($p2, [byte[]](9, 8, 7))
    [System.IO.File]::WriteAllBytes($dest, [byte[]](42, 42, 42, 42, 42, 42, 42, 42, 42))
    [System.IO.File]::WriteAllText($keep, 'keep')

    Join-Segments -Segments @($p1, $p2) -Dest $dest | Out-Null

    $actual = [System.IO.File]::ReadAllBytes($dest)
    ($actual -join ',') | Should -Be '0,1,2,255,9,8,7'
    $actual.Length | Should -Be 7
    Test-Path -LiteralPath $p1 | Should -BeFalse
    Test-Path -LiteralPath $p2 | Should -BeFalse
    Test-Path -LiteralPath $keep | Should -BeTrue
  }
}

Describe 'Quote-NativeArg' {
  It 'quotes spaces, embedded quotes and a trailing backslash for a native argv' {
    (Quote-NativeArg -Arg 'a b') | Should -Be '"a b"'
    (Quote-NativeArg -Arg 'a"b') | Should -Be '"a\"b"'
    (Quote-NativeArg -Arg 'C:\path\') | Should -Be '"C:\path\\"'
  }
}

Describe 'Remove-DownloadArtifacts' {
  It 'removes the part and its sidecar but leaves unrelated files alone' {
    $dest = Join-Path $TestDrive 'rootfs-core-amd64.tar.zst.part-00'
    $meta = Get-DownloadMetaPath -Dest $dest
    $keep = Join-Path $TestDrive 'keep.txt'

    [System.IO.File]::WriteAllText($dest, 'partial')
    New-Item -ItemType Directory -Path (Split-Path -Parent $meta) -Force | Out-Null
    [System.IO.File]::WriteAllText($meta, '{"version":1}')
    [System.IO.File]::WriteAllText($keep, 'keep')

    Remove-DownloadArtifacts -Dest $dest

    Test-Path -LiteralPath $dest | Should -BeFalse
    Test-Path -LiteralPath $meta | Should -BeFalse
    Test-Path -LiteralPath $keep | Should -BeTrue
  }
}
