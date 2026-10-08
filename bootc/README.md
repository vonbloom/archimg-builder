# bootc images

Trial (since 2026-10-07) of [bootc](https://github.com/bootc-dev/bootc) as a replacement for
arkdep: the same recipe (`image/arkdep-build.d/<recipe>`) built as a bootc container image, based
on the Arch image of [bootcrew/mono](https://github.com/bootcrew/mono). Built and pushed to the
build server's registry by `build-bootc@<recipe>` (see the main README). While arkdep and bootc are
compared the T480 runs bootc (`t480`, built weekly) and the P14s stays on arkdep (`p14s` bootc
image by hand); `install` sets the schedules.

- `Containerfile`: CachyOS v3 repositories and `linux-cachyos` like the recipe; `bootc` from the
  `[aur]` repository (`aur/local/bootc`: pinned version, no SELinux); composefs backend.
- `build-recipe.sh`: applies the arkdep recipe in arkdep-build's order (package lists, overlays,
  presets, locale-gen), without arkdep, `arkane-keyring` and `nss-altfiles`.
- `overlay/`: files only bootc systems need (the registry, AppArmor's `@{HOMEDIRS}`, the masked
  `systemd-boot-random-seed.service`, `bootc-update.timer`: stages new images, see the main README).
- `build`, `prune`: build, rechunk and push; retention in the registry.
- `install`: installs an image from the installer ISO on existing partitions, keeping `/home` (see
  the main README).

```
podman build --no-hostname -f bootc/Containerfile --build-arg RECIPE=p14s -t localhost/p14s-bootc .
bcvk to-disk --composefs-backend --bootloader systemd --filesystem btrfs --format qcow2 \
    --disk-size 30G --target-transport containers-storage localhost/p14s-bootc disk.qcow2
```

`bcvk` (release binaries at github.com/bootc-dev/bcvk) installs the image to a disk image from an
ephemeral VM, rootless. Boot the disk with QEMU + OVMF like `iso/test-vm`.

## Results (VM, bootc 1.17.0, bcvk 0.21.0, 2026-10-07)

These tests compiled bootc in the Containerfile (since replaced by the `[aur]` package).

- The image matches the arkdep p14s image: same 520 packages and versions except the arkdep stack
  (bootc adds `composefs`, `ostree`, `skopeo`), same enabled system and user units. 4.1 GB.
- Install: ESP + btrfs root, systemd-boot, ~2 min. Boots to sway with waybar (autologin added by a
  test-only layer), no failed units, 11.5-13.6 s in the VM (initrd 6.7-7.2 s: the forced amdgpu
  load, see `docs/todo.md`).
- Updates from a registry (`bootc switch`/`upgrade`), image split per package with
  [chunkah](https://github.com/coreos/chunkah) (128 layers, 1.2 GB, it reads the pacman database
  at `/usr/lib/sysimage`): a full rebuild with the same package versions changed 12 layers, 208 MiB
  downloaded, 7 s to stage, +91 MiB on disk (composefs stores each file once). arkdep downloads the
  whole image (~900 MB) every time. Of the 208 MiB: 118 MiB are the bootc binaries rebuilt from
  source (not reproducible; `install-all` also ships the integration tests), 62 MiB the initramfs
  (regenerated every build), ~28 MiB generated files (pacman db, caches, certificates).
- `/etc` 3-way merge: a local edit to an image file and a new local file survive updates; an image
  change to a file the machine did not touch is applied; when both changed a file, the local copy
  wins and the image change is silently dropped. No `migrate_files` list needed.
- `/var` (journal, `/var/home`) is shared by all deployments. `bootc rollback` works (two
  deployments, each with its own `/etc`).
- `pacman` fails on the read-only `/usr`, as with arkdep; `bootc usroverlay` gives a writable
  `/usr` until the next reboot (try packages without rebuilding).
- Rootless podman and distrobox work as `roger`.

## T480 rehearsal (VM, bootc 1.17.0 -> 1.17.1, 2026-10-08)

A VM with the T480's layout (ESP, swap, ext4 root, ext4 `/home` with the user's files) booted from
the installer ISO (`cow_spacesize=2G`), `bootc/install` downloaded from GitHub:

- Install in ~1 min (pull from the registry included). Boots in 7-8 s, no failed units; sudo, iwd,
  the `/home` partition at `/var/home`, swap (priority 10, after zram), the firmware boot entry.
- `bootc upgrade` to the next build staged it in 8 s (changed layers only). After the reboot the
  install-time kernel arguments (`/home` and swap mounts, `resume=`, `rootflags`) were still there,
  and the `/etc` 3-way merge applied the image's corrected modes (`/etc/systemd` 775 -> 755,
  libvirt's `default.xml` 644 -> 600). The previous image stays as the rollback entry.
- `bootc status` shows no `version` on composefs (1.17.0 and 1.17.1) although the image has the
  label: `bootc-update` falls back to the image's creation date.
- The `userland` distrobox broke when its first setup was interrupted (see the dotfiles'
  pre-init hook): not bootc specific.

## Problems found

- bootcrew's Arch image has failed to build every day since 2026-08-31 (CI). Building bootc on
  Arch needs `--no-default-features` (the `selinux` feature links libselinux, only in the AUR).
- The recipe's `NoExtract usr/include/*` breaks compiling bootc: the builder stage uses plain Arch.
- podman bind mounts `/etc/resolv.conf` and `/etc/hostname` during builds: `--no-hostname`, and the
  overlay's `resolv.conf` link becomes a tmpfiles.d entry.
- `/usr/local` is a link to `/var/usrlocal`, which bootc never updates after the install: the
  recipe's scripts move to `/usr/bin`.
- Overlays extracted with `tar -xp` kept the checkout's UID 1000 and 775 modes, also on existing
  directories (`/usr`, `/etc/systemd`, `/etc/sudoers.d`): sudo ignored `sudoers.d` and iwd failed
  on D-Bus (the first registry image, `p14s:2026-10-07`). They are now extracted as root like
  arkdep-build's `cp -r`.
- bootc mounts the ESP read-only at `/boot`: `systemd-boot-random-seed.service` fails, masked.
- `bootc install` creates no firmware boot entry (only the `EFI/BOOT/BOOTX64.EFI` fallback):
  `install` adds or reorders it with `efibootmgr`.

## Missing before real use

- Done: the registry on the build server (`insecure` in `registries.conf.d`), retention
  (`prune`), `bootc` packaged once in `[aur]` instead of compiled in every build.
- Image signing (cosign + `policy.json` on the clients) instead of the GPG-signed arkdep repository.
- Machine-specific kernel arguments: `install` passes the `/home` mount, the swap partition and
  `resume=` with `--karg`, and they survive `bootc upgrade` (rehearsal). Hibernation: not tested.
- btrbk (`snapshot_dir /arkdep/snapshots`), `arkdep-diff`. Done: `notify-image`, the status page,
  updates (`bootc-update.timer`) and the waybar indicator.
- btrfs is "expected to work but not tested" upstream with the composefs backend; it worked here.
  No boot counting / automatic rollback (arkdep has none either).
- No in-place migration from arkdep: `install` reinstalls the root partition and keeps a separate
  `/home` partition (the T480 layout); the P14s has `/home` inside its btrfs root.
