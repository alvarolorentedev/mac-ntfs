# MacNTFS

Open-source NTFS read/write for macOS using Apple's FSKit framework and the
upstream ntfs-3g engine. No kernel extension, no macFUSE, no Reduced Security.

Status: **M2 (engine proven)** — a signed FSKit module mounts a disposable NTFS
image read-only (M1 gate passed on macOS 27.0.1), and the libntfs-3g bridge
passes its engine tests: read/write/create/unlink/truncate round-trips, plus
dirty-volume and hibernation safety gates. Read/write through Finder arrives
with the FSKit volume mapping (M3).

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
three fresh disposable images: a read/write cycle (create, write, sync, remount,
verify, truncate, unlink, readdir), a dirty volume (read/write refused, falls
back to read-only with the reason), and a hibernated volume (`hiberfil.sys`
present). No FSKit and no physical devices involved.

## License

GPL-3.0 (see `LICENSE`). Bundles ntfs-3g (GPL-2.0-or-later); notices follow in
M5.
