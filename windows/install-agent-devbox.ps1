<#
.SYNOPSIS
  agent-devbox one-click installer for Windows (WSL2).

.DESCRIPTION
  - Imports the published OCI image as a WSL2 distro named `agent-devbox`.
  - Creates + attaches a 32GB dynamic VHDX data disk and initializes it.
  - Wires the data disk into the distro so /home, /root and /workspace persist
    across image upgrades.
  - Optionally registers a logon Scheduled Task that re-attaches the disk.

  Idempotent: safe to re-run. It creates only what is missing (distro and/or
  data disk) and refreshes the boot config; an existing data disk is never
  reformatted.

  The interactive shell user is root; the paseo daemon runs as non-root `paseo`.

.NOTES
  Requires Windows 11 (WSL2 with `wsl --mount --vhd`). Elevates once (UAC).
#>
[CmdletBinding()]
param(
  [ValidateSet('agents', 'core')] [string] $Variant = 'agents',
  [string] $InstallDir = '',
  [string] $ReleaseTag = '',
  [switch] $Yes
)

$ErrorActionPreference = 'Stop'

$Distro   = 'agent-devbox'
$DiskName = 'agent-devbox-data'
$VhdxName = 'data.vhdx'
$Repo     = 'sfhgknsdfksdlf/agent-devbox'
$ConfPath = '/etc/agent-devbox.conf'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Elevate once (UAC) ----------------------------------------------------
if (-not (Test-Admin)) {
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Variant', $Variant)
  if ($InstallDir) { $argv += @('-InstallDir', "`"$InstallDir`"") }
  if ($ReleaseTag) { $argv += @('-ReleaseTag', $ReleaseTag) }
  if ($Yes)        { $argv += '-Yes' }
  Write-Host 'Requesting administrator privileges (one UAC prompt)...'
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv | Out-Null
  exit 0
}

# --- Preflight: make sure WSL exists and (recommended) uses mirrored networking ---
$__ensure = Join-Path $PSScriptRoot 'wsl-ensure.ps1'
if (Test-Path -LiteralPath $__ensure) {
    . $__ensure
    $__r = Ensure-Wsl -Yes:$Yes
  if ($__r -eq 'reboot-required') { Write-Host 'WSL was installed; please reboot Windows and run this installer again.'; exit 0 }
  if (-not (Test-WslInstalled)) { throw 'WSL is still unavailable; setup did not complete.' }
  Set-MirroredNetworking -Yes:$Yes
} else {
  Write-Warning "wsl-ensure.ps1 not found; skipping the WSL/network preflight (extract ALL the scripts from the Release zip)."
}

function Get-WslDistros { (wsl.exe -l -q 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
function Test-DistroExists { (Get-WslDistros) -contains $Distro }

function Join-Parts {
  param([string[]] $Parts, [string] $Dest)
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
  $out = [System.IO.File]::Create($Dest)
  try {
    foreach ($p in $Parts) {
      $in = [System.IO.File]::OpenRead($p)
      try { $in.CopyTo($out) } finally { $in.Dispose() }
    }
  } finally { $out.Dispose() }
}

# --- Decide the install directory -----------------------------------------
if (-not $InstallDir) {
  $default = 'D:\WSL\agent-devbox'
  if ($Yes) {
    $InstallDir = $default
  } else {
    $answer = Read-Host "Install directory [$default] (press Enter for default)"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer }
  }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$VhdxPath = Join-Path $InstallDir $VhdxName
Write-Host "Distro=$Distro  Variant=$Variant  InstallDir=$InstallDir"

# --- Release channel: stable (`latest`), the moving `beta` test build, or a
#     specific release tag (e.g. build-20261018.0731). Asked on every run so
#     you can switch builds; only used when (re)importing. -----------------
if (-not $ReleaseTag) {
  if ($Yes) {
    $ReleaseTag = 'latest'
  } else {
    $sel = Read-Host 'Release [Enter = stable (latest), b = beta test build, or a tag e.g. build-20261018.0731]'
    if ([string]::IsNullOrWhiteSpace($sel)) { $ReleaseTag = 'latest' }
    elseif ($sel -match '^(b|beta)$')       { $ReleaseTag = 'beta' }
    else                                    { $ReleaseTag = $sel.Trim() }
  }
}
if ($ReleaseTag -match '^\d{8}\.\d{4}$') { $ReleaseTag = "build-$ReleaseTag" }

# --- 0) Re-import over an existing distro? (the data disk is separate, so
#     /home, /root and /workspace survive) ----------------------------------
$import = -not (Test-DistroExists)
if (-not $import) {
  if ($Yes) {
    $import = $false
  } else {
    $ans = Read-Host "Distro '$Distro' already exists. Re-import it with the '$ReleaseTag' build? (the data disk is not touched) [y/N]"
    $import = ($ans -match '^(y|yes)$')
  }
  if ($import) {
    Write-Host "Unregistering '$Distro' (data disk kept)..."
    wsl.exe --unregister $Distro | Out-Null
  }
}

# --- 1) Import the distro if it does not exist -----------------------------
if ($import) {
  $stz = "rootfs-$Variant-amd64.tar.zst"
  $stzPath = Join-Path $InstallDir $stz
  $tarPath = Join-Path $InstallDir "rootfs-$Variant-amd64.tar"
  $localParts = Get-ChildItem -Path $PSScriptRoot -Filter "$stz.part-*" -ErrorAction SilentlyContinue

  $rel = $null
  if ($localParts) {
    Write-Host 'Reassembling local rootfs parts...'
    Join-Parts -Parts ($localParts | Sort-Object Name | ForEach-Object { $_.FullName }) -Dest $stzPath
  } else {
    $relApi = if ($ReleaseTag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" }
    Write-Host "Downloading rootfs from GitHub Release ($ReleaseTag)..."
    $rel = Invoke-RestMethod $relApi -Headers @{ 'User-Agent' = 'agent-devbox-installer' }
    $parts = $rel.assets | Where-Object { $_.name -like "$stz.part-*" } | Sort-Object name
    if (-not $parts) { throw "No '$stz.part-*' assets found in the '$ReleaseTag' release." }
    $local = @()
    foreach ($p in $parts) {
      $dest = Join-Path $InstallDir $p.name
      Write-Host "  $($p.name)"
      Invoke-WebRequest -Uri $p.browser_download_url -OutFile $dest
      $local += $dest
    }
    Join-Parts -Parts $local -Dest $stzPath
  }

  # Windows 10 has no built-in zstd, so fetch a PINNED zstd.exe from the official project.
  $zstdExe = Join-Path $InstallDir 'zstd.exe'
  if (-not (Test-Path $zstdExe)) {
    $zstdVer = '1.5.7'
    $zstdUrl = "https://github.com/facebook/zstd/releases/download/v$zstdVer/zstd-v$zstdVer-win64.zip"
    $tmpZip = Join-Path $InstallDir 'zstd.zip'
    $tmpDir = Join-Path $InstallDir 'zstd-tmp'
    Write-Host "Fetching zstd $zstdVer (needed to decompress)..."
    Invoke-WebRequest -Uri $zstdUrl -OutFile $tmpZip
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $found = Get-ChildItem -Path $tmpDir -Recurse -Filter 'zstd.exe' | Select-Object -First 1
    if (-not $found) { throw 'zstd.exe not found in the downloaded archive.' }
    Copy-Item $found.FullName $zstdExe -Force
    Remove-Item -Path $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host 'Decompressing rootfs (zstd)...'
  & $zstdExe -d -f $stzPath
  if ($LASTEXITCODE -ne 0) { throw "zstd decompress failed ($LASTEXITCODE)" }

  Write-Host "Importing distro '$Distro'..."
  wsl.exe --import $Distro $InstallDir $tarPath
  if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE)" }
} else {
  Write-Host "Distro '$Distro' already exists; skipping import."
}

# --- 2) Create the data disk if missing ------------------------------------
$createdDisk = $false
if (-not (Test-Path $VhdxPath)) {
  Write-Host "Creating data disk $VhdxPath (32GB dynamic)..."
  try {
    New-VHD -Path $VhdxPath -SizeBytes 32GB -Dynamic | Out-Null
  } catch {
    Write-Host 'New-VHD unavailable (Windows Home?); using diskpart...'
    $dp = @"
create vdisk file="$VhdxPath" maximum=32768 type=expandable
select vdisk file="$VhdxPath"
attach vdisk
"@
    $dp | diskpart | Out-Null
    # Detach; we attach via wsl below.
    $detach = @"
select vdisk file="$VhdxPath"
detach vdisk
"@
    $detach | diskpart | Out-Null
  }
  $createdDisk = $true
} else {
  Write-Host "Data disk already exists; leaving it untouched."
}

# --- 3) Attach (bare), initialize if brand new, capture UUID, detach --------
Write-Host 'Attaching data disk (bare) and initializing if new...'
wsl.exe --mount --vhd $VhdxPath --bare | Out-Null
Start-Sleep -Seconds 2

$initOut = wsl.exe -d $Distro -u root -e bash -lc '/usr/local/bin/datadisk-init.sh' 2>&1
Write-Host $initOut
$uuid = ''
foreach ($line in ($initOut -split "`n")) {
  if ($line -match 'UUID=([0-9a-fA-F-]+)') { $uuid = $Matches[1] }
}
# Fall back: read the UUID from the label.
if (-not $uuid) {
  $uuid = (wsl.exe -d $Distro -u root -e bash -lc "blkid -t LABEL=$DiskName -s UUID -o value" 2>$null | ForEach-Object { $_.Trim() })
}

Write-Host 'Detaching data disk (boot will re-attach it)...'
wsl.exe --unmount "\\?\$VhdxPath" 2>$null | Out-Null

# --- 4) paseo password (required by the daemon); stored in the boot config ---
if (-not $Yes) {
  $pw = Read-Host "paseo password (press Enter to generate a random one)"
} else {
  $pw = ''
}
if ([string]::IsNullOrWhiteSpace($pw)) {
  $pw = -join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
  Write-Host "Generated paseo password: $pw"
}

# --- 5) Write boot config into the distro ----------------------------------
$conf = "DATA_VHDX='$VhdxPath'`nDATA_UUID='$uuid'`nPASEO_PASSWORD='$pw'`n"
$conf | wsl.exe -d $Distro -u root -e bash -lc "umask 077; cat > $ConfPath; chmod 600 $ConfPath" | Out-Null
Write-Host "Wrote $ConfPath (UUID=$uuid)"

# --- 6) Optional: logon Scheduled Task to re-attach the disk ---------------
$taskName = 'agent-devbox-mount-datadisk'
if (-not $Yes) {
  $ans = Read-Host "Register a logon Scheduled Task to auto-attach the data disk? [y/N] (Enter = no)"
} else {
  $ans = 'N'
}
if ($ans -match '^(y|yes)$') {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  $action  = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "--mount --vhd `"$VhdxPath`" --name $DiskName"
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Description 'Attach the agent-devbox data disk on logon' | Out-Null
  Write-Host "Registered Scheduled Task '$taskName'."
} else {
  Write-Host 'Skipped Scheduled Task (wsl-boot.sh will still try to attach on boot).'
}

# --- 7) Restart the distro so boot wires everything up ---------------------
Write-Host 'Restarting distro...'
wsl.exe --terminate $Distro | Out-Null
wsl.exe -d $Distro -u root -e bash -lc 'echo agent-devbox is ready; mount | grep -E "agent-devbox-data| /home | /root | /workspace " || true'
Write-Host ''
Write-Host 'Done. Enter the environment with:  wsl -d agent-devbox'
Write-Host 'Set a paseo password if you have not: edit /etc/agent-devbox.conf or export PASEO_PASSWORD before boot.'
