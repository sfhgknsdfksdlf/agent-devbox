# Local, no-external-network coverage for the multi-connection downloader.
#
#   Invoke-Pester -Path tests/powershell/download.Tests.ps1 -CI
#
# The server is a separate PowerShell process (so it can really answer several
# requests concurrently) with a System.Net.HttpListener bound to 127.0.0.1 on a
# port the OS just granted via TcpListener port 0 (retried 5 times). In CI a
# bind failure FAILS the test; only a local run without injection skips
# explicitly. AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL=1 forces the bind failure so
# download-failure.ps1 can prove that path is red.

#Requires -Version 5.1
BeforeAll {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path (Join-Path $repoRoot 'windows') 'wsl-ensure.ps1')

  $script:ProxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy')
  $script:SavedEnv = @{}
  foreach ($n in $script:ProxyNames) {
    $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n, $null)
  }
  [Environment]::SetEnvironmentVariable('NO_PROXY', '127.0.0.1,localhost')
  [Environment]::SetEnvironmentVariable('no_proxy', '127.0.0.1,localhost')

  $script:Total = 65536
  $script:Content = New-Object byte[] $script:Total
  for ($i = 0; $i -lt $script:Total; $i++) {
    $script:Content[$i] = [byte](($i * 31 + 7) % 256)
  }
  $script:ContentSha = $null
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $script:ContentSha = ([BitConverter]::ToString($sha.ComputeHash($script:Content))).Replace('-', '').ToLowerInvariant()
  } finally { $sha.Dispose() }

  $script:ServerScript = @'
$ErrorActionPreference = 'Stop'
$prefix = $env:ADBOX_TEST_PREFIX
$configPath = $env:ADBOX_TEST_CONFIG
$logPath = $env:ADBOX_TEST_LOG
$readyPath = $env:ADBOX_TEST_READY
try {
  $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
  $content = New-Object byte[] ([int]$config.Total)
  for ($i = 0; $i -lt $content.Length; $i++) {
    $content[$i] = [byte](($i * 31 + 7) % 256)
  }
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($prefix)
  $listener.Start()
  [System.IO.File]::WriteAllText($readyPath, 'ok', (New-Object System.Text.UTF8Encoding($false)))
} catch {
  try { [System.IO.File]::WriteAllText($readyPath, ('fail:' + $_.Exception.Message), (New-Object System.Text.UTF8Encoding($false))) } catch { }
  exit 1
}

$pool = [runspacefactory]::CreateRunspacePool(1, 16)
$pool.Open()
$lock = New-Object object
$state = [hashtable]::Synchronized(@{ Seq = 0; Active = 0; MaxActive = 0 })
$running = New-Object System.Collections.ArrayList

$handler = {
  param($Context, $Config, $State, $Lock, $LogPath, $Content)
  $response = $Context.Response
  try {
    [System.Threading.Monitor]::Enter($Lock)
    try {
      $State.Seq = [int]$State.Seq + 1
      $seq = [int]$State.Seq
      $State.Active = [int]$State.Active + 1
      $active = [int]$State.Active
      if ($active -gt [int]$State.MaxActive) { $State.MaxActive = $active }
    } finally {
      [System.Threading.Monitor]::Exit($Lock)
    }

    $range = [string]$Context.Request.Headers['Range']
    $ifMatch = [string]$Context.Request.Headers['If-Match']
    $status = 200
    $from = 0L
    $to = 0L
    if ($range -match '^bytes=(\d+)-(\d+)$') {
      $from = [long]$Matches[1]
      $to = [long]$Matches[2]
      if ($to -ge $Content.Length) { $to = [long]$Content.Length - 1 }
      if ($from -le $to) { $status = 206 } else { $status = 416 }
    }
    if ($Config.Mode -eq 'ignore-range') { $status = 200 }
    if ($Config.Mode -eq '429' -and $seq -le [int]$Config.First429) { $status = 429 }
    if ($Config.Mode -eq '412' -and $ifMatch -and $seq -le [int]$Config.First412) { $status = 412 }

    $entry = [pscustomobject]@{
      Seq = $seq
      Status = $status
      Range = $range
      IfMatch = $ifMatch
      Active = $active
      Time = (Get-Date).ToString('o')
    }
    $line = ($entry | ConvertTo-Json -Compress) + "`n"
    [System.Threading.Monitor]::Enter($Lock)
    try { [System.IO.File]::AppendAllText($LogPath, $line) } finally { [System.Threading.Monitor]::Exit($Lock) }

    if ($status -eq 429 -or $status -eq 412 -or $status -eq 416) {
      $response.StatusCode = $status
      $response.ContentLength64 = 0
      return
    }

    if ($status -eq 200) {
      $bodyFrom = 0
      $bodyLen = $Content.Length
    } else {
      $bodyFrom = [int]$from
      $bodyLen = [int]($to - $from + 1)
    }
    $response.StatusCode = $status
    $response.ContentLength64 = $bodyLen
    $response.AddHeader('Accept-Ranges', 'bytes')
    if ($status -eq 206) {
      $response.AddHeader('Content-Range', ('bytes {0}-{1}/{2}' -f $from, $to, $Content.Length))
    }
    $out = $response.OutputStream
    $slow = ($Config.Mode -eq 'slow' -and -not (Test-Path -LiteralPath ([string]$Config.GoFastPath)))
    $offset = 0
    while ($offset -lt $bodyLen) {
      if ($Config.Mode -eq 'slow' -and (Test-Path -LiteralPath ([string]$Config.GoFastPath))) { $slow = $false }
      $chunk = 4096
      if ($slow) { $chunk = [int]$Config.SlowChunk }
      if ($chunk -le 0) { $chunk = 256 }
      if (($offset + $chunk) -gt $bodyLen) { $chunk = $bodyLen - $offset }
      $out.Write($Content, $bodyFrom + $offset, $chunk)
      $out.Flush()
      $offset += $chunk
      if ($slow) { Start-Sleep -Milliseconds ([int]$Config.SlowDelayMs) }
    }
    $out.Close()
  } catch {
    try { $Context.Response.Abort() } catch { }
  } finally {
    [System.Threading.Monitor]::Enter($Lock)
    try { $State.Active = [int]$State.Active - 1 } finally { [System.Threading.Monitor]::Exit($Lock) }
    try { $Context.Response.Close() } catch { }
  }
}

try {
  while ($true) {
    $ctx = $listener.GetContext()
    if ($ctx.Request.Url.AbsolutePath -eq '/__stop') {
      $ctx.Response.StatusCode = 200
      $ctx.Response.ContentLength64 = 0
      $ctx.Response.Close()
      break
    }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($handler).AddArgument($ctx).AddArgument($config).AddArgument($state).AddArgument($lock).AddArgument($logPath).AddArgument($content)
    $ar = $ps.BeginInvoke()
    [void]$running.Add([pscustomobject]@{ Power = $ps; Async = $ar })
    for ($i = $running.Count - 1; $i -ge 0; $i--) {
      if ($running[$i].Async.IsCompleted) {
        try { [void]$running[$i].Power.EndInvoke($running[$i].Async) } catch { }
        try { $running[$i].Power.Dispose() } catch { }
        $running.RemoveAt($i)
      }
    }
  }
} finally {
  try { $listener.Stop() } catch { }
  try { $listener.Close() } catch { }
  try { $pool.Close() } catch { }
  try { $pool.Dispose() } catch { }
}
'@
}

AfterAll {
  foreach ($n in $script:ProxyNames) {
    [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n])
  }
}

BeforeAll {
  # Test-only port acquisition: bind a TcpListener on an ephemeral loopback
  # port instead of guessing a port in a fixed range. Port 0 lets the OS pick a
  # free port; a real bind failure is retried 5 times, then thrown so the caller
  # can turn it into a test failure (CI) or a skip (local, non-injected).
  # AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL=1 / -ForceBindFailure simulate the failure
  # deterministically without binding anything; every attempt is appended to
  # AGENT_DEVBOX_TEST_HTTPLISTEN_ATTEMPTS_FILE when that env var is set.
  function Get-FreeLoopbackPort {
    param([switch] $ForceBindFailure)
    $inject = $ForceBindFailure -or ($env:AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL -eq '1')
    $attemptsFile = $env:AGENT_DEVBOX_TEST_HTTPLISTEN_ATTEMPTS_FILE
    $lastError = ''
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      if (-not [string]::IsNullOrEmpty($attemptsFile)) {
        try { [System.IO.File]::AppendAllText($attemptsFile, ("attempt {0}`n" -f $attempt)) } catch { }
      }
      if ($inject) {
        $lastError = 'injected HttpListener bind failure'
        continue
      }
      $listener = $null
      try {
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
      } catch {
        $lastError = "$($_.Exception.Message)"
      } finally {
        if ($null -ne $listener) {
          try { $listener.Stop() } catch { }
        }
      }
    }
    $ex = New-Object System.Exception ("Get-FreeLoopbackPort failed after 5 attempts to bind a loopback port: $lastError")
    $ex.Data['AdboxPortFailure'] = $true
    throw $ex
  }

  # Start the child listener on a real 127.0.0.1 port. The whole start is
  # retried up to 5 times when the child reports a bind failure or never
  # becomes ready; each failed attempt is torn down (process + temp dir) before
  # the next one. A port-acquisition failure is not retried here because
  # Get-FreeLoopbackPort already exhausted its own 5 attempts.
  function Start-DownloadServer {
    param([hashtable] $Config, [switch] $ForceBindFailure)
  $inject = $ForceBindFailure -or ($env:AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL -eq '1')
  $maxAttempts = 5
  $lastError = ''
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $base = $null
    $proc = $null
    $keep = $false
    $prefix = $null
    try {
      try {
        $port = Get-FreeLoopbackPort -ForceBindFailure:$ForceBindFailure
      } catch {
        $isPortFailure = ($_.Exception.Data -and $_.Exception.Data['AdboxPortFailure'])
        if ($isPortFailure -and $inject) { throw }
        if ($isPortFailure) {
          $lastError = "$($_.Exception.Message)"
          return [pscustomobject]@{
            Process = $null
            Base = $null
            Url = $null
            Log = $null
            Ready = $false
            Error = $lastError
            Attempts = $attempt
          }
        }
        throw
      }

      $base = Join-Path ([System.IO.Path]::GetTempPath()) ('adbox-dl-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $base -Force | Out-Null
      $serverPath = Join-Path $base 'server.ps1'
      [System.IO.File]::WriteAllText($serverPath, $script:ServerScript, (New-Object System.Text.UTF8Encoding($false)))
      $configPath = Join-Path $base 'config.json'
      $logPath = Join-Path $base 'requests.log'
      $readyPath = Join-Path $base 'ready.txt'
      $config | ConvertTo-Json -Depth 6 | ForEach-Object { [System.IO.File]::WriteAllText($configPath, $_, (New-Object System.Text.UTF8Encoding($false))) }
      $prefix = "http://127.0.0.1:$port/"
      $saved = @{}
      foreach ($n in @('ADBOX_TEST_PREFIX', 'ADBOX_TEST_CONFIG', 'ADBOX_TEST_LOG', 'ADBOX_TEST_READY')) {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n)
      }
      try {
        [Environment]::SetEnvironmentVariable('ADBOX_TEST_PREFIX', $prefix)
        [Environment]::SetEnvironmentVariable('ADBOX_TEST_CONFIG', $configPath)
        [Environment]::SetEnvironmentVariable('ADBOX_TEST_LOG', $logPath)
        [Environment]::SetEnvironmentVariable('ADBOX_TEST_READY', $readyPath)
        $exe = (Get-Process -Id $PID).Path
        $startArgs = @{
          FilePath = $exe
          ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'server.ps1')
          WorkingDirectory = $base
          PassThru = $true
        }
        if ($env:OS -eq 'Windows_NT') { $startArgs['WindowStyle'] = 'Hidden' }
        $proc = Start-Process @startArgs
      } finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
      }
      $deadline = [DateTime]::UtcNow.AddSeconds(15)
      while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
        if ($proc -and $proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
      }
      $ready = ''
      if (Test-Path -LiteralPath $readyPath) { $ready = [System.IO.File]::ReadAllText($readyPath) }
      if ($ready -eq 'ok') {
        $keep = $true
        return [pscustomobject]@{
          Process = $proc
          Base = $base
          Url = ($prefix + 'asset')
          Log = $logPath
          Ready = $true
          Error = $ready
          Attempts = $attempt
        }
      }
      if ($ready) { $lastError = $ready } else { $lastError = 'child server did not become ready' }
    } finally {
      if (-not $keep) {
        if ($proc -and -not $proc.HasExited) {
          try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
          try { [void]$proc.WaitForExit(5000) } catch { }
        }
        if ($base -and (Test-Path -LiteralPath $base)) {
          Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
  return [pscustomobject]@{
    Process = $null
    Base = $null
    Url = $null
    Log = $null
    Ready = $false
    Error = $lastError
    Attempts = $maxAttempts
  }
}

function Stop-DownloadServer {
  param($Server)
  if ($null -eq $Server) { return }
  if ($Server.Process -and -not $Server.Process.HasExited) {
    try { Stop-Process -Id $Server.Process.Id -Force -ErrorAction Stop } catch { }
    try { [void]$Server.Process.WaitForExit(5000) } catch { }
  }
  if ($Server.Base -and (Test-Path -LiteralPath $Server.Base)) {
    Remove-Item -LiteralPath $Server.Base -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Shared entry point for every test: a ready server, or a hard failure when a
# bind problem must not be hidden. In CI (and under the injected failure) a
# bind failure throws so Pester marks the test failed; only a local run without
# injection is allowed to skip explicitly.
function Start-TestDownloadServer {
  param([hashtable] $Config, [switch] $ForceBindFailure)
  $injected = $ForceBindFailure -or ($env:AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL -eq '1')
  $server = Start-DownloadServer -Config $Config -ForceBindFailure:$ForceBindFailure
  if ($server.Ready) { return $server }
  $why = [string]$server.Error
  Stop-DownloadServer -Server $server
  if (($env:CI -eq 'true') -or $injected) {
    throw "HttpListener could not bind: $why"
  }
  Set-ItResult -Skipped -Because "HttpListener could not bind: $why"
  return $null
}

function Get-TestLog {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Test-FileEqualsBytes {
  param([string] $Path, [byte[]] $Bytes)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $actual = [System.IO.File]::ReadAllBytes($Path)
  if ($actual.Length -ne $Bytes.Length) { return $false }
  for ($i = 0; $i -lt $actual.Length; $i++) {
    if ($actual[$i] -ne $Bytes[$i]) { return $false }
  }
  return $true
}
}

Describe 'Save-Download segmented mode' {
  It 'keeps -Connections 1 on the unchanged single-stream path' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 1 -SegmentMinBytes 1 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      $entries = Get-TestLog -Path $server.Log
      $entries.Count | Should -Be 1
      [string]$entries[0].Range | Should -Be ''
      [int]$entries[0].Status | Should -Be 200
      $meta = Read-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest)
      $meta.version | Should -Be 1
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'discards an active segment layout when -Connections 1 is requested' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      $plan = @(Get-SegmentPlan -TotalBytes $script:Total -Connections 4)
      $seg0 = Get-DownloadSegmentPath -Dest $dest -Index 0
      New-Item -ItemType Directory -Path (Split-Path -Parent $seg0) -Force | Out-Null
      [System.IO.File]::WriteAllBytes($seg0, [byte[]](1, 2, 3))
      Write-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest) -Url $server.Url -ETag '"v1"' `
        -Length $script:Total -Sha256 $script:ContentSha -Complete $false -Connections 4 `
        -SegmentSize ([long]$plan[0].SegmentSize) -SegmentCount $plan.Count -SegmentState 'active'
      $warnings = @()
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 1 -SegmentMinBytes 1 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 `
        -WarningVariable warnings 6>$null
      (@($warnings | ForEach-Object { "$_" }) -join "`n") | Should -Match '-Connections 1'
      Test-Path -LiteralPath (Get-DownloadSegmentDir -Dest $dest) | Should -BeFalse
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      (Read-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest)).version | Should -Be 1
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'downloads every segment with 206 and produces the exact bytes and SHA256' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 4 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      (Get-FileSha256 -Path $dest) | Should -Be $script:ContentSha
      $entries = Get-TestLog -Path $server.Log
      @($entries | Where-Object { [int]$_.Status -eq 206 }).Count | Should -Be 4
      @($entries | Where-Object { [string]$_.Range -eq '' }).Count | Should -Be 0
      Test-Path -LiteralPath (Get-DownloadSegmentDir -Dest $dest) | Should -BeFalse
      $meta = Read-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest)
      $meta.segmentState | Should -Be 'complete'
      $meta.connections | Should -Be 4
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'falls back to one stream from zero when the server returns 200' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'ignore-range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      $warnings = @()
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 4 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 `
        -WarningVariable warnings 6>$null
      $warningText = (@($warnings | ForEach-Object { "$_" }) -join "`n")
      $warningText -match '\u670d\u52a1\u5668\u4e0d\u652f\u6301\u5206\u6bb5\u4e0b\u8f7d' | Should -BeTrue
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      $entries = Get-TestLog -Path $server.Log
      @($entries | Where-Object { [string]$_.Range -ne '' }).Count | Should -BeGreaterThan 0
      @($entries | Where-Object { [string]$_.Range -eq '' }).Count | Should -BeGreaterThan 0
      Test-Path -LiteralPath (Get-DownloadSegmentDir -Dest $dest) | Should -BeFalse
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'reduces concurrency to one after 429 and still completes' {
    $server = Start-TestDownloadServer -Config @{ Mode = '429'; Total = $script:Total; First429 = 4 }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 4 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 5 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      $entries = Get-TestLog -Path $server.Log
      @($entries | Where-Object { [int]$_.Seq -le 4 -and [int]$_.Status -eq 429 }).Count | Should -Be 4
      $after = @($entries | Where-Object { [int]$_.Seq -gt 4 })
      $after.Count | Should -BeGreaterThan 0
      ($after | Measure-Object -Property Active -Maximum).Maximum | Should -Be 1
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'resumes pre-seeded segment files and asks the server for the exact Range starts' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      $plan = @(Get-SegmentPlan -TotalBytes $script:Total -Connections 4)
      $partial = 1000
      $seg0 = Get-DownloadSegmentPath -Dest $dest -Index 0
      New-Item -ItemType Directory -Path (Split-Path -Parent $seg0) -Force | Out-Null
      $prefixBytes = New-Object byte[] $partial
      [Array]::Copy($script:Content, 0, $prefixBytes, 0, $partial)
      [System.IO.File]::WriteAllBytes($seg0, $prefixBytes)
      Write-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest) -Url $server.Url -ETag '"v1"' `
        -Length $script:Total -Sha256 $script:ContentSha -Complete $false -Connections 4 `
        -SegmentSize ([long]$plan[0].SegmentSize) -SegmentCount $plan.Count -SegmentState 'active'
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 4 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      $entries = Get-TestLog -Path $server.Log
      @($entries | Where-Object { [string]$_.Range -eq ('bytes={0}-{1}' -f $partial, (($plan[0].End))) }).Count | Should -BeGreaterThan 0
    } finally {
      Stop-DownloadServer -Server $server
    }
  }

  It 'aborts a slow window with a resume-safe segment state, then resumes to completion' {
    $goFast = Join-Path ([System.IO.Path]::GetTempPath()) ('adbox-go-' + [guid]::NewGuid().ToString('N'))
    $server = Start-TestDownloadServer -Config @{
      Mode = 'slow'; Total = $script:Total
      SlowChunk = 256; SlowDelayMs = 200
      GoFastPath = $goFast
    }
    if ($null -eq $server) {
      Remove-Item -LiteralPath $goFast -Force -ErrorAction SilentlyContinue
      return
    }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      $err = ''
      try {
        Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
          -Connections 2 -SegmentMinBytes 1024 -SlowWindowSeconds 1 -SlowSpeedBytesPerSec 262144 `
          -StallSeconds 10 -Retries 2 6>$null
      } catch {
        $err = "$($_.Exception.Message)"
      }
      $err -match '\u4f20\u8f93\u8fc7\u6162' | Should -BeTrue
      $meta = Read-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest)
      $meta | Should -Not -BeNullOrEmpty
      $meta.segmentState | Should -Be 'active'
      [System.IO.File]::WriteAllText($goFast, 'fast')
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 2 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 5 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
    } finally {
      Stop-DownloadServer -Server $server
      Remove-Item -LiteralPath $goFast -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restarts from zero after 412 instead of appending to stale segments' {
    $server = Start-TestDownloadServer -Config @{ Mode = '412'; Total = $script:Total; First412 = 1 }
    if ($null -eq $server) { return }
    try {
      $dest = Join-Path $server.Base 'rootfs-core-amd64.tar.zst.part-00'
      $plan = @(Get-SegmentPlan -TotalBytes $script:Total -Connections 4)
      $partial = 1000
      $seg0 = Get-DownloadSegmentPath -Dest $dest -Index 0
      New-Item -ItemType Directory -Path (Split-Path -Parent $seg0) -Force | Out-Null
      $prefixBytes = New-Object byte[] $partial
      [Array]::Copy($script:Content, 0, $prefixBytes, 0, $partial)
      [System.IO.File]::WriteAllBytes($seg0, $prefixBytes)
      Write-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest) -Url $server.Url -ETag '"old-etag"' `
        -Length $script:Total -Sha256 $script:ContentSha -Complete $false -Connections 4 `
        -SegmentSize ([long]$plan[0].SegmentSize) -SegmentCount $plan.Count -SegmentState 'active'
      Save-Download -Url $server.Url -Dest $dest -ExpectedBytes $script:Total -Sha256 $script:ContentSha `
        -Connections 4 -SegmentMinBytes 1024 -SlowWindowSeconds 0 -StallSeconds 10 -Retries 3 6>$null
      (Test-FileEqualsBytes -Path $dest -Bytes $script:Content) | Should -BeTrue
      $entries = Get-TestLog -Path $server.Log
      @($entries | Where-Object { [int]$_.Status -eq 412 }).Count | Should -BeGreaterThan 0
      $first412 = @($entries | Where-Object { [int]$_.Status -eq 412 })[0]
      # In-flight requests from the aborted batch may still be logged after the
      # 412; only requests WITHOUT If-Match are the post-412 restart.
      $after = @($entries | Where-Object {
          [int]$_.Seq -gt [int]$first412.Seq -and [string]$_.IfMatch -eq ''
        })
      @($after | Where-Object { [int]$_.Status -eq 206 }).Count | Should -BeGreaterThan 0
      @($after | Where-Object {
          [string]$_.Range -eq ('bytes={0}-{1}' -f $partial, $plan[0].End)
        }).Count | Should -Be 0
      $meta = Read-DownloadSidecar -Path (Get-DownloadMetaPath -Dest $dest)
      $meta.segmentState | Should -Be 'complete'
    } finally {
      Stop-DownloadServer -Server $server
    }
  }
}

Describe 'download listener guard' {
  It 'starts a real loopback HTTP listener and never silently skips in CI' -Tag 'listener-failure' {
    $server = Start-TestDownloadServer -Config @{ Mode = 'range'; Total = $script:Total }
    if ($null -eq $server) { return }
    try {
      $server.Ready | Should -BeTrue
      ([int]$server.Attempts) | Should -BeGreaterThan 0
      ([string]$server.Url) | Should -Match '^http://127\.0\.0\.1:\d+/asset$'
    } finally {
      Stop-DownloadServer -Server $server
    }
  }
}
