# MacNTFS

Open-source NTFS read/write for macOS using Apple's FSKit framework and the
upstream ntfs-3g engine. No kernel extension, no macFUSE, no Reduced Security.

Status: **M3 (read/write mounted)** — the FSKit module mounts NTFS volumes on
macOS 27.0.1 and serves real read/write traffic: create, write, rename, unlink,
truncate, with content verified by SHA-256 across remounts. Dirty and
hibernated volumes are refused read/write and mount read-only with a logged
reason. The MacNTFS app defaults to read-only; see "Mount safety" below.

## Layout

```
MacNTFS/                 host app (SwiftUI; non-sandboxed for FSKit enablement)
NTFSModule/              FSKit file system extension (Swift; sandboxed)
MacNTFS.xcodeproj        both targets, team D8UFJKPSQP, automatic signing
scripts/build-libntfs.sh builds pinned ntfs-3g into build/ (static lib + mkntfs)
scripts/make-test-image.sh  creates a disposable NTFS image
scripts/m1-mount-test.sh    M1 gate: enable extension, attach image, mount, verify
scripts/fskit-diagnose.sh   collects signing/registration/mount diagnostics
```

## Build

Prerequisites:

- macOS 27 with Xcode 27
- Signing credentials for the Apple Developer team that owns the FSKit
  capabilities (see "Reproducible signing" below). The
  `com.apple.developer.fskit.fsmodule` (extension) and
  `com.apple.developer.fskit.mount` (app) entitlements require provisioning
  profiles; ad-hoc builds with these entitlements are killed by AMFI.
- Build-time only, for `scripts/build-libntfs.sh`: `curl` (present on macOS) and
  `pkg-config` (`brew install pkgconf`). Nothing requires Homebrew at runtime.

```sh
./scripts/build-libntfs.sh                # pinned ntfs-3g 2026.9.28 (SHA-256 verified)
./scripts/build-signed.sh                 # signed build (see below)
```

## Reproducible signing (local and CI)

The supported non-interactive flow is an **App Store Connect API key**. Create
it once:

1. App Store Connect → Users and Access → Integrations → **App Store Connect API**
   → **Team Keys** → **+**; role **Admin** (needed to create certificates and
   profiles); download the `.p8` (single download).
2. Note the **Key ID** and the **Issuer ID** shown on the keys page.

Then every build — workstation or CI — is:

```sh
export ASC_KEY_PATH=/secure/AuthKey_ABC123XYZ.p8    # never commit this file
export ASC_KEY_ID=ABC123XYZ
export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
./scripts/build-signed.sh
```

With `-allowProvisioningUpdates`, xcodebuild uses the key to create the Apple
Development certificate and the profiles authorizing both capability
entitlements, then verifies the resulting appex/app entitlements.

Other modes:

- `MANUAL_SIGNING=1` — profiles already installed on the machine (offline CI).
- `COMPILE_ONLY=1` — unsigned compilation check for hosted runners; produces an
  app that cannot load as an FSKit module.

CI notes: compilation and the engine tests run on any runner. Actual
mount-integration tests require a self-hosted Mac: FSKit module enablement is
per-user machine state (`fskit_agent`), which Apple does not expose to hosted CI.

## M1 gate

```sh
./scripts/m1-mount-test.sh
```

The script registers the extension, enables it for the current user
(`MacNTFS --enable-extension`; on macOS 27 the System Settings toggle also
works), attaches a disposable NTFS image, mounts it read-only, verifies, and
unmounts. It refuses to touch physical disks: the device comes from attaching a
raw image file and its BSD name is validated before use.

## Engine tests

```sh
./scripts/run-engine-tests.sh
```

Builds the bridge against the pinned static library and runs the engine suite on
fresh disposable images: read/write cycles (create, write, sync, remount,
verify, truncate, unlink, readdir, lookup, rename including overwrite, statfs),
a dirty volume, and a hibernated volume. No FSKit and no physical devices
involved.

## M3 gate (mounted read/write validation)

```sh
./scripts/m3-mount-test.sh
```

Mounts disposable images through the real FSKit module and verifies: read/write
cycle with SHA-256 content check across remounts; explicit read-only mount
(`-o rdonly`) refuses writes; a dirty volume and a hibernated volume both fall
back to read-only with writes refused, even though read/write was requested.

## Mount safety

- **MacNTFS app:** mounts read-only unless the user explicitly chooses
  read/write for a specific volume.
- **Dirty or hibernated volumes (Windows Fast Startup):** read/write is always
  refused; the volume mounts read-only with the reason logged. This is enforced
  in the bridge, not just in the UI.
- **Platform convention:** `mount(8)` delivers no options for a regular mount;
  the kernel enforces `-o rdonly` at the VFS layer. The module therefore treats
  an option-less mount as read/write, and the session is still subject to the
  safety gate above.
- Unsupported operations (symbolic links, hard links, extended attributes) are
  reported as `ENOTSUP` rather than silently accepted.

## License

GPL-3.0 (see `LICENSE`). Bundles ntfs-3g (GPL-2.0-or-later); notices follow in
M5.
