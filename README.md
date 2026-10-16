# MacNTFS

Open-source NTFS read/write for macOS. Built on Apple's FSKit framework and the
upstream ntfs-3g engine: no kernel extension, no macFUSE, no Reduced Security,
and no SIP changes.

Status: **0.1.0** — read/write mounting verified on **macOS 27.0.1** (Apple
Silicon). MacNTFS probes NTFS volumes, mounts them through FSKit, and supports
create, write, rename, unlink, truncate and read with content verified across
remounts. Dirty and hibernated volumes are refused read/write and mount
read-only with the reason logged.

## What you get

- A menu bar app that lists every NTFS volume Disk Arbitration reports.
- **Mount Read-Only** as the default; **Mount Read/Write** as an explicit
  per-volume opt-in.
- Unmount, eject, reveal in Finder and a one-click diagnostics report.
- A safety model that never mounts a dirty or hibernated (Windows Fast Startup)
  volume read/write and never formats, repairs or erases anything.

## Requirements

- macOS 27, Apple Silicon.
- FSKit itself requires macOS 15.4+, but this project has only been built and
  tested against the macOS 27 SDK and runtime. There is no macOS 26 or 15
  support claim.

## Install

1. Download `MacNTFS-<version>.dmg` from the
   [GitHub releases](../../releases) and open it.
2. Drag **MacNTFS.app** to `/Applications`, then launch it once — this registers
   the file system extension.
3. Press **Enable File System Extension** in the menu bar window, or use
   System Settings → General → Login Items & Extensions → File System
   Extensions.

To build from source instead, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Use

The menu bar lists every NTFS volume Disk Arbitration reports.

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

## Uninstall

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

## Documentation

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — architecture, build, signing and
  release CI.
- [docs/VALIDATION.md](docs/VALIDATION.md) — release validation checklist.
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) — troubleshooting symptoms, causes
  and actions.

## Licenses

MacNTFS is GPL-3.0 (`LICENSE`). It statically links ntfs-3g (GPL-2.0-or-later);
see `THIRD_PARTY_NOTICES.md` for versions, hashes and attribution.
