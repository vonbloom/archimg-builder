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

- [ ] Push chunkah's output directly (`skopeo copy oci-archive:... docker://localhost:5000/...`,
      skopeo in a container like chunkah) instead of `podman load` + `podman push`: ~2.4 GB of
      compressed writes instead of 3.5 GB plus the import, lower memory peak. The manifest stays
      OCI as chunkah writes it.
- [ ] Layered images instead of one Containerfile per recipe: `base` (generic) -> desktop (`sway`,
      and `mango` to try mangowm, in cachyos-extra-v3) -> device (ucode, firmware, tlp.d, dracut
      GPU config, initramfs), published as `<device>-<desktop>`. Each extra combination only builds
      its device layer, and switching desktop on a laptop is a `bootc switch` (rollback included).
- [ ] Rebuild only what changed: drop `--no-cache` and let podman reuse layers, with a fingerprint
      of the package versions available for each layer (`pacman -Sy` + `pacman -Sp`, ~20 s) as a
      `--build-arg` of its install step, so a new package version invalidates that layer and the
      ones above. Arch updates the base nearly every week; the gain is for changes in the desktop
      or device layers and for reruns in the same week. Nothing changed: no new tag, no notification.
- [ ] VM 202 memory 8 -> 12 GB (homelab `host_vars/zeus.yml`, `qm set 202 --memory 12288`).
- [ ] Optional: pacman package cache across builds (`RUN --mount=type=cache`), ~700 MB of
      downloads per build (40 s today).
- The rpool NVMe replacement (homelab TODO) speeds up every I/O bound phase.

Upstream issues with a local workaround, to drop when they are fixed in a bootc release:

- [ ] bootc-dev/bootc#2557 (no firmware boot entry with `--bootloader systemd`): the
      `efibootmgr` step of `bootc/install`.
- [ ] bootc-dev/bootc#2558 (`timeout 5` never written): the `loader.conf` written by `bootc/install`.
- [ ] bootc-dev/bootc#2227 (version read from labels on ostree, annotations on composefs): keep
      both in `bootc/build`; the creation date fallback of `bootc-update` once every image has the
      annotation.
- [ ] AUR `bootc` without the `selinux` feature (reported in the AUR comments): `aur/local/bootc`
      while the AUR package links libselinux.

## Storage

- [ ] **Compress the existing data.** `compress=zstd:1` (2026-10-07, active on the P14s since the
      p14s-2026-10-07 deployment, 2026-10-08) only applies to new writes;
      the installer compressed the first deployment, everything written since then is not.
      `btrfs filesystem defragment -r -czstd /home` would compress `/home`, but it unshares the
      extents with the btrbk snapshots of `~/.gnupg` (small) and rewrites every file (SSD
      writes). Check the gain first with `compsize /home` (package `compsize`, as root).
- [ ] Stopped podman containers kept by `podman-cleanup`: decide on the old dev containers
      (`beautiful_boyd`: tramit-api-next, 6 months; `hopeful_dhawan`: tramit-csv, 2 months) and
      the `playground` distrobox (`podman rm`, `distrobox rm`).

## Memory and scheduling

- [ ] **systemd-oomd**, left out of the cachyos-settings subset (see CLAUDE.md, Memory tuning):
      revisit only if the system ever thrashes. It would need the `userland` distrobox protected
      (`ManagedOOMPreference=avoid` on a dedicated slice, monitoring `user@1000.service` instead
      of `user-.slice`) and testing that it kills a dev container and not userland.
- [ ] **sched-ext** (`scx_lavd`, an interactivity and power aware scheduler for laptops) on top of
      the BORE scheduler of linux-cachyos: optional experiment (`scx-scheds`, `scx_loader`).
