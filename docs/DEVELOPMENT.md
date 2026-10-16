# Development and build

Everything needed to build, sign, package and validate MacNTFS from source.

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
docs/                    this guide, validation checklist and diagnostics guide
```

## Build

Prerequisites:

- macOS 27 with Xcode 27.
- Build-time only for the engine: Xcode command line tools (`curl`, `tar`,
  `make` are present on macOS). No Homebrew at build or runtime.
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
certificate already lives on the machine. The app version (`MARKETING_VERSION`)
must match the tag. Mount integration tests still run locally via
`scripts/validate-all.sh` because FSKit enablement is per-user machine state.

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
