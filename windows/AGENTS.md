# windows/ — WSL installer & data-disk helpers

## OVERVIEW
PowerShell that imports a released rootfs as a WSL distro and wires a persistent data disk. The ONLY install entry is the raw `install.ps1` one-liner; there are no `.cmd`/`.bat` bootstrappers. No Docker needed on Windows.

## FILES
| File | Role |
|---|---|
| install.ps1 | **Sole entry**, served from `main` (`irm .../windows/install.ps1 \| iex`). Prompts release / variant / code ref (`?` lists branches), self-elevates once (freshly written copy → `RemoteSigned`, log relay), fetches the 5 siblings from the SAME `-Ref` (raw source, NOT the Release), verifies them against `windows/SHA256SUMS` before dot-sourcing, runs the preflight + installer; rootfs parts come from the Release. UTF-8 **without** BOM. |
| install-agent-devbox.ps1 | The installer: Chinese 10-step banner; `[2/10]` disk check BEFORE download; host-arch selection (`rootfs-$Variant-$Arch`), Windows 10 ARM64 rejection, pre-mkfs `uname -m` probe; tiered import; per-variant map (agents → `agent-devbox` / `D:\WSL\agent-devbox`; core → `*-core` equivalents); `New-VHD` probe → diskpart fallback → non-empty `data.vhdx`; attach + ACL + `datadisk-init.sh` (ext4 label `devbox-data`) + 5-key `/etc/agent-devbox.conf` + one direct attach (NO scheduled task; unregisters legacy `agent-devbox*-mount-datadisk` tasks) + copy the manual `.cmd` helpers; writes the fixed-GUID WT profile fragment BEFORE the import and removes WSL's stale fragment; persistent transcript in the InstallDir; never prints the password. |
| wsl-ensure.ps1 | Dot-sourced preflight + shared helpers: `Ensure-Wsl`/`Test-WslInstalled`/mirrored networking, `Normalize-ReleaseTag`, `Quote-NativeArg`, `Join-Parts`, `Get-FreeDiskSpaceBytes` (managed `DriveInfo`), `Get-ZstdUncompressedSize*` + `Assert-DiskSpace` (managed `HttpClient` Range), `Invoke-WslImportStream`, `Save-Download` (managed `HttpClient`), `Get-AgentDevboxDownloadHelperPath`, `Get-ZstdExe` (thin wrapper), sidecar read/write, `Get-FileSha256`, `ConvertFrom-Sha256Sums`, `Format-NativeOutput`, `Clear-StaleImportArtifacts`, `Assert-DistroReady`, `ConvertTo-AgentDevboxArch`, `Get-AgentDevboxHostArch`. |
| wsl-ensure-downloads.ps1 | **Lazily loaded** (definitions only): `Install-WslUi` (wsl-ui NSIS) + `Get-ZstdExeFromRelease` (pinned zstd for Tier 3). Dot-sourced ONLY in `Ensure-Wsl`'s wsl-ui branch and `Get-ZstdExe`; the happy path never loads it. **AV-sensitive — see PITFALLS.** |
| mount-datadisk.cmd | Manual attach (pure batch, copied into the InstallDir; **no PowerShell, no UAC**): no args = `<InstallDir>\data.vhdx` with `--bare`; positional `<vhdx>` overrides the path; 3 attempts, logs `datadisk-attach.log`, exits with wsl's real code. |
| unmount-datadisk.cmd | Manual detach (pure batch): `wsl --unmount "\\?\<vhdx>"`. |

## CONVENTIONS
- `$ErrorActionPreference='Stop'`. CI AST-parses every file; ps-lint also enforces AV hygiene (`wsl-ensure.ps1` has no `TypeDefinition`/`DllImport`/`HttpWebRequest`/`GetResponseStream`, does not define `Install-WslUi`, keeps `Get-AgentDevboxDownloadHelperPath`; `install.ps1` has no `irm`/`iex`/`Bypass` tokens) and the installer invariants (disk check first, interactive-only upgrade prompt before any WSL config change and before the disk check, streaming import, elevation uses `-Wait`).
- **Encoding:** `install.ps1` UTF-8 **without** BOM (a BOM survives an in-memory fetch as U+FEFF and breaks PS 5.1 parsing); every other `*.ps1` UTF-8 **with** BOM (PS 5.1 `-File` reads BOM-less as ANSI → garbled Chinese); `.cmd` ASCII + CRLF.
- **Remote text = `Invoke-WebRequest -OutFile` then `[IO.File]::ReadAllText`**, never `.Content` (PS 5.1 may return `byte[]` → zero manifest entries → bare exit code 1).
- **Staging:** scripts under `%LOCALAPPDATA%\agent-devbox` (never `%TEMP%`); `install.ps1` uses a per-run `run-<rand>` dir + temporary relay log; the installer's real transcript is `<InstallDir>\agent-devbox-install-<ts>.log`. Only the wsl-ui scratch dir uses `GetTempPath()` (the tripwire forbids it in the entry/installer only).
- **Execution policy:** `install-agent-devbox.ps1` keeps `Bypass` (MOTW risk on extracted files); `install.ps1`'s freshly written elevated child uses `RemoteSigned`.
- **Log relay:** the elevated window writes `-LogPath` (+ `$LogPath.rc`, and `$LogPath.err` for pre-installer failures); the ORIGINAL window waits, echoes the log/`失败原因`, and never relies on the exit code alone.
- **Secrets:** never print `PASEO_PASSWORD`; it lives in `/etc/agent-devbox.conf` and `/mnt/devbox-data/.paseo-password` (mode 600, survives upgrades). Transcript starts only after `$InstallDir` exists and is stopped before copying.
- **Interaction:** all UI text Chinese; pickers = Enter/`latest`/`b`(newest beta)/tag, variant Enter/`c`, ref Enter/`?`/name. The upgrade confirmation lives in `Confirm-Upgrade` (`wsl-ensure.ps1`); `install.ps1` calls it BEFORE `Ensure-Wsl`/`Set-MirroredNetworking`, and the installer calls it for direct invocation. An existing distro prompts ONCE only on an interactive console: Enter = upgrade, `n` = cancel, one re-ask then cancel. `-Yes`/`-KeepExisting`/`-UpgradeConfirmed`/redirected input skip the prompt (upgrade). Cancel exits 0 before any download/unregister/WSL-config change. Hold the elevated window ~10 s only when `-not $Yes -and [Environment]::UserInteractive`.
- **Disk math:** `required = base + 2 GiB + max(3 GiB, 10% of base)`; streaming uses `base = C + V` (compressed + uncompressed×1.05), uncompressed from the zstd frame header (local byte read or an 18-byte Range request).
- **Import tiers:** Tier 1 stream the parts into `wsl --import - ` (WSL2 bsdtar decodes zstd) → Tier 2 `Join-Parts` + import the `.tar.zst` → Tier 3 pinned `zstd.exe` → `.tar`. Happy path never downloads `zstd.exe`. **Tier 3 is x64-only**: ARM64 uses Tier 1/Tier 2 and never fetches `zstd.exe`; the skip path must NOT set `ContentSuspect` and keeps the parts/sidecars for a retry. Never pipe tier output to `Out-Null`.
- **Download identity:** a partial is reusable only when `<InstallDir>\.agent-devbox-download\<part>.meta` matches (URL + strong ETag + length + SHA256); resume sends `Range` + **`If-Match`** (GitHub/Azure ignore `If-Range`); `412`/ignored Range/`Content-Range` mismatch restarts from zero; after close the length must equal `-ExpectedBytes` and/or the server total, then `-Sha256`. On failure remove this run's parts + sidecars.
- **Script identity:** all 6 scripts are verified with `Get-FileHash` before any dot-source; mismatch → one re-download → fatal. Manifest exists but incomplete → fatal. Only a **missing** manifest is bypassable with `-AllowUnverifiedScripts`. `wsl-ensure-downloads.ps1` is the one OPTIONAL entry (missing = warning + degraded wsl-ui/Tier 3).
- **Data disk:** `New-VHD` (or diskpart, exit codes checked) → non-empty `data.vhdx` → `wsl --mount --vhd --bare` → `datadisk-init.sh devbox-data` → UUID → `wsl --unmount`. Conf keys: `DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`, `DATA_MNTNAME`=`devbox-data`, `DATA_DISTRO` (5 keys). The installer resolves the data-disk UUID by label `devbox-data` before falling back to the old conf UUID (logging the swap), so an upgrade with a copied variant disk reads the password from the right disk. There is **no scheduled task** of any kind: the installer attaches the disk once itself and unregisters legacy `agent-devbox*-mount-datadisk` tasks left by older versions. The manual repair entry is the pure-batch `mount-datadisk.cmd` (direct `wsl.exe --mount --vhd <vhdx> --bare`, 3 attempts, `datadisk-attach.log`, wsl's real exit code; no `-EncodedCommand` wrapper, which always exited 0 and hid attach failures). The installer also asserts the NEW boot-log lines (`tail -n +N` -> `boot complete`, `boot failed` fails immediately) after the restart; `wsl -d` sessions may not see the boot session's mounts, so `findmnt` alone is not evidence. The WT repair runs BEFORE that assert, so a failed assert can never leave stale profile GUIDs. `wsl-boot.sh` attaches the VHDX itself on every start (one bounded `wsl.exe --mount --vhd --bare`, skipped when already attached), then `blkid -t UUID=` (fallback label `devbox-data`) + `mount -t ext4`; it must never call `schtasks` / `wsl -d` / `--unmount`.
- **Import diagnostics:** `Format-NativeOutput` on failure; `Clear-StaleImportArtifacts` deletes a leftover `ext4.vhdx` only when `wsl -l -q` exited 0 AND the distro is absent; `Assert-DistroReady` re-checks registration and unregisters a partial one, mentioning the per-user/UAC caveat.

## PITFALLS (hard-earned — do NOT repeat)
**火绒 `HEUR:TrojanDownloader/PS.NetLoader`**
- Symptom: `wsl-ensure-downloads.ps1` deleted mid-install → elevated child dies → original window shows only `安装失败（退出码 1）`, no installer log.
- Cause: PS 5.1 `Invoke-WebRequest -OutFile` + running the fetched `.exe` is the malware downloader fingerprint; **`-UseBasicParsing`** (skip the IE engine — what every loader adds) pushes it over the line. Huorong scores statically AND via AMSI/PSET, so re-wording does not help.
- Evidence (identical bytes): `0742690` fine · `73a1a03` (token in 2 calls) quarantined · rewrite (IWR removed, token in a **comment**) quarantined again.
- Rules: no such token in that helper, comments included (tripwired). `install.ps1` may keep it for sibling downloads — do not copy it into the helper. Fix IWR hangs structurally (winget/manual), never by re-adding the flag. `.ps1` signing does NOT help. Fallback: preflight `1` (no wsl-ui); report to `bbs.huorong.cn/forum-44-1.html` / `seclab@huorong.cn` (zip password `infected`).

**PowerShell 5.1 ≠ pwsh 7**
- `.Content` may be `byte[]` → use `-OutFile` + `ReadAllText`.
- `Join-Path A B C` is PS 7 only → nest two calls.
- Native stderr under `EAP=Stop` becomes terminating → `Invoke-Native`.
- Assigning a MISSING property on a `ConvertFrom-Json` object throws → `Add-Member -Force`. WT ships a **duplicate** `agent-devbox-core` profile with no `commandline`; the old `$p.commandline = …` aborted the whole repair (`agent-devbox-install-20261021-011500.log:67`), so the stale GUID survived → wsl-ui's `wt -p` hit `WSL_E_DISTRO_NOT_FOUND` while `wsl -d` still worked.
- `Sort-Object -Property` over a `List[object]`/array of Hashtables reorders deterministically (measured 0,1,2,3 -> 2,3,0,1 on 5.1.26100.2161; pwsh 7 differs). Use `Sort-Object { [int]$_.Index }` or plan order. Gate: `powershell -File tests/powershell/ps51-order.ps1`.
- `#Requires` in `irm | iex` is fine, but pwsh 7 green proves nothing for 5.1 — only the ps-lint 5.1 run counts.

**ARM64 / WSL 架构**
- A 32-bit (WOW64) shell reports `x86`, and an **x64-emulated PowerShell on ARM64 reports `AMD64`**, while the machine is ARM64. `wsl-ensure-downloads.ps1` used to read the process env alone; it now calls `Get-AgentDevboxHostArch` (Machine-scope registry value wins, unknown throws).
- `wsl --import` does **not** validate architecture. After import and BEFORE `datadisk-init.sh` the installer runs `uname -m`; a mismatch or `Exec format error` unregisters the new distro, deletes only `ext4.vhdx`, and keeps `data.vhdx` + the parts.
- ARM64 import has no Tier 3: never fetch `zstd.exe` there (the published binary is win64-only), and never hard-code `rootfs-$Variant-amd64` (the stem is `rootfs-$Variant-$Arch`).
- Skipping Tier 3 is not evidence of corruption: never set `ContentSuspect`, keep the parts and sidecars so a re-run re-verifies SHA256 and retries.

## ANTI-PATTERNS
- NEVER build a `cmd /c copy /b "..."` string (quote/`$()` escaping) — use `Join-Parts`.
- NEVER add a second install entry (`.cmd`/`.bat`) or a second elevation path.
- NEVER move `Assert-DiskSpace` after the download, and NEVER make the happy path fetch `zstd.exe`.
- NEVER add a second upgrade-confirmation prompt or a `[Y/n]` prompt: the confirmation lives in `Confirm-Upgrade` (`wsl-ensure.ps1`), and `install.ps1` may only call it, and must call it BEFORE `Ensure-Wsl`/`Set-MirroredNetworking` so cancel cannot change `.wslconfig` or shut WSL down. The installer calls the same helper for direct invocation. The install-dir prompt is the ONE allowed direct `Read-Host`: it runs BEFORE the UAC hand-off and BEFORE `Confirm-Upgrade`, and must not prompt again when `-InstallDir` is passed. Enter is the only affirmative. NEVER make the AV prompt a `Read-Host` or sleep unconditionally.
- NEVER assign a possibly-missing JSON property directly (`$p.commandline = …`): WT profiles may lack it, and one throw aborts the repair for every profile. Use `Add-Member -Force`.
- NEVER leave a repaired WT profile without `startingDirectory`: null/absent means "inherit the launch location" (`%WINDIR%\System32` when started from the Start menu). Use the documented `\\\\wsl$\\<distro>\\root` form — `~` is NOT documented — and never override a user's value.
- NEVER edit WT `settings.json` without a timestamped backup + re-parse, and NEVER touch profiles outside `agent-devbox*` / `source=Microsoft.WSL`.
- NEVER copy an active transcript, and NEVER start it before `$InstallDir` exists.
- NEVER probe `New-VHD` with a bare `try/catch`; NEVER ignore diskpart exit codes.
- NEVER shell out for downloads (`curl.exe` in `Save-Download`) — managed `System.Net.Http` only (proxy/PAC, progress, tripwired).
- NEVER let the boot script call `schtasks.exe` / `wsl -d` / `--unmount` (boot loop); its only Windows call is the one bounded `wsl.exe --mount --vhd --bare` attach.
- NEVER delete `<InstallDir>\ext4.vhdx` while `wsl -l -q` lists the distro; NEVER format an existing data disk.
- NEVER pipe `wsl --import` / `zstd.exe` output to `Out-Null`.
- NEVER accept end-of-stream or a matching length as proof: length gate + identity sidecar + `SHA256SUMS` decide.
- NEVER put the sidecar next to the parts (`<part>.meta` matches the `rootfs-*.part-*` glob); NEVER resume with `If-Range`.
- NEVER dot-source a sibling before its `SHA256SUMS` check; NEVER bypass a partial/mismatched manifest with `-AllowUnverifiedScripts`.
- NEVER stage or execute installer scripts from `%TEMP%`.
- NEVER add `Add-Type -TypeDefinition` / `DllImport` / `HttpWebRequest` / `GetResponseStream` to `wsl-ensure.ps1`, and NEVER put a download-and-execute helper back into it (`Get-ZstdExe` stays a thin wrapper).
- NEVER add a BOM to `install.ps1`, strip it elsewhere, add non-ASCII to `.cmd`, or change `.cmd` to LF.
- The interactive shell user is root; the daemon runs as non-root `paseo`.
