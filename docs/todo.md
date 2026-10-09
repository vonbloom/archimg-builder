# TODO

## Boot time (P14s)

Measured 2026-10-07: 31.6 s = 16.1 s firmware + 3.5 s loader + 0.9 s kernel + 7.5 s initrd +
3.6 s userspace. The firmware part cannot be helped; the initrd and loader parts can.

- [x] **amdgpu in the initramfs costs ~4 s: kept forced (decided 2026-10-08 after test boots).**
      `force_drivers+=" amdgpu "` (`p14s/.../10-gpu.conf`) makes `dracut-pre-udev` run `modprobe
      amdgpu` synchronously before udev starts: no other initrd work happens from 1.5 s until the
      driver starts probing at 5.5 s (same on every boot). It is there for Plymouth, which ignores
      simpledrm (the EFI framebuffer, built into linux-cachyos, up at 1.45 s) until `DeviceTimeout`
      (8 s) unless told to use it (`src/daemon/plymouthd-settings.c`, `plymouthd-policy.c`):
      `UseSimpledrm=1` or `UseSimpledrmNoLuks=1` (Fedora's default) in plymouthd.conf, or
      `plymouth.use-simpledrm` on the command line.
      - **Cause (2026-10-07, measured in a KVM VM booting the same vmlinuz + initramfs):** not the
        CPU speed. The VM, on a host CPU at full clock, takes the same 3.9 s, and the kernel's own
        initramfs unpack is as fast on the laptop (177 ms) as in the VM (212 ms), so the initrd
        already runs at full speed: loading `acpi-cpufreq` earlier would not help. With
        `initcall_debug` and a `function_graph` trace of `load_module`: decompression and
        signature check take ~0.14 s and `amdgpu_init` 1.5 ms. Almost all the rest is ftrace
        checking every traceable function of the module (`ftrace_module_enable` ->
        `test_for_valid_rec` -> `kallsyms_lookup`, ~0.2 ms each). Each lookup scans the module
        symbol table linearly, and amdgpu has 15,828 `__mcount_loc` entries and 75,071 symbols.
        Sorting the ORC unwind table (`unwind_module_init`) adds ~0.5 s. Wherever the module
        loads, this is paid.
      - **Test boots (2026-10-08, P14s docked, lid closed, two DisplayPort monitors on the dock;
        one-shot entries with test initramfs images, same deployment):**

        | | amdgpu forced | no amdgpu + `plymouth.use-simpledrm` | `add_drivers` (unforced) |
        |---|---|---|---|
        | initrd | 7.4 s | 1.7 s | 7.3 s |
        | Plymouth starts | 6.2 s | 1.9 s | 2.0 s, waits for amdgpu |
        | tty1 login | ~11.7 s | ~6.1 s | ~11.2 s |
        | amdgpu ready | 5.9 s | 12.4 s | 6.4 s |
        | initramfs | 57 MB | 22 MB | 57 MB |

        Without amdgpu the splash showed at once but deformed (the EFI mode on the dock's monitors
        has another aspect ratio), then tty1 stretched, until amdgpu, loaded by the real root in
        8 s instead of 4, took over at 12.4 s (the monitors blank and resync). A login before that
        would also start sway on simpledrm. Unforced, amdgpu still holds the initrd:
        `dracut-initqueue` waits for udev to settle before `/sysroot` is mounted. On the dock
        Plymouth is not seen with amdgpu either (forced or not): the monitors take seconds to
        resync after its modeset, by which time the splash is over. Undocked, the forced driver
        shows a clean splash from ~6 s.
      - The same trade-off applies to `i915` on the T480; not tested there.
      - Reproduce the load cost: `qemu-system-x86_64 -enable-kvm -cpu host -smp 16 -m 8G -display
        none -serial file:LOG -kernel /boot/arkdep/<deployment>/vmlinuz -initrd
        .../initramfs-linux.img -append 'console=ttyS0 root=LABEL=NONE ignore_loglevel
        systemd.log_target=kmsg initcall_debug'` and compare the timestamps of `dracut pre-udev
        hook` and `amdgpu: Virtual CRAT table`.
      - Test initramfs images without root (identical size to the image's own build):
        `unshare -r dracut --no-hostonly -c /dev/null --confdir <dir> --tmpdir ~/.cache/<dir>
        --kver $(uname -r) <out>` (chown errors and 600/700 modes are user namespace artifacts,
        harmless in an initramfs where everything runs as root; `--include` does not override
        files the plymouth module installs). Boot one with a copy of the deployment's entry and
        `bootctl set-oneshot <entry>.conf` (run sudo in a terminal).
- [x] **Unused dracut modules omitted** (`depends/generic/.../dracut.conf.d/20-omit-unused.conf`,
      2026-10-08): the initramfs, read by the firmware from the ESP (part of the 3.5 s loader
      time), went from 63 MB (110 MB unpacked) to 57 MB (88 MB) in a test build, mostly
      `hwdb.bin` (13 MB unpacked); booted fine in the test boots. To check on the next builds:
      the T480 and `iso/test-vm` (the previous deployment stays in the boot menu,
      `deploy_keep=2`). Most of the rest is amdgpu: its firmware for every AMD GPU (28 MB, already
      zstd-compressed; only `renoir_*` is used) and the module (6 MB).

## bootc builds

First server build (build-bootc@p14s, 2026-10-07, VM 202 with 6 cores): 18 min, I/O bound. Package
download and install take 1.6 min; committing the recipe layer (~3.5 GB, ~100k files) 5.6 min;
chunkah + `podman load` ~7 min (and the 6.9 GB memory peak of the 8 GB VM); the push 1 min (later
pushes only upload changed layers). The VM disk is a zvol on zeus' Kingston SA400 SATA SSDs.

Layer reuse (measured 2026-10-09 in the registry): the two t480 builds of 2026-10-08, 20 min
apart with recipe changes in between, share 104 of 128 layers: the update downloads 162 MiB of the
1035 MiB image. chunkah's layers are reproducible for unchanged packages (directory mtimes come
from the packages' build dates). 2026-10-07 -> 2026-10-08 shared none: the owner/mode fix of
`/usr`, `/usr/lib` and `/usr/share` (`build-recipe.sh`) changed those parent directories in every
layer, a one-off. Still to see on a regular weekly build: which layers change on every build
(VERSION_ID with the time in os-release, install dates in the pacman database, the initramfs?).

- [ ] **Boot test before publishing `latest`.** The composefs backend sets up no boot counting
      (bootc docs, `bootc-boot-failure-detection.7.md`: "likely to be added in the future"), unlike
      arkdep's `+3` entries: an image that does not boot is only found when the T480, which
      stages updates every 4 h by itself, reboots into it, and the user has to pick the previous
      entry by hand. Gate `latest` (what the T480 follows) on a boot in a VM, the manual VM
      rehearsal of 2026-10-08 automated:
      - Nested KVM for VM 202: zeus (i5-8500) has `kvm_intel nested=Y`, but VM 202 runs with
        `cpu: x86-64-v3`, which hides VMX (no `/dev/kvm`). By hand: `qm set 202 --cpu host`,
        restart the VM, then `host_vars/zeus.yml` (and `pve_guests` support for `cpu` if missing).
      - Server packages: `qemu-system-x86` and `ovmf` (homelab `builders` play).
      - `bootc/test <recipe> <image>`: `bootc install to-disk --via-loopback --composefs-backend
        --bootloader systemd --filesystem btrfs --karg console=ttyS0` into a sparse raw file (in a
        privileged container of the new image, like `bootc/install` does from the ISO), then
        `qemu-system-x86_64 -enable-kvm -machine q35 -m 4G` with OVMF, the disk, no network,
        `-serial file:...`, and wait (with a timeout, ~5 min) for the getty's `login:` on ttyS0.
        Also fail on `emergency`/`Failed to start` lines. Test from the signed registry image
        (the reference the T480 pulls) or check that the image's own `policy.json`, which requires
        signatures for `192.168.2.50:5000`, does not refuse a local source reference.
      - `bootc/build`: push the dated tag (signed) as today, run the test, and only then point
        `latest` at it. On failure keep `latest`, notify Home Assistant with the tail of the
        serial log (`notify-failure@` already runs on a failed unit) and keep the log next to
        the `.pkgs` file.
      - bootc-dev/bootc#2557 and #2558 need no workaround in the test: OVMF boots the
        `EFI/BOOT` fallback bootc installs, and without a menu timeout the default entry boots.
      - Cost: ~5 min per build, ~10 GB of temporary disk (56 GB free). Catches what breaks the
        generic boot (initramfs and dracut modules, composefs setup, `/etc` merge, failing
        units, emergency mode), not hardware specific drivers (i915, Wi-Fi) or the desktop.
- [x] **Push chunkah's output with skopeo** instead of `podman load` + `podman push` (2026-10-09).
      Test build of t480 to `test/t480`: 9 min 49 s instead of ~18, memory peak 3 GB instead of
      4.7-6.9 GB, 1.5 min of CPU instead of ~4.5 (no import, no recompression). After the recipe
      layer is committed: chunkah 15 s, skopeo pull 9 s (first run), push of all 128 layers to an
      empty repository 64 s. Tags, OCI manifest, the four annotations and the sigstore signature
      checked; the signature accepted by a copy of `:latest` with the T480's policy. The first
      real build re-uploads every layer to `t480` (chunkah's gzip bytes), and the T480 downloads
      the whole image (~1 GiB) once.
      - Today chunkah writes a gzip-compressed OCI archive (`--compressed` also gzips the whole
        archive around the already compressed layers) to stdout; `podman load` decompresses it
        and writes every layer uncompressed into containers-storage (~3.5 GB on the zvol of
        worn SATA SSDs); `podman push` then reads them back and compresses the layers it cannot
        match to registry blobs through its blob info cache.
      - Instead: `chunkah build ... --compressed -o oci:/out/<recipe>` (an OCI directory layout:
        layers gzip-compressed once, no outer archive) into a work directory on the server (the
        compressed image is ~1.0 GiB today), then
        `skopeo copy --preserve-digests --dest-tls-verify=false --sign-by-sigstore-private-key ...
        --sign-passphrase-file ... oci:<dir> docker://192.168.2.50:5000/<recipe>:<date>` and the
        same copy, unsigned, to `:latest` (blobs already there are skipped, the manifest digest
        stays the same, so the signature covers both tags as today). `--preserve-digests` makes
        skopeo fail rather than rewrite the manifest. skopeo reads `registries.d` for
        `use-sigstore-attachments` like podman: either Debian's `skopeo` package on the server
        (homelab `builders` play) or `quay.io/skopeo/stable` in a container with
        `/etc/containers/registries.d` and the key directory mounted.
      - Gains: ~1 GiB written once instead of the 3.5 GB import plus the re-read, no gzip of the
        archive and no recompression; less page cache charged to the unit (its 4.7-6.9 GB
        "memory peak" includes it). chunkah alone with `-o oci:` takes 26-29 s (2026-10-09,
        rechunking the published t480 image on the server), so nearly all of the ~7 min of
        "chunkah + `podman load`" is the import: most of it should go.
      - Upstream issues: every manifest annotation (`org.opencontainers.image.version` for
        bootc-dev/bootc#2227, `created`, `base.digest`, `base.name`) is written by chunkah itself
        (checked in its `oci:` output), and `--preserve-digests` copies the manifest unchanged,
        so the #2227 workaround keeps working. The same flag keeps the image OCI: the composefs
        backend fails on Docker v2s2 manifests (bootc-dev/bootc#1703, open); skopeo would fail
        instead of converting. #2557 and #2558 concern `bootc install`, not the push. The
        `podman inspect`/`podman rmi` of the built image stay.
      - One-off cost: the first image pushed this way has chunkah's gzip bytes instead of
        podman's (0 of 128 compressed layers matched the registry's in the test), so the T480
        downloads the whole image once (~1 GiB). Afterwards reuse depends on chunkah's gzip
        staying byte-identical for identical input: two runs on the same input gave the same
        manifest and all 128 layers byte for byte. Pin `CHUNKAH` to a version tag instead of
        `latest`, so that a compression library update does not trigger another full download
        unannounced.
- [ ] Layered images instead of one Containerfile per recipe: `base` (generic) -> desktop (`sway`,
      and `mango` to try mangowm, in cachyos-extra-v3) -> device (ucode, firmware, tlp.d, dracut
      GPU config, initramfs), published as `<device>-<desktop>`. Each extra combination only builds
      its device layer, and switching desktop on a laptop is a `bootc switch` (rollback included).
      Prospect with a third kind of machine (yamaha: x86-64-v2, Cinnamon, appliance services),
      the split of `depends/generic` into base and modules, and a phase 1 in today's recipe
      format: `layers.md` (2026-10-09).
      Once bootc is the default, the arkdep conventions of `image/arkdep-build.d` (`depends.list`,
      `bootstrap.list`/`package.list`, `post_bootstrap`/`post_install` overlays, `extensions/`,
      `build-recipe.sh` replaying them) go: each layer gets its own manifest (packages and overlay
      next to its Containerfile, like `userland/`). What lives in `depends/generic` for both builds
      today moves to the base layer, e.g. the registry's client config (`etc/containers`, moved
      there from `bootc/overlay` on 2026-10-09) and its key (`post_install.sh` for arkdep,
      `build-recipe.sh` for bootc: one `install` in the base layer).
      - The userland image stays apart from these layers (decided 2026-10-09). The host image takes
        what needs root, hardware, the boot or the session (drivers, network, virtualization,
        the compositor, portals, the keyring) plus what the host's own shells and scripts use;
        the userland image takes the user's apps and tools, which change often. Apart, an app
        update is a box replaced in seconds, not a build of the system and a reboot; the `[aur]`
        packages' install scripts run as root in the box, not on the host; a broken userland
        still boots and rolls back alone; both laptops share it whatever the host runs (arkdep,
        bootc); and playground tries packages in the real environment. Moving a package is a
        line from one `packages.list` to the other. Duplicates are on purpose (zsh-completions,
        fzf, git, man-db...: the host's shells and the boxes' each need theirs).
      - Borderline: Thunar with gvfs and xfconf, the one app that needs the D-Bus services
        forwarded to the box (`userland/dbus-1/`). In the desktop layer that workaround would go.
- [ ] Rebuild only what changed: drop `--no-cache` and let podman reuse layers, with a fingerprint
      of the package versions available for each layer (`pacman -Sy` + `pacman -Sp`, ~20 s) as a
      `--build-arg` of its install step, so a new package version invalidates that layer and the
      ones above. Arch updates the base nearly every week; the gain is for changes in the desktop
      or device layers and for reruns in the same week. Nothing changed: no new tag, no notification.
- [ ] VM 202 memory 8 -> 12 GB (homelab `host_vars/zeus.yml`, `qm set 202 --memory 12288`). Less
      pressing since the skopeo push: a bootc build peaks at 3 GB.
- [ ] Optional: pacman package cache across builds (`RUN --mount=type=cache`), ~700 MB of
      downloads per build (40 s today).
- The rpool NVMe replacement (homelab TODO) speeds up every I/O bound phase.

## userland image

The userland distrobox built here as an image (`userland/`, 2026-10-09) instead of assembled and
upgraded in place on each machine from the dotfiles' `default.ini`. Done: the image, its manifest
(`/usr/share/userland/distrobox.ini`), the weekly build and the status page. Test builds on the
server (2026-10-09): 15 min, 1.63 GB compressed in 128 layers (the live userland's writable layer
was 8.9 GB, 3.7 GB of it package cache); a box created from it on the P14s started in 13 s
without installing anything, with zsh, `ca_ES.UTF-8`, the apps and the remote podman working.
Still to do, in order:

- [ ] **Pull from the registry on the laptops**: the registry's client config moved from
      `bootc/overlay` to the generic overlay (`registries.conf.d` with `192.168.2.50:5000` as
      insecure, `registries.d`, a `policy.json` that requires the signature for that registry and
      keeps Arch's default for the others), and the arkdep image gets the key from `keys/`
      (2026-10-09). To check once the P14s runs an image built with it: `podman pull
      192.168.2.50:5000/userland:latest` works, and an unsigned image there is refused.
- [x] **`userland-update`** in the host images (generic overlay, 2026-10-09): pulls
      `userland:latest`, and if userland runs another image reads `distrobox.ini` and the D-Bus
      services from it, pins its `image=` lines to the pulled digest, `distrobox assemble create
      --replace` (asks first if userland runs: its apps close), installs the services, removes the
      previous image. `deploy-userland` runs it when there is no userland box. Dry run on the
      P14s from the checkout: pulled the real image in 38 s. The manifest gained the exports made
      by hand on the P14s (`gimp`, `magick`, `unzip`).
- [x] **Switch the laptops' boxes to the image**: the P14s on 2026-10-09 (`userland-update` from the
      checkout, 38 s with the image already pulled: both boxes, 14 exports, D-Bus services;
      zsh, locale, VS Code, Ansible, ssh and the remote podman work; the old userland's 8.9 GB
      writable layer gone); the T480 the same day (its t480-2026-10-09 image, script from the
      checkout: 126 s over Wi-Fi, then `--playground`). The dotfiles' `distrobox` package went the
      same day (unstowed on both laptops first: `default.ini`, the pre-init hook, the copy of the
      `[aur]` key, the D-Bus services).
- [x] **waybar notice** (2026-10-09): `custom/userland` (`userland-update-status`, sway layer)
      compares the registry's `userland:latest` digest with the image the box runs every hour (no
      staged pull: `userland-update` pulls on the click, 40 s on the LAN) and shows the package
      changes from the two images' lists. To check once the laptops run an image with it.

## bootc: sealed images (if bootc stays)

Read 2026-10-09: the bootc.dev series "Sealed images" (2026-05-04 to 05-07) and the bootc docs
(`bootc-composefs.7.md`, `building/bootc-sealed-images.7.md`). A sealed image is a chain from the
firmware to every file: Secure Boot (own keys) -> signed systemd-boot -> signed UKI (kernel,
initramfs and command line in one EFI binary) whose command line carries the composefs digest of
the whole root (`composefs.digest=v1-sha512-12:...`, computed at build time) -> the initramfs only
mounts a root with that digest, and fs-verity checks every file on read (a tampered file returns
EIO). Without Secure Boot "nothing validates that root digest itself": any root process can
replace the UKI, so a UKI alone adds little.

- [x] **Check what the T480 has now** (2026-10-09): fs-verity is enforced with the BLS entries
      (`findmnt /` shows `verity=require`, `composefs.digest=v1-sha512-12:...` on the command
      line, `fsverity=yes` in the kernel log). That is the integrity half; the digest there is
      written by the client, not authenticated.
- [ ] **btrfs compression + fs-verity: spurious `FILE CORRUPTED!`** on the T480 (kernel
      7.2.9-1-cachyos, both boots since the install). The kernel logs `fs-verity (nvme0n1p3,
      inode N): FILE CORRUPTED! pos=... level=-1` for objects of the composefs repository, mostly
      at 128 KiB offsets (btrfs compressed extents), yet every read succeeds: reading the whole
      root as roger gave no I/O error (20 messages on the way). Reproduced without root in
      `/var/tmp`: a 60 MB file of libraries, SHA-512 verity enabled, page cache dropped, read 3
      times: 10 messages and no read error when btrfs compressed it (`compress=zstd:1`), none
      with `chattr +m` (uncompressed). Without verity, 10 reads of a 200 MB compressed file after
      dropping the cache all gave the written bytes. So the stored data is intact and a readahead
      of compressed extents fails verification, then the synchronous retry passes. Fedora IoT hit
      the same message on btrfs with 6.16.8, where reads did fail (EIO, SIGBUS, broken login);
      fixed by "btrfs: fix incorrect readahead expansion length" (Oct 2025,
      https://discussion.fedoraproject.org/t/165159). A kernel where the retry fails too would
      break the T480 the same way (`bootc rollback` boots the previous deployment, whose objects
      are mostly the same files).
      - Narrowed down (2026-10-09): the P14s (another NVMe and CPU) gives the same 10 messages, so
        not the T480's hardware; so does Arch's own kernel in a VM (cloud image, virtio disk,
        btrfs `compress=zstd:1`): 7.2.2, 7.2.7 and 7.2.9-arch1 fail, 6.18.55-lts, 7.0.14 and
        7.1.11 do not. A regression of the 7.2 merge window, not CachyOS's. Reads with
        `POSIX_FADV_RANDOM` (no readahead) give none: readahead of compressed extents. VM and
        scripts kept in `~/.cache/verity-vm` (`vm-kernel.sh <arch version>` installs a kernel
        from the Arch archive, boots it and runs both tests). Reported to linux-btrfs on
        2026-10-09 (Cc fsverity and regressions, `#regzbot introduced: v7.1..v7.2.2`). Next, when
        they answer: bisect v7.1..v7.2 in that VM if they ask for it, test their patches.
      - Avoid it on new installs: `bootc/install` mounts the root and sets `rootflags` with
        `compress=zstd:1`; `chattr +m` on `/sysroot/composefs` before the image is written, or
        no compression on the bootc root at all (costs disk: the objects are mostly binaries).
        Existing objects stay compressed (verity files cannot be rewritten in place).
- [ ] **Sealed images, together with LUKS + TPM2.** Sealing protects the system, not the data: a
      stolen laptop's `/var/home` is readable without disk encryption. The pair that pays off is
      a TPM2-bound LUKS key released only when our signed UKI boots (`systemd-cryptenroll`).
      - Build: two Containerfile stages, `bootc container split-kernel-and-rootfs` and
        `bootc container ukify --rootfs ... --kernel-dir ... -- --signtool sbsign
        --secureboot-private-key ... --secureboot-certificate ...`, the UKI copied to
        `/boot/EFI/Linux/`, systemd-boot signed with the same db key. The key reaches the build
        as a podman secret (never in a layer), lives in `/etc/distro-builder/` and in the homelab
        vault like the sigstore key. Tools available: `systemd-ukify` 262 and `sbsigntools`
        (Arch), and our bootc 1.17.1 has `split-kernel-and-rootfs`, `compute-composefs-digest`,
        `--allow-missing-verity` and the Secure Boot key enrolment.
      - Machines: own PK/KEK/db enrolled with the firmware in Setup Mode (systemd-boot
        `secure-boot-enroll` from `/usr/lib/bootc/install/secureboot-keys/<name>/`, or `sbctl`),
        keeping Microsoft's keys (Lenovo and fwupd firmware updates, option ROMs). The installer
        ISO is not signed: install with Secure Boot off, enable it afterwards. LUKS needs the
        dracut modules left out on 2026-10-08 back (`crypt`, `systemd-cryptsetup`, `dm`, and
        `systemd-pcrextend` for TPM policies), and bootc's install with LUKS + TPM has an open
        issue (bootc-dev/bootc#421).
      - Limits: the kernel command line is fixed in the image (machine specific arguments such
        as `resume=` go; systemd resumes from the `HibernateLocation` EFI variable instead), btrfs
        is "expected to work but not tested" upstream (their CI covers ext4 and XFS), keys must
        be rotated (db key valid 10 years in the examples). The P14s gains nothing while it runs
        arkdep: this is also an argument for bootc in the comparison.
      - Test in a VM first: OVMF with our keys enrolled (`virt-fw-vars --set-pk/--add-kek/--add-db`,
        as in the series), which the boot test above can reuse to check the seal on every build
        (`verity=require`, `mokutil --sb-state`) before touching the T480's firmware.

Upstream issues with a local workaround, to drop when they are fixed in a bootc release:

- [ ] bootc-dev/bootc#2557 (no firmware boot entry with `--bootloader systemd`): the
      `efibootmgr` step of `bootc/install`.
- [ ] bootc-dev/bootc#2558 (`timeout 5` never written): the `loader.conf` written by `bootc/install`.
- [ ] bootc-dev/bootc#2227 (version read from labels on ostree, annotations on composefs): keep
      both in `bootc/build`; the creation date fallback of `bootc-update` once every image has the
      annotation.
- [ ] AUR `bootc` without the `selinux` feature (reported in the AUR comments): `aur/local/bootc`
      while the AUR package links libselinux.

## arkdep upstream

- [ ] arkanelinux/arkdep#53: `arkdep deploy` computes the boot entry's file name (with the time)
      for every template line, so an entry written across a second boundary is split in two: a
      title-only `<time>-<image>+3.conf` and the rest under the next second, shown by its file
      name (p14s-2026-10-08). No workaround in the images: merge them by hand or let the entry go
      with its deployment. Also reported there: the conflict check before writing never matches,
      and `arkdep cleanup` never removes the boot entry and kernel of an untracked deployment
      (`[[ -f ...*glob* ]]`); `remove_deployment` does.
      - Fixed upstream in ef6738e (2026-10-09, not released: `[arkane]` still has 2026.08.17), but
        the fix computes the time as `$($(date +%Y%m%d-%H%M%S))`: bash runs the time as a command
        ("command not found") and the variable is empty, so every entry would be named
        `-<image>+3.conf`. Reported:
        https://github.com/arkanelinux/arkdep/issues/53#issuecomment-6077770244, fixed in
        366d3af (2026-10-09, the single substitution we proposed). Neither is released yet. When
        the P14s image takes the next arkdep release, check that it includes 366d3af (`grep
        systemd_boot_entry_timestamp /usr/bin/arkdep`: one `$(`) and, after the first deploy with
        it, the entry's name on the ESP. The other two points are still open.

## Storage

- [x] **Compress the existing data: not done (decided 2026-10-09).** `compress=zstd:1`
      (2026-10-07, active on the P14s since the p14s-2026-10-07 deployment, 2026-10-08) only
      applies to new writes. `sudo compsize -x /home` on 2026-10-09: 76 GB on disk, of which 2.4 GB
      written since then is zstd (37 %) and 75 GB uncompressed, but 127 GB referenced: ~50 GB are
      extents shared between files (reflinks). `btrfs filesystem defragment -r -czstd /home` would
      unshare them (the disk usage could grow) and rewrite ~75 GB on the SSD, for a modest gain
      (container layers, ISOs, browser cache and downloads compress little), with `/home` 25 %
      full (356 GB free). Files rewritten from now on get compressed anyway. If one large,
      compressible directory without reflinks ever matters, defragment only that one.
- [x] Stopped podman containers kept by `podman-cleanup`: the dev containers stay (VS Code
      reopens them; 17.6 GB of writable layers on the P14s, 2026-10-09), and `playground` comes
      from the userland image now.

## Memory and scheduling

- [ ] **systemd-oomd**, left out of the cachyos-settings subset (see CLAUDE.md, Memory tuning):
      revisit only if the system ever thrashes. It would need the `userland` distrobox protected
      (`ManagedOOMPreference=avoid` on a dedicated slice, monitoring `user@1000.service` instead
      of `user-.slice`) and testing that it kills a dev container and not userland.
- [ ] **sched-ext** (`scx_lavd`, an interactivity and power aware scheduler for laptops) on top of
      the BORE scheduler of linux-cachyos: optional experiment (`scx-scheds`, `scx_loader`).
