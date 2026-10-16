# Known limitations

Current, honest limits of MacNTFS 0.1.0. None of these are silent: unsupported
operations return `ENOTSUP` rather than a false success.

- **fsync delivery is not independently verified end to end.** Writes use the
  resource's direct I/O path and the volume syncs on unmount; crash-consistency
  under power loss has not been fault-injection tested.
- **Rename cannot refuse `RENAME_SWAP`**: FSKit passes no rename flags (Apple
  bug FB24419773), so a swap request is performed as a destination replace.
- **POSIX permissions are not mapped** from NTFS security descriptors yet;
  uniform mode bits are reported and ownership is ignored (`noowners`).
- **Symlinks, hard links, extended attributes/resource forks**: reported as
  unsupported (`ENOTSUP`). Windows junctions appear as plain entries.
- **Mount location**: via Disk Arbitration the system picks `/Volumes/<name>`;
  when the app falls back to the `mount -F` path it uses
  `~/Library/MacNTFS/Volumes/<name>`.
- **One volume per resource** (FSKit unary design, matching NTFS semantics).
- **Platform**: built and tested only against the macOS 27 SDK and runtime on
  Apple Silicon. FSKit itself requires macOS 15.4+, but no support is claimed
  for earlier releases.
- **Stale extension processes** can linger after unmounts during development;
  `pkill -9 -f NTFSModule.appex` before rebuilding.
