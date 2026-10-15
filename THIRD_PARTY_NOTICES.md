# Third-party notices

MacNTFS links the following third-party software. All of it is used under
licenses compatible with this project's GPL-3.0 license.

## ntfs-3g (libntfs-3g) — GPL-2.0-or-later

- Upstream: https://github.com/tuxera/ntfs-3g
- Version: **2026.9.28** (official release tarball)
- Source: `https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz`
- SHA-256: `350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8`
- Copyright: the ntfs-3g authors (Anton Altaparmakov, Richard Russon,
  Szabolcs Szakacsits, Yura Pakhuchiy, Jean-Pierre Andre, Tuxera Inc. and
  others). See the source tree's `AUTHORS`, `CREDITS`, and `COPYING`.
- License: GNU General Public License, version 2 or (at your option) any later
  version. The copy shipped upstream is `COPYING` (GPL-2.0 text); a copy is
  also available at https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
- What is used: `libntfs-3g.a`, a static library built by
  `scripts/build-libntfs.sh`. The FUSE driver, mount helper and mtab support
  are disabled at configure time (`--disable-ntfs-3g`, `--disable-mount-helper`,
  `--disable-mtab`), so no FUSE code is compiled or linked: MacNTFS calls
  libntfs-3g directly from the FSKit extension through `bridge/ntfs_bridge.c`.
- Also built, for development only: `mkntfs` from the same source tree, used to
  create disposable test images. It is not shipped or required at runtime.

Because every linked file is licensed "GPL-2.0 or later", the combined work may
be distributed under this project's GPL-3.0 license.

## Apple frameworks

The app and the file system extension link Apple system frameworks (FSKit,
DiskArbitration, Foundation, SwiftUI) under the macOS SDK terms. No Apple
sample code is copied into this repository.

## This project

MacNTFS is licensed under GPL-3.0; see `LICENSE`.
