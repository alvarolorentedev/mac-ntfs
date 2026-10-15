# MacNTFS

Open-source NTFS read/write for macOS. Built on Apple's FSKit framework and the
upstream ntfs-3g engine: no kernel extension, no macFUSE, no Reduced Security,
and no SIP changes.

Status: **0.1.0** — read/write mounting verified on **macOS 27.0.1** (Apple
Silicon). The module probes NTFS volumes, mounts them through FSKit, and serves
create, write, rename, unlink, truncate and read operations with content
verified across remounts. Dirty and hibernated volumes are refused read/write
and mount read-only with the reason logged.

## Architecture

```
MacNTFS.app (SwiftUI menu bar; non-sandboxed)
 ├─ DiskArbitrationMonitor   discovery and state (dynamic BSD names only)
 ├─ MountService             mount/unmount/eject (validated argv, no shell strings)
 ├─ ModuleEnabler            per-user FSKit enablement (plist + fskit_agent)
 └─ Contents/Extensions/
     └─ NTFSModule.appex     FSKit module (sandboxed, Developer ID signed)
           NTFSFileSystem    probe (NTFS boot sector) + load (safety gate)
           NTFSVolume        FSVolume.Handler → bridge (one serial queue)
           NTFSDeviceShim    FSBlockDeviceResource → C callbacks (aligned RMW)
           bridge/ntfs_bridge.c
                             owns ntfs_volume*: mount/umount, lookup, readdir,
                             create, remove, rename, read, write, truncate,
                             sync; dirty/hibernation refusal; metadata
                             protection; explicit ENOTSUP for unsupported ops
           libntfs-3g.a      pinned static library, no FUSE linked
```

Bridge contract: the bridge owns one `ntfs_volume`; all calls are serialized on
the extension's queue; every call returns a status that maps 1:1 to a POSIX
error. Device I/O uses the resource's direct path, bypassing the kernel buffer
cache; unaligned requests are wrapped in sector-aligned read-modify-write.

## Layout

```
MacNTFS/                 menu bar app sources
NTFSModule/              FSKit extension sources (Swift + ObjC shim)
bridge/                  narrow C bridge to libntfs-3g
tests/engine/            bridge test suite (no FSKit)
scripts/                 build, signing, validation and diagnostics scripts
MacNTFS.xcodeproj        both targets; manual Developer ID signing
docs/                    validation checklist and diagnostics guide
```

## Supported macOS

- **Verified:** macOS 27.0.1, Apple Silicon.
- FSKit itself requires macOS 15.4+, but this project has only been built and
  tested against the macOS 27 SDK and runtime. There is no macOS 26 or 15
  support claim.

## Build

Prerequisites:

- macOS 27 with Xcode 27.
- Build-time only for the engine: `curl` (present on macOS) and `pkg-config`
  (`brew install pkgconf`). Nothing requires Homebrew at runtime.
- Signing credentials for the Apple Developer team that owns the FSKit
  capabilities (see "Signing" below).

```sh
./scripts/build-libntfs.sh     # pinned ntfs-3g 2026.9.28, SHA-256 verified
./scripts/create-dev-id-profiles.sh   # once; needs ASC_* variables (below)
./scripts/build-signed.sh      # manual Developer ID build + entitlement check
```

## Signing (local and CI)

The FSKit entitlements (`com.apple.developer.fskit.fsmodule` for the extension,
`com.apple.developer.fskit.mount` for the app) require provisioning profiles;
ad-hoc builds with these entitlements are killed by AMFI. On macOS 27 these
capabilities are self-service: enabling them for the App IDs is enough — no
Apple approval step.

The reproducible flow uses an App Store Connect API key:

1. App Store Connect → Users and Access → Integrations → App Store Connect API
   → Team Keys → **+**, role **Admin**; download the `.p8` (one-time).
2. Note the Key ID and Issuer ID.

```sh
export ASC_KEY_PATH=/secure/AuthKey_XXXXXX.p8   # never commit this file
export ASC_KEY_ID=XXXXXX
export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
./scripts/create-dev-id-profiles.sh             # creates both profile files
./scripts/build-signed.sh                       # installs them and builds
```

`create-dev-id-profiles.sh` creates Developer ID profiles containing all valid
Developer ID certificates of the team (no device registration, so the same
profiles work on any machine). `build-signed.sh` installs them into the Xcode
profile lookup, builds, and verifies both entitlements afterwards. For an
unsigned compilation check on hosted CI runners, use `COMPILE_ONLY=1`.

## Installer (CI)

Pushing a version tag builds a Release app, notarizes and staples it, packages
`MacNTFS-<version>.dmg` (app + Applications shortcut + quick start) and attaches
it to the GitHub release. The workflow lives in
`.github/workflows/release.yml` and runs on a **self-hosted macOS runner**
(labeled `self-hosted, macOS, ARM64`) that has Xcode 27 / macOS 27. This
machine runs two runner instances: `macbook-air-ci` (opencode-cloud-link) and
`macbook-air-ci-ntfs` (this repository, `/Users/alvarolorente/ci/runner-mac-ntfs`,
installed as a LoginItem via `svc.sh`). The keychain is left untouched when the
certificate already lives on the machine. The app version (`MARKETING_VERSION`) must match
the tag. Mount integration tests still run locally via `scripts/validate-all.sh`
because FSKit enablement is per-user machine state.

Required repository secrets:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_P8` | base64 of the `AuthKey_*.p8` file |
| `DEVELOPER_ID_P12` | base64 of the exported "Developer ID Application" certificate + private key (.p12) |
| `DEVELOPER_ID_P12_PASSWORD` | the password chosen while exporting the .p12 |

Export the certificate once: Keychain Access → My Certificates → "Developer ID
Application: …" → Export…, save as .p12 with a password, then
`base64 -i cert.p12 | pbcopy` and paste into the `DEVELOPER_ID_P12` secret.
If the runner machine already has the certificate in its login keychain, the
`DEVELOPER_ID_P12` / `DEVELOPER_ID_P12_PASSWORD` secrets can be left unset.

The same installer can be produced locally:

```sh
CONFIG=Release ./scripts/build-signed.sh
./scripts/make-installer.sh          # notarizes and staples when ASC_* are set
```

CI builds and notarizes on hosted runners; mount integration tests still require
a self-hosted Mac because FSKit module enablement is per-user machine state.

## Install, use, uninstall

Install: copy `MacNTFS.app` to `/Applications`, launch it once (registers the
extension), then press **Enable File System Extension** in the menu bar window
(or use System Settings → General → Login Items & Extensions → File System
Extensions, which works on macOS 27).

Use: the menu bar lists every NTFS volume Disk Arbitration reports.

- **Mount Read-Only** — default action; writes are refused.
- **Mount Read/Write** — explicit opt-in; still refused (mounts read-only)
  when the volume is dirty or hibernated.
- **Unmount**, **Eject**, **Reveal**, **Details** — per volume.
- **Copy Diagnostics** — writes a report to
  `~/Library/Application Support/MacNTFS/` and copies it to the clipboard.

The app mounts through Disk Arbitration, so volumes appear under `/Volumes`
like any other disk (read-only unless you choose otherwise). If Disk
Arbitration refuses, it falls back to the validated `mount -F` path with a
user-owned mount point under `~/Library/MacNTFS/Volumes/`.

Uninstall:

1. Quit the app and eject/unmount all volumes.
2. Disable the extension in System Settings → Login Items & Extensions → File
   System Extensions.
3. Delete `/Applications/MacNTFS.app` and `~/Library/MacNTFS`.
4. Optional cleanup of the registration: `pluginkit -r <path-to-appex>` (while
   the app bundle still exists).

## Safety model

- The app defaults to **read-only**; read/write is a per-volume explicit action.
- **Dirty and hibernated volumes (Windows Fast Startup) are never mounted
  read/write.** The bridge refuses and mounts read-only with the reason logged.
- The module never formats, repairs, or erases anything.
- Metadata files (`mft_no < 16`) can never be unlinked.
- Unsupported operations (symbolic links, hard links, extended attributes)
  return `ENOTSUP`; nothing reports false success.
- Writes go through the resource's direct I/O path; the volume flushes on
  unmount and on FSKit's synchronize calls.

## Validation

All validation runs against disposable NTFS images; nothing in this repository
touches physical drives.

```sh
./scripts/run-engine-tests.sh   # bridge suite, no FSKit needed
./scripts/m3-mount-test.sh      # mounted read/write + safety downgrades
./scripts/m4-mount-test.sh      # app mount/unmount/eject code paths
./scripts/validate-all.sh       # everything above in order
```

See `docs/VALIDATION.md` for the full release checklist and `docs/DIAGNOSTICS.md`
for troubleshooting symptoms and causes.

## Known limitations

- **fsync delivery is not independently verified end to end.** Writes use the
  resource's direct I/O path and the volume syncs on unmount; crash-consistency
  under power loss has not been fault-injection tested.
- **Rename cannot refuse `RENAME_SWAP`**: FSKit passes no rename flags (Apple
  bug FB24419773), so a swap request is performed as a destination replace.
- **POSIX permissions are not mapped** from NTFS security descriptors yet;
  uniform mode bits are reported and ownership is ignored (`noowners`).
- **Symlinks, hard links, extended attributes/resource forks**: reported as
  unsupported (ENOTSUP). Windows junctions appear as plain entries.
- **Mount location**: via Disk Arbitration the system picks `/Volumes/<name>`;
  the fallback path uses `~/Library/MacNTFS/Volumes/<name>`.
- **One volume per resource** (FSKit unary design, matching NTFS semantics).
- Stale extension processes can linger after unmounts during development;
  `pkill -9 -f NTFSModule.appex` before rebuilding.

## Licenses

MacNTFS is GPL-3.0 (`LICENSE`). It statically links ntfs-3g (GPL-2.0-or-later);
see `THIRD_PARTY_NOTICES.md` for versions, hashes and attribution.
