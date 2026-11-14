# Mountee

**[mountee.app](https://mountee.app) — NTFS read/write on macOS, without a kernel
extension, macFUSE, or security compromises.**

Mountee is a free, open-source (GPL-3.0) NTFS driver and menu bar app for Apple
Silicon Macs. It builds on Apple's FSKit framework and the upstream ntfs-3g
engine, so it mounts NTFS drives with full read/write access from user space:
nothing to approve in Recovery Mode, nothing to downgrade, nothing left behind
after you remove it.

Status: **0.3.0** — read/write verified on **macOS 27.0.1** and **macOS 26.6.2**
(Apple Silicon).

## Why Mountee

- **No kernel extension.** Built on Apple's FSKit framework, so there is no
  kext to approve, no Reduced Security, no SIP changes and no reboot. Your Mac
  stays at Full Security.
- **No macFUSE.** The ntfs-3g engine is compiled into the app. There is
  nothing else to install and no Homebrew at runtime.
- **Safe by default.** Volumes mount read-only; read/write is an explicit
  per-volume action. Dirty or Windows-hibernated volumes (Fast Startup) are
  never mounted read/write. Mountee never formats, repairs or erases anything.
- **Honest about failure.** Unsupported operations return `ENOTSUP` and
  metadata files can never be deleted — nothing reports a false success.
- **Free and open source.** GPL-3.0, auditable, with a pinned and SHA-256
  verified ntfs-3g build.
- **Native experience.** Volumes appear under `/Volumes` like any other disk;
  a menu bar app lists them with mounting, unmounting, ejecting and
  reveal-in-Finder.

## How it compares

| | **Mountee** | macOS built-in | macFUSE + ntfs-3g | Paragon / Tuxera |
|---|---|---|---|---|
| NTFS read | Yes | Yes | Yes | Yes |
| NTFS write | Yes | No | Yes | Yes |
| Kernel extension | **No** (FSKit, user space) | No | Yes¹ | Yes |
| Security changes | **None** | None | Reduced Security¹ | Reduced Security |
| Reboot to install | No | — | Yes¹ | Yes |
| Cost | Free | Included | Free | ~$15–30 |
| Open source | GPL-3.0 | — | Yes | No |
| Kernel code to break on OS updates | None | None | Yes | Yes |

¹ Recent macFUSE releases include an experimental FSKit backend that avoids
the kext, but the established macFUSE + ntfs-3g setup still uses the kernel
backend, which requires disabling third-party kext protection in Recovery Mode
and restarting.

The built-in macOS driver is read-only. Commercial drivers work well, but they
are paid, closed source, and historically depend on kernel extensions that
break with macOS updates and require lowering your Mac's security. Mountee is a
free, open-source option that gets read/write without either.

## Requirements

- **macOS 26 or later**, Apple Silicon. Verified on macOS 26.6.2 and 27.0.1.
- Nothing else. No macFUSE, no Homebrew, no admin tools.

## Install

1. Download `Mountee-<version>.dmg` from the
   [GitHub releases](../../releases) and open it.
2. If upgrading, quit and remove `/Applications/MacNTFS.app` first. Drag
   **Mountee.app** to `/Applications` and launch it.
3. Press **Enable File System Extension** in the menu bar window. Add
   Mountee to Login Items again when prompted.

This release changes the app and FSKit identifiers. Existing diagnostic reports are copied from
`~/Library/Application Support/MacNTFS` into the new support folder without
removing the originals. Existing or active mountpoints are left in place; new
fallback mounts use `~/Library/Mountee/Volumes`.

That's it. No reboot, no Recovery Mode, no security settings to change. This is
per-user: enable the extension once in each macOS account that should mount
drives.

## Use

The menu bar lists every NTFS volume Disk Arbitration reports.

- **Mount Read-Only** — default action; writes are refused.
- **Mount Read/Write** — explicit opt-in; still refused (mounts read-only) when
  the volume is dirty or hibernated.
- **Unmount**, **Eject**, **Reveal**, **Details** — per volume.
- **Open Mountee at login** — toggle to start the app automatically; offered
  once on first launch, defaulting to on.
- **Copy Diagnostics** — copies a troubleshooting report to the clipboard.

Mounted volumes appear in Finder and `/Volumes` like any other disk. To
uninstall: eject all volumes, disable the extension in System Settings →
General → Login Items & Extensions → File System Extensions, then delete
`/Applications/Mountee.app` and its support data under
`~/Library/Application Support/Mountee` and `~/Library/Mountee`.

## Safety model

- Read-only by default; read/write is a per-volume explicit action.
- Dirty and hibernated volumes (Windows Fast Startup) are never mounted
  read/write — they mount read-only with the reason logged.
- Never formats, repairs or erases anything, even when asked to.
- Metadata files (`mft_no < 16`) can never be unlinked.
- Unsupported operations return `ENOTSUP`; nothing reports false success.

## Maturity and limitations

Mountee is young (0.3.0). The write path is verified with content hashes across
remounts on disposable images, but treat read/write on valuable disks like any
new driver: keep backups and try it on non-critical data first. The safety
gates above are the main protection against the classic NTFS corruption cases.

Known limits include: no POSIX permission mapping yet, no symlinks/hard
links/extended attributes, and fsync delivery is not fault-injection tested.
The full list lives in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Documentation

- [docs/LIMITATIONS.md](docs/LIMITATIONS.md) — full known-limitations list.
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) — troubleshooting symptoms,
  causes and actions.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — architecture, build, signing
  and release CI.
- [docs/VALIDATION.md](docs/VALIDATION.md) — release validation checklist.

## License

Mountee is GPL-3.0 (`LICENSE`). It statically links ntfs-3g (GPL-2.0-or-later);
see `THIRD_PARTY_NOTICES.md` for versions, hashes and attribution.
