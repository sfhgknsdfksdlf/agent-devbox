#Requires -Version 5.1
# Expected-failure wrapper for the loopback download listener guard.
#
# It injects a deterministic port-bind failure and asserts the tagged Pester
# test goes RED (FailedCount >= 1, SkippedCount == 0) after exactly five bind
# attempts. That proves the download tests can never silently skip in CI when
# HttpListener cannot bind. The main suite (build.yml) runs the same file
# WITHOUT the injection and must stay green.
#
#   pwsh -NoProfile -File tests/powershell/download-failure.ps1
#
# This is a plain script, not a Pester test file (deliberately not *.Tests.ps1).
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$testsPath = Join-Path $here 'download.Tests.ps1'

$attemptsFile = Join-Path ([System.IO.Path]::GetTempPath()) ('adbox-dl-attempts-' + [guid]::NewGuid().ToString('N') + '.log')
$savedFail = [Environment]::GetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL')
$savedAttempts = [Environment]::GetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_ATTEMPTS_FILE')
$savedCI = [Environment]::GetEnvironmentVariable('CI')

$exitCode = 1
try {
  if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' })) {
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0
  }
  Import-Module Pester -MinimumVersion 5.0

  [Environment]::SetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL', '1')
  [Environment]::SetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_ATTEMPTS_FILE', $attemptsFile)
  # Force the CI failure mode: a bind failure must fail the test, never skip it.
  [Environment]::SetEnvironmentVariable('CI', 'true')

  # NOT -CI: -CI exits the process on failure, before the result assertions.
  $result = Invoke-Pester -Path $testsPath -Tag 'listener-failure' -PassThru -Output Detailed

  $attempts = @()
  if (Test-Path -LiteralPath $attemptsFile) {
    $attempts = @([System.IO.File]::ReadAllLines($attemptsFile) | Where-Object { $_.Trim() })
  }

  $failedNames = @()
  if ($null -ne $result) {
    try {
      foreach ($item in @($result.Failed)) {
        if ($item -is [System.Collections.DictionaryEntry]) {
          if ($item.Key) { $failedNames += [string]$item.Key }
          if ($item.Value -and $item.Value.PSObject.Properties['ExpandedName']) {
            $failedNames += [string]$item.Value.ExpandedName
          }
        } elseif ($item -and $item.PSObject.Properties['ExpandedName']) {
          $failedNames += [string]$item.ExpandedName
        }
      }
    } catch {
      $failedNames = @()
    }
  }
  $failedName = (@($failedNames | Where-Object { $_ }) -join '; ')

  $failed = if ($null -ne $result) { [int]$result.FailedCount } else { 0 }
  $skipped = if ($null -ne $result) { [int]$result.SkippedCount } else { 0 }
  $passed = if ($null -ne $result) { [int]$result.PassedCount } else { 0 }
  $total = if ($null -ne $result) { [int]$result.TotalCount } else { 0 }

  Write-Host ("Expected-failure result: Failed={0} Skipped={1} Passed={2} Total={3} Attempts={4}" -f $failed, $skipped, $passed, $total, $attempts.Count)

  # Only enforce the test name when the Pester result actually exposes it.
  $named = ($failedName -eq '') -or ($failedName -match 'listener|loopback')
  if ($failed -ge 1 -and $skipped -eq 0 -and $attempts.Count -eq 5 -and $named) {
    Write-Host 'OK: injected listener failure is red (FailedCount >= 1, SkippedCount = 0, exactly 5 attempts).'
    $exitCode = 0
  } else {
    Write-Host ("FAIL: expected FailedCount>=1, SkippedCount=0 and exactly 5 attempts naming the listener test; got Failed={0} Skipped={1} Attempts={2} FailedName=[{3}]" -f $failed, $skipped, $attempts.Count, $failedName)
    $exitCode = 1
  }
} catch {
  Write-Host ("FAIL: expected-failure wrapper error: {0}" -f $_.Exception.Message)
  $exitCode = 1
} finally {
  [Environment]::SetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_FAIL', $savedFail)
  [Environment]::SetEnvironmentVariable('AGENT_DEVBOX_TEST_HTTPLISTEN_ATTEMPTS_FILE', $savedAttempts)
  [Environment]::SetEnvironmentVariable('CI', $savedCI)
  Remove-Item -LiteralPath $attemptsFile -Force -ErrorAction SilentlyContinue
}
exit $exitCode
