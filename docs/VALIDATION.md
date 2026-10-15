# Validation checklist

Everything below uses **disposable NTFS images**. Never point any test at a
physical drive; the scripts refuse device paths and validate every BSD name
they receive from `hdiutil`.

## Automated (run before every release)

Run in order; each step must pass before the next.

```sh
./scripts/build-libntfs.sh          # [ ] SHA-256 verified, no FUSE linked
./scripts/run-engine-tests.sh       # [ ] "ENGINE TESTS: PASSED" (154 checks)
./scripts/create-dev-id-profiles.sh # [ ] both .provisionprofile written
./scripts/build-signed.sh           # [ ] BUILD SUCCEEDED, "entitlements OK"
./scripts/m1-mount-test.sh          # [ ] "M1 GATE: PASSED"
./scripts/m3-mount-test.sh          # [ ] "M3 GATE: PASSED"
./scripts/m4-mount-test.sh          # [ ] "M4 GATE: PASSED"
```

`./scripts/validate-all.sh` runs the engine, M3 and M4 gates in one go.

Between rebuilds, kill stale extension processes:
`pkill -9 -f NTFSModule.appex`

### What each gate proves

- **engine tests** — bridge correctness without FSKit: read/write cycles,
  truncate, unlink, readdir, lookup, rename (including overwrite), statfs,
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
