# Validation checklist

Everything below uses **disposable NTFS images**. Never point any test at a
physical drive; the scripts refuse device paths and validate every BSD name
they receive from `hdiutil`.

## Automated (run before every release)

Run in order; each step must pass before the next.

```sh
./scripts/build-libntfs.sh          # [ ] SHA-256 verified, no FUSE linked
./scripts/run-engine-tests.sh       # [ ] "ENGINE TESTS: PASSED" (179 checks)
./scripts/create-dev-id-profiles.sh # [ ] both .provisionprofile written
./scripts/build-signed.sh           # [ ] BUILD SUCCEEDED, "entitlements OK"
./scripts/make-installer.sh         # [ ] DMG notarized ("Accepted"), stapled, spctl accepted
./scripts/m1-mount-test.sh          # [ ] "M1 GATE: PASSED"
./scripts/m3-mount-test.sh          # [ ] "M3 GATE: PASSED"
./scripts/m4-mount-test.sh          # [ ] "M4 GATE: PASSED"
```

`./scripts/validate-all.sh` runs the engine, M3 and M4 gates in one go.

Between rebuilds, kill stale extension processes:
`pkill -9 -f NTFSModule.appex`

### What each gate proves

- **engine tests** — bridge correctness without FSKit: read/write cycles,
  truncate, unlink, readdir (cookies/resume), lookup, rename (including
  overwrite and into subdirectories), statfs, WIN32-namespaced names,
  case-insensitive lookups, case-preserving listings, timestamp updates,
  dirty-volume refusal, hibernation refusal, read-only enforcement.
- **M1 gate** — the signed module loads, probes the NTFS boot sector and mounts
  a disposable image.
- **M3 gate** — mounted read/write: mkdir, 1 MiB write, rename, unlink,
  SHA-256 content match across remount; explicit `-o rdonly` refuses writes; a
  dirty volume and a hibernated volume fall back to read-only with writes
  refused.
- **M4 gate** — the app's own code paths headlessly: Disk Arbitration listing,
  read-only mount with write refusal, read/write mount with write and readback,
  read-only remount persistence, eject, diagnostics export.

## VM matrix (FSKit API generations)

The supported floor is **macOS 26**: FSKit's original volume protocols
(`FSVolume.Operations`) are the only ones it has, while macOS 27 replaced them
with the async `FSVolume.Handler`. The extension carries both adapters, chosen
in `loadResource`; the host/CI machine runs macOS 27, so the V1 adapter is
exercised in VMs. One command per OS line:

```sh
./scripts/check-min-os.sh                                             # compile-floor guard (Mach-O minos <= 26.0)
./scripts/vm-validate.sh ghcr.io/cirruslabs/macos-tahoe-base:latest   # macOS 26.x
```

`vm-validate.sh` clones the image (or reuses a running VM), installs the signed
app from `build/DerivedData` into `/Applications`, enables the extension, runs
the engine, M3 and M4 gates inside the guest, reports which adapter loaded, and
deletes harness-created VMs afterwards unless `--keep` is passed. The registry
only publishes `latest` per OS family, so this validates the newest point
release of a line; for an exact build, create a VM with
`tart create --from-ipsw <file.ipsw>`, install the Tart guest agent, then pass
its name to `vm-validate.sh`.

Notes learned the hard way:

- The m3 mountpoint must be on the guest's own APFS; mounting onto the virtiofs
  share breaks `umount` (EINVAL) on macOS 26 and leaves stale mounts.
- m3 needs passwordless sudo inside the VM; `vm-validate.sh` configures it.
- The FSKit enabled-list plist is authoritative on 26; the harness still runs
  `pluginkit -e use` as a fallback.

Results (2026-10-16):

| Guest | Adapter | Engine | M3 | M4 | Notes |
|---|---|---|---|---|---|
| macOS 26.6.2 | V1 (`FSVolume.Operations`) | PASSED | PASSED | PASSED | full RW cycle + safety downgrades |
| macOS 27 (host) | V3 (`FSVolume.Handler`) | PASSED | PASSED | PASSED | |

### Why the floor is 26 and not 15.4

FSKit exists from macOS 15.4 and the code once built for it, but 15.x is
unsupported. On the only 15.x build available for testing (15.7.7):

1. `mount -F` is broken system-wide: fskitd drops the `mountVolume:…` XPC
   message ("received a message or reply block that is not in the interface"),
   for Apple's `com.apple.fskit.msdos` too, so exit 69 is not module-specific.
2. DiskArbitration mounts NTFS read-only through Apple's built-in
   `com.apple.filesystems.util.ntfs`, without ever starting our extension.
3. Our V1 adapter itself loads and opens the image read-write (verified in
   `log show`), so the bridge is fine; the 15.x system mount paths are the
   blocker. Re-verify on stock 15.x hardware before ever lowering the floor
   again.

## Manual (menu bar app)

- [ ] Launch the app; the extension shows **Enabled** (enable it if not).
- [ ] Attach a disposable NTFS image (Disk Utility or `hdiutil`); it appears in
      the menu with name and size.
- [ ] **Mount Read-Only** → volume appears under `~/Library/MacNTFS/Volumes/`;
      Finder cannot create a file in it.
- [ ] **Unmount**, then **Mount Read/Write** → Finder can create, rename and
      delete files; verify with a second read-only mount afterwards.
- [ ] **Eject** → the volume disappears from the menu.
- [ ] **Copy Diagnostics** → clipboard contains the report and the file exists
      in `~/Library/Application Support/MacNTFS/`.
- [ ] Dirty/hibernated behaviour (optional, images): craft with
      `build/tests/engine_tests --make-dirty <image>` and
      `--make-hibernated <image>`, then request **Mount Read/Write** and confirm
      the volume mounts read-only and writes fail.

## Physical disks (only on explicit request)

Physical-drive validation is out of scope for the default checklist. If it is
ever performed with the owner's explicit consent: back up first, mount
read-only first, and only then consider read/write on a clean volume.
