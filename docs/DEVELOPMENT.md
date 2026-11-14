# Development and build

Everything needed to build, sign, package and validate Mountee from source.

## Architecture

```
Mountee (SwiftUI menu bar; non-sandboxed)
 ├─ DiskArbitrationMonitor   discovery and state (dynamic BSD names only)
 ├─ MountService             mount/unmount/eject (validated argv, no shell strings)
 ├─ ModuleEnabler            per-user FSKit enablement (plist + fskit_agent)
 ├─ LaunchAtLogin            login item via SMAppService (first-launch offer)
 └─ Contents/Extensions/
     └─ MounteeFSKit.appex     FSKit module (sandboxed, Developer ID signed)
           NTFSFileSystem    probe (NTFS boot sector) + load (safety gate)
           NTFSVolumeBase    shared volume core: bridge, cache, enumeration
           NTFSVolumeV3      macOS 27+ adapter (async FSVolume.Handler)
           NTFSVolumeV1      macOS 26 adapter (deprecated FSVolume.Operations)
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

The volume adapters are thin: `loadResource` picks `NTFSVolumeV3` on macOS 27+
(`FSVolume.Handler`) and `NTFSVolumeV1` on 26 (`FSVolume.Operations`, deprecated
in 27 but the only volume API on 26). The deployment target is 26.0 so the
compiler rejects any accidental use of newer APIs anywhere in the app. macOS
15.x is unsupported: the system mount paths there fail even for Apple's own
FSKit module (see `docs/VALIDATION.md`).

## Layout

```
Mountee/                 menu bar app sources
MounteeFSKit/            FSKit extension sources (Swift + ObjC shim)
bridge/                  narrow C bridge to libntfs-3g
tests/engine/            bridge test suite (no FSKit)
scripts/                 build, signing, validation and diagnostics scripts
Mountee.xcodeproj        Mountee and MounteeFSKit targets; manual Developer ID signing
docs/                    this guide, validation checklist and diagnostics guide
```

## Build

Prerequisites:

- macOS 26.6.2 or later with Xcode 27.
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

Register the App IDs `app.mountee` and `app.mountee.fskit` with the app's FSKit
mount and module capabilities before generating profiles. Existing profiles
for the old identifiers do not work with these IDs. `create-dev-id-profiles.sh`
creates Developer ID profiles containing the team's existing Developer ID
certificate; it does not create a certificate, CSR, or private key. Keep the
current `~/.secrets/mac-ntfs` key, P12, and App Store Connect key paths intact.
`build-signed.sh` installs the new profiles into Xcode, builds, and verifies
both entitlements. For unsigned CI compilation checks use `COMPILE_ONLY=1`.

The app bundle is `Mountee.app`, the app ID is `app.mountee`, and the extension
ID is `app.mountee.fskit`. Since these are new identifiers, upgrading users
must remove `/Applications/MacNTFS.app`, enable Mountee's extension, and add
Mountee to Login Items again. The app copies existing diagnostic reports to
the new support folder without deleting the originals. Existing and active
mountpoints are not moved; fallback mounts use `~/Library/Mountee/Volumes`.

## Installer (CI)

Pushing a version tag builds a Release app, notarizes and staples it, packages
`Mountee-<version>.dmg` (app + Applications shortcut + quick start) and attaches
it to the GitHub release. The workflow lives in
`.github/workflows/release.yml` and runs in a disposable Tart macOS 26.6.2 VM
with Xcode 27. The runner requires `self-hosted`, `macOS`, `ARM64`, `tart-macos`
and `tart-run-${{ github.run_id }}-${{ github.run_attempt }}` labels. A shared
host controller polls this repository and CloudLink every two minutes and runs
one VM at a time. Each VM handles one job and is destroyed afterward.

Every run imports the required certificate secrets into a temporary keychain.
The app version (`MARKETING_VERSION`) must match a release tag. Manual dispatch
uploads a seven-day `Mountee-installer` artifact without publishing a release.
Mount integration tests run separately through `scripts/validate-all.sh` because
FSKit enablement is per-user machine state.

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
Both certificate secrets are mandatory in CI; fresh VMs have no signing identity.

The same installer can be produced locally:

```sh
CONFIG=Release ./scripts/build-signed.sh
./scripts/make-installer.sh          # notarizes and staples when ASC_* are set
```

CI builds and notarizes in disposable VMs. Mount integration tests require explicit
FSKit module enablement in their validation environment.

## Validation

All validation runs against disposable NTFS images; nothing in this repository
touches physical drives.

```sh
./scripts/check-min-os.sh       # Mach-O floor guard: everything stamped <= 26.0
./scripts/test-diagnostics-migration.sh # preserves source reports and mountpoints
./scripts/test-module-enabler-migration.sh # preserves unrelated FSKit IDs
./scripts/run-engine-tests.sh   # bridge suite, no FSKit needed
./scripts/test-module-enabler-migration.sh # old module ID replacement check
./scripts/m3-mount-test.sh      # mounted read/write + safety downgrades
./scripts/m4-mount-test.sh      # app mount/unmount/eject code paths
./scripts/validate-all.sh       # everything above in order
```

Per-OS runtime validation runs in disposable VMs (see `docs/VALIDATION.md`):

```sh
./scripts/vm-validate.sh ghcr.io/cirruslabs/macos-tahoe-base:latest   # macOS 26.x
```

See `docs/VALIDATION.md` for the full release checklist and `docs/DIAGNOSTICS.md`
for troubleshooting symptoms and causes.
