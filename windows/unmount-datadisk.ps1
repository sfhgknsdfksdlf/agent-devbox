<#
.SYNOPSIS
  手动卸载 / 分离一块 WSL 数据盘（VHDX）。

.DESCRIPTION
  由 agent-devbox 安装器复制到安装目录，方便手动卸载 / 排查。
  需要管理员权限：脚本会自我提权一次（一个 UAC 提示）。

  用法（在 PowerShell 里）：
    .\unmount-datadisk.ps1
        卸载本目录的 data.vhdx
    .\unmount-datadisk.ps1 -Vhdx "D:\其它\other.vhdx"
        卸载指定的 VHDX

  注意：wsl --unmount 只能分离“已附加”的磁盘；若仍失败，可运行
  wsl --shutdown（会分离所有磁盘，代价是关闭所有发行版）。

.NOTES
  以 -File 读取，所以本文件是 UTF-8 带 BOM（PS 5.1 否则会按 ANSI 读、中文乱码）。
#>
[CmdletBinding()]
param(
  [string] $Vhdx = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Vhdx) { $Vhdx = Join-Path $PSScriptRoot 'data.vhdx' }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
  $q = "'" + ($Vhdx -replace "'", "''") + "'"
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Vhdx', $q)
  Write-Host '正在请求管理员权限（会弹出一次 UAC 授权提示）…'
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv -Wait -PassThru -ErrorAction Stop
  exit $p.ExitCode
}

Write-Host "正在卸载 $Vhdx …"
& wsl.exe --unmount ("\\?\" + $Vhdx)
$rc = $LASTEXITCODE
if ($rc -ne 0) {
  Write-Host "wsl --unmount 失败（退出码 $rc）。可尝试 wsl --shutdown（会分离所有磁盘）。" -ForegroundColor Red
  exit $rc
}
Write-Host '已卸载。' -ForegroundColor Green
exit 0
