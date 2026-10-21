<#
.SYNOPSIS
  手动附加（并可选择挂载）一块 WSL 数据盘（VHDX）。

.DESCRIPTION
  由 agent-devbox 安装器复制到安装目录，方便手动挂载 / 排查。
  需要管理员权限：脚本会自我提权一次（一个 UAC 提示）。

  用法（在 PowerShell 里）：
    .\mount-datadisk.ps1
        附加本目录的 data.vhdx（--bare，只附加；开机由 wsl-boot.sh 按 UUID 挂载）
    .\mount-datadisk.ps1 -Vhdx "D:\其它\other.vhdx"
        附加指定的 VHDX（--bare，仅附加）
    .\mount-datadisk.ps1 -Vhdx "D:\其它\other.vhdx" -Name mydisk
        附加并自动挂载到 /mnt/wsl/mydisk（--type ext4 --name mydisk）

.NOTES
  以 -File 读取，所以本文件是 UTF-8 带 BOM（PS 5.1 否则会按 ANSI 读、中文乱码）。
#>
[CmdletBinding()]
param(
  [string] $Vhdx = '',
  [string] $Name = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Vhdx) { $Vhdx = Join-Path $PSScriptRoot 'data.vhdx' }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 自我提权一次；参数用单引号包住并转义，路径含空格也安全。
if (-not (Test-Admin)) {
  $q = "'" + ($Vhdx -replace "'", "''") + "'"
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Vhdx', $q)
  if ($Name) { $argv += @('-Name', ("'" + ($Name -replace "'", "''") + "'")) }
  Write-Host '正在请求管理员权限（会弹出一次 UAC 授权提示）…'
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv -Wait -PassThru -ErrorAction Stop
  exit $p.ExitCode
}

if (-not (Test-Path -LiteralPath $Vhdx)) {
  Write-Host "找不到 VHDX：$Vhdx" -ForegroundColor Red
  exit 1
}

function Invoke-WslMount([string[]] $Arguments) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & wsl.exe @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
  } finally { $ErrorActionPreference = $prev }
}

$script:AttachLog = Join-Path $PSScriptRoot 'datadisk-attach.log'
function Write-AttachLog([string] $Message) {
  try { Add-Content -LiteralPath $script:AttachLog -Value ("{0} {1}" -f (Get-Date -Format 's'), $Message) -Encoding UTF8 } catch { }
}

$attempts = 3
$result = $null
for ($i = 1; $i -le $attempts; $i++) {
  if ($Name) {
    Write-Host "正在附加并挂载 $Vhdx -> /mnt/wsl/$Name …（第 $i/$attempts 次）"
    $result = Invoke-WslMount @('--mount', '--vhd', $Vhdx, '--type', 'ext4', '--name', $Name)
  } else {
    Write-Host "正在附加 $Vhdx（--bare，仅附加）…（第 $i/$attempts 次）"
    $result = Invoke-WslMount @('--mount', '--vhd', $Vhdx, '--bare')
  }
  Write-AttachLog ("attempt {0}/{1} exit={2} output={3}" -f $i, $attempts, $result.ExitCode, $result.Output)
  if ($result.ExitCode -eq 0) { break }
  if ($i -lt $attempts) { Start-Sleep -Seconds 2 }
}

if ($result.ExitCode -ne 0) {
  Write-Host "wsl --mount 失败（退出码 $($result.ExitCode)）：$($result.Output)" -ForegroundColor Red
  Write-Host "若磁盘正在使用，先 wsl --terminate <发行版> 再重试；仍失败请重启 Windows。诊断记录：$script:AttachLog" -ForegroundColor Red
  exit $result.ExitCode
}
Write-Host "完成。进入 WSL 后可用 lsblk / findmnt 检查。诊断记录：$script:AttachLog" -ForegroundColor Green
exit 0
