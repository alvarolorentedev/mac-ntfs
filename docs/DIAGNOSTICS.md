# Diagnostics guide

Symptoms observed while building and using MacNTFS, with causes and actions.

## "File system extension not found" / module never loads

- **Cause:** the extension is not registered or not enabled for this user.
  macOS 26 also had a system bug where the System Settings toggle could not
  enable third-party FSKit modules; macOS 27 fixed it.
- **Check:** `pluginkit -m -p com.apple.fskit.fsmodule -vv` — the module must
  appear with `com.github.alvarolorentedev.macntfs.ntfsmodule` and the appex
  path.
- **Action:** launch the app once, then press **Enable File System Extension**
  (or toggle it in System Settings → Login Items & Extensions → File System
  Extensions). `MacNTFS --extension-status` prints the live state.

## `mount: Module ... is disabled!`

- **Cause:** the per-user FSKit enablement list does not contain the module.
- **Action:** `MacNTFS --enable-extension` (non-sandboxed app context), or the
  UI button.

## The app or extension is killed (`exit 137`, "Launchd job spawn failed")

- **Cause:** restricted FSKit entitlements with an ad-hoc or profile-less
  signature; AMFI kills the process.
- **Action:** sign through `scripts/build-signed.sh` so both provisioning
  profiles are embedded. Verify with
  `codesign -d --entitlements - <appex>`.

## `No Accounts` / `No profiles ... were found`

- **Cause:** no signing credentials available to `xcodebuild`.
- **Action:** follow "Signing" in the README (App Store Connect API key →
  `create-dev-id-profiles.sh` → `build-signed.sh`).

## Mount through Disk Arbitration fails with ENOPROTOOPT

- **Cause:** on macOS 27, Disk Arbitration's mount path refuses third-party
  FSKit modules (status 49244/ENOPROTOOPT). This is why the app mounts through
  the validated `mount -F` path.
- **Action:** none needed; the app falls back automatically. Listing, unmount
  and eject still use Disk Arbitration.

## Writes fail with `Read-only file system` on a read/write mount

- **Cause:** the volume is dirty or hibernated by Windows (Fast Startup), so
  the bridge refuses read/write and mounts read-only. Or the mount was
  requested with `-o rdonly`.
- **Check:**
  `log show --last 10m --predicate 'subsystem == "com.github.alvarolorentedev.macntfs.ntfsmodule"'`
  — notice-level messages include the task options and the downgrade reason.
- **Action:** boot Windows once and let it shut down cleanly (no Fast Startup
  hibernation), or keep using read-only.

## Extension stops reloading new builds

- **Cause:** ExtensionKit keeps an extension process alive after unmount.
- **Action:** `pkill -9 -f NTFSModule.appex`, then mount again.

## Where the evidence lives

- `MacNTFS --diagnostics <path>` (or **Copy Diagnostics**) writes: extension
  state, fskitd/fskit_agent liveness, registered FSKit modules, the NTFS mount
  table and detected volumes.
- `scripts/fskit-diagnose.sh` collects the same state plus recent fskitd logs
  into `build/diagnostics/<timestamp>/`.
- Module logs: subsystem `com.github.alvarolorentedev.macntfs.ntfsmodule`
  (notice level is persisted; `log show --info --predicate 'subsystem == ...'`).
