# Pester coverage for pure helpers that the dependency-free runner does not
# touch. These three are the last line of defence for Tier 2 merging, argv
# quoting, and partial-download cleanup.
#
#   Invoke-Pester -Path tests/powershell/install.Tests.ps1 -CI

#Requires -Version 5.1
BeforeAll {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path (Join-Path $repoRoot 'windows') 'wsl-ensure.ps1')
  . (Join-Path (Join-Path $repoRoot 'windows') 'wsl-ensure-downloads.ps1')

  # Creates a sparse file of an exact length so the download helper's size gate
  # can run against real files while Get-FileHash is mocked. No multi-MB writes.
  function New-P05SizedFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][int64] $Length)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $fs.SetLength($Length) } finally { $fs.Dispose() }
  }
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

Describe 'Get-AgentDevboxChannelIdentity' {
  It 'keeps the stable agents identity exactly as today' {
    $id = Get-AgentDevboxChannelIdentity -Variant 'agents' -Channel 'stable'
    $id.Variant | Should -Be 'agents'
    $id.Channel | Should -Be 'stable'
    $id.Distro | Should -Be 'agent-devbox'
    $id.InstallDir | Should -Be 'D:\WSL\agent-devbox'
    $id.Label | Should -Be 'devbox-data'
    $id.MountName | Should -Be 'devbox-data'
    $id.TerminalGuid | Should -Be '{6f4a1c2e-8b3d-4a97-9c51-0e7d2b8f3a64}'
    $id.HideGuid | Should -Be '{04014822-8112-5520-a687-27d5f19a9da6}'
  }

  It 'gives beta core a fully distinct identity' {
    $id = Get-AgentDevboxChannelIdentity -Variant 'core' -Channel 'beta'
    $id.Variant | Should -Be 'core'
    $id.Channel | Should -Be 'beta'
    $id.Distro | Should -Be 'agent-devbox-core-beta'
    $id.InstallDir | Should -Be 'D:\WSL\agent-devbox-core-beta'
    $id.Label | Should -Be 'devbox-data-beta'
    $id.MountName | Should -Be 'devbox-data-beta'
    $id.TerminalGuid | Should -Be '{9c0a398c-65c5-4a2f-85e5-220af66bac1b}'
    $id.HideGuid | Should -Be '{e6647892-a55a-456d-841d-4c4faed607b9}'

    $stable = Get-AgentDevboxChannelIdentity -Variant 'core' -Channel 'stable'
    $id.Distro | Should -Not -Be $stable.Distro
    $id.InstallDir | Should -Not -Be $stable.InstallDir
    $id.Label | Should -Not -Be $stable.Label
    $id.MountName | Should -Not -Be $stable.MountName
    $id.TerminalGuid | Should -Not -Be $stable.TerminalGuid
    $id.HideGuid | Should -Not -Be $stable.HideGuid
  }
}

Describe 'Install-WslUi: pinned release and verified bytes' {
  BeforeEach {
    Mock Write-Host {}
    $script:p05Order = New-Object System.Collections.Generic.List[string]
  }

  It 'x64: downloads the pinned v0.21.0 asset, verifies, then unblocks and installs' {
    $script:p05Asset = (Get-WslUiReleaseSpec).Assets['x64']
    $script:p05Url = $null
    $script:p05Out = $null
    Mock Invoke-WebRequest {
      $script:p05Order.Add('download')
      $script:p05Url = $Uri
      $script:p05Out = $OutFile
      New-P05SizedFile -Path $OutFile -Length $script:p05Asset.Length
    }
    Mock Get-FileHash {
      $script:p05Order.Add('hash')
      [pscustomobject]@{ Hash = $script:p05Asset.Sha256.ToUpperInvariant() }
    }
    Mock Unblock-File { $script:p05Order.Add('unblock') }
    Mock Start-Process {
      $script:p05Order.Add('start')
      [pscustomobject]@{ ExitCode = 0 }
    }

    Install-WslUi -Arch 'x64'

    $script:p05Url | Should -Be ('https://github.com/octasoft-ltd/wsl-ui/releases/download/v0.21.0/' + $script:p05Asset.Name)
    $script:p05Url | Should -Not -Match 'releases/latest'
    $script:p05Order.IndexOf('hash') | Should -BeLessThan $script:p05Order.IndexOf('unblock')
    $script:p05Order.IndexOf('unblock') | Should -BeLessThan $script:p05Order.IndexOf('start')
    Should -Invoke Start-Process -Times 1 -Exactly
    Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/S' }
    Test-Path -LiteralPath (Split-Path -Parent $script:p05Out) | Should -BeFalse
  }

  It 'arm64: downloads the pinned arm64 asset from an exact URL' {
    $script:p05Asset = (Get-WslUiReleaseSpec).Assets['arm64']
    $script:p05Url = $null
    Mock Invoke-WebRequest {
      $script:p05Url = $Uri
      New-P05SizedFile -Path $OutFile -Length $script:p05Asset.Length
    }
    Mock Get-FileHash { [pscustomobject]@{ Hash = $script:p05Asset.Sha256 } }
    Mock Unblock-File {}
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

    Install-WslUi -Arch 'arm64'

    $script:p05Url | Should -Be ('https://github.com/octasoft-ltd/wsl-ui/releases/download/v0.21.0/' + $script:p05Asset.Name)
    $script:p05Asset.Name | Should -Be 'WSL.UI_0.21.0_arm64-setup.exe'
    Should -Invoke Start-Process -Times 1 -Exactly
  }

  It 'unknown arch: fails closed without downloading, unblocking or executing' {
    Mock Invoke-WebRequest {}
    Mock Get-FileHash { throw 'must not hash' }
    Mock Unblock-File {}
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

    { Install-WslUi -Arch 'riscv64' } | Should -Throw

    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    Should -Invoke Get-FileHash -Times 0 -Exactly
    Should -Invoke Unblock-File -Times 0 -Exactly
    Should -Invoke Start-Process -Times 0 -Exactly
  }

  It 'wrong SHA256: throws before unblocking or executing the installer' {
    $script:p05Asset = (Get-WslUiReleaseSpec).Assets['x64']
    Mock Invoke-WebRequest { New-P05SizedFile -Path $OutFile -Length $script:p05Asset.Length }
    Mock Get-FileHash { [pscustomobject]@{ Hash = ('0' * 64) } }
    Mock Unblock-File {}
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

    { Install-WslUi -Arch 'x64' } | Should -Throw '*SHA256*'

    Should -Invoke Unblock-File -Times 0 -Exactly
    Should -Invoke Start-Process -Times 0 -Exactly
  }

  It 'wrong length: throws before unblocking or executing the installer' {
    $script:p05Asset = (Get-WslUiReleaseSpec).Assets['x64']
    Mock Invoke-WebRequest { New-P05SizedFile -Path $OutFile -Length ($script:p05Asset.Length - 1) }
    Mock Get-FileHash { [pscustomobject]@{ Hash = $script:p05Asset.Sha256 } }
    Mock Unblock-File {}
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

    { Install-WslUi -Arch 'x64' } | Should -Throw '*大小*'

    Should -Invoke Unblock-File -Times 0 -Exactly
    Should -Invoke Start-Process -Times 0 -Exactly
  }

  It 'installer non-zero exit: surfaces the exit code' {
    $script:p05Asset = (Get-WslUiReleaseSpec).Assets['x64']
    Mock Invoke-WebRequest { New-P05SizedFile -Path $OutFile -Length $script:p05Asset.Length }
    Mock Get-FileHash { [pscustomobject]@{ Hash = $script:p05Asset.Sha256 } }
    Mock Unblock-File {}
    Mock Start-Process { [pscustomobject]@{ ExitCode = 23 } }

    { Install-WslUi -Arch 'x64' } | Should -Throw '*23*'
    Should -Invoke Unblock-File -Times 1 -Exactly
    Should -Invoke Start-Process -Times 1 -Exactly
  }
}

Describe 'Get-ZstdExeFromRelease: pinned zip/exe and cache reverification' {
  BeforeEach {
    Mock Write-Host {}
    $script:p05Spec = Get-ZstdReleaseSpec
    $script:p05Install = Join-Path $TestDrive ('zstd-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:p05Install -Force | Out-Null
    $script:p05Installed = Join-Path $script:p05Install 'zstd.exe'
    $script:p05Order = New-Object System.Collections.Generic.List[string]
    $script:p05Hashed = New-Object System.Collections.Generic.List[string]
    $script:p05ZipPath = $null
    $script:p05Unblocked = $false

    Mock Invoke-WebRequest {
      $script:p05Order.Add('download-zip')
      $script:p05ZipPath = $OutFile
      New-P05SizedFile -Path $OutFile -Length $script:p05Spec.ZipLength
    }
    Mock Get-FileHash {
      $script:p05Hashed.Add($LiteralPath)
      $script:p05Order.Add('hash')
      if ($LiteralPath -like '*.zip') {
        [pscustomobject]@{ Hash = $script:p05Spec.ZipSha256 }
      } else {
        [pscustomobject]@{ Hash = $script:p05Spec.ExeSha256 }
      }
    }
    Mock Expand-Archive {
      $script:p05Order.Add('expand')
      $dir = Join-Path $DestinationPath $script:p05Spec.ExeDir
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      New-P05SizedFile -Path (Join-Path $dir $script:p05Spec.ExeName) -Length $script:p05Spec.ExeLength
    }
    Mock Unblock-File { $script:p05Unblocked = $true }
  }

  It 'verifies the zip before expanding, accepts only the reviewed path, and installs a verified exe' {
    $result = Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64'

    $result | Should -Be $script:p05Installed
    Test-Path -LiteralPath $result | Should -BeTrue
    $script:p05Order[0] | Should -Be 'download-zip'
    $script:p05Order.IndexOf('hash') | Should -BeLessThan $script:p05Order.IndexOf('expand')
    @($script:p05Order | Where-Object { $_ -eq 'hash' }).Count | Should -BeGreaterOrEqual 2
    $script:p05Unblocked | Should -Be $false
    Test-Path -LiteralPath (Split-Path -Parent $script:p05ZipPath) | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $script:p05Install 'zstd.zip') | Should -BeFalse
  }

  It 'wrong zip SHA256: throws before extracting and installs nothing' {
    Mock Get-FileHash {
      if ($LiteralPath -like '*.zip') { [pscustomobject]@{ Hash = ('0' * 64) } }
      else { [pscustomobject]@{ Hash = $script:p05Spec.ExeSha256 } }
    }

    { Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64' } | Should -Throw '*压缩包*'

    Should -Invoke Expand-Archive -Times 0 -Exactly
    Test-Path -LiteralPath $script:p05Installed | Should -BeFalse
  }

  It 'wrong extracted exe SHA256: throws and never replaces the destination' {
    Mock Get-FileHash {
      if ($LiteralPath -like '*.zip') { [pscustomobject]@{ Hash = $script:p05Spec.ZipSha256 } }
      else { [pscustomobject]@{ Hash = ('0' * 64) } }
    }

    { Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64' } | Should -Throw '*zstd.exe*'

    Should -Invoke Expand-Archive -Times 1 -Exactly
    Test-Path -LiteralPath $script:p05Installed | Should -BeFalse
  }

  It 'wrong cached exe: is never reused; a verified download replaces it' {
    New-P05SizedFile -Path $script:p05Installed -Length $script:p05Spec.ExeLength
    $script:p05CacheChecked = $false
    Mock Get-FileHash {
      if ($LiteralPath -eq $script:p05Installed -and -not $script:p05CacheChecked) {
        $script:p05CacheChecked = $true
        return [pscustomobject]@{ Hash = ('f' * 64) }
      }
      if ($LiteralPath -like '*.zip') { return [pscustomobject]@{ Hash = $script:p05Spec.ZipSha256 } }
      [pscustomobject]@{ Hash = $script:p05Spec.ExeSha256 }
    }

    $result = Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64'

    $result | Should -Be $script:p05Installed
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    Should -Invoke Expand-Archive -Times 1 -Exactly
    Test-Path -LiteralPath $script:p05Installed | Should -BeTrue
  }

  It 'good cached exe: is reverified and reused without downloading' {
    New-P05SizedFile -Path $script:p05Installed -Length $script:p05Spec.ExeLength

    $result = Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64'

    $result | Should -Be $script:p05Installed
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    Should -Invoke Expand-Archive -Times 0 -Exactly
    $script:p05Hashed | Should -Contain $script:p05Installed
  }

  It 'extra same-name files: the exact reviewed entry wins over a decoy' {
    $script:p05Decoy = $null
    Mock Expand-Archive {
      $decoyDir = Join-Path $DestinationPath 'aaa'
      New-Item -ItemType Directory -Path $decoyDir -Force | Out-Null
      $script:p05Decoy = Join-Path $decoyDir $script:p05Spec.ExeName
      New-P05SizedFile -Path $script:p05Decoy -Length $script:p05Spec.ExeLength
      $dir = Join-Path $DestinationPath $script:p05Spec.ExeDir
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      New-P05SizedFile -Path (Join-Path $dir $script:p05Spec.ExeName) -Length $script:p05Spec.ExeLength
    }
    Mock Get-FileHash {
      $script:p05Hashed.Add($LiteralPath)
      if ($LiteralPath -like '*.zip') { return [pscustomobject]@{ Hash = $script:p05Spec.ZipSha256 } }
      $parentLeaf = Split-Path -Leaf (Split-Path -Parent $LiteralPath)
      if ($LiteralPath -eq $script:p05Installed -or $parentLeaf -eq $script:p05Spec.ExeDir) {
        return [pscustomobject]@{ Hash = $script:p05Spec.ExeSha256 }
      }
      [pscustomobject]@{ Hash = ('0' * 64) }
    }

    $result = Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64'

    $result | Should -Be $script:p05Installed
    $script:p05Hashed | Should -Not -Contain $script:p05Decoy
  }

  It 'missing exact entry: a same-name file elsewhere is not accepted' {
    Mock Expand-Archive {
      $decoyDir = Join-Path $DestinationPath 'aaa'
      New-Item -ItemType Directory -Path $decoyDir -Force | Out-Null
      New-P05SizedFile -Path (Join-Path $decoyDir $script:p05Spec.ExeName) -Length $script:p05Spec.ExeLength
    }

    { Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'amd64' } | Should -Throw '*zstd.exe*'
    Test-Path -LiteralPath $script:p05Installed | Should -BeFalse
  }

  It 'arm64: never fetches zstd.exe' {
    { Get-ZstdExeFromRelease -InstallDir $script:p05Install -Arch 'arm64' } | Should -Throw '*ARM64*'
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    Should -Invoke Expand-Archive -Times 0 -Exactly
  }
}
