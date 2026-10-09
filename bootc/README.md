# bootc images (`bootc/`)

Trial (since 2026-10-07) of [bootc](https://github.com/bootc-dev/bootc) as a replacement for
arkdep: the same recipes (`image/arkdep-build.d/<recipe>`) built as bootc container images, based
on the Arch image of [bootcrew/mono](https://github.com/bootcrew/mono). While both are compared the
T480 runs bootc (`t480`, built weekly) and the P14s stays on arkdep (`p14s` bootc image by hand);
`../install` sets the schedules. Implementation notes and pitfalls: `CLAUDE.md` in this directory.

- `Containerfile`: CachyOS v3 repositories and `linux-cachyos` like the recipe; `bootc` from the
  `[aur]` repository (`aur/local/bootc`: pinned version, no SELinux); composefs backend.
- `build-recipe.sh`: applies the arkdep recipe in arkdep-build's order (package lists, overlays,
  presets, locale-gen), without arkdep, `arkane-keyring` and `nss-altfiles`.
- `overlay/`: files only bootc systems need (the registry, AppArmor's `@{HOMEDIRS}`, the masked
  `systemd-boot-random-seed.service`, `bootc-update.timer`: stages new images, see below).
- `build`, `prune`: build, rechunk and push; retention in the registry.
- `install`: installs an image from the installer ISO on existing partitions, keeping `/home` (see
  below).

## Building and updates

- `bootc/build <recipe>` builds `bootc/Containerfile` (which applies the arkdep recipe with
  `build-recipe.sh` and installs `bootc` from `[aur]`), splits the image into per-package layers
  with [chunkah](https://github.com/coreos/chunkah) and pushes it to the registry with skopeo
  (the compressed layers as chunkah writes them) as `<recipe>:YYYY-MM-DD` and `<recipe>:latest`. The package list goes to `/mnt/repo/bootc/<recipe>/`
  for the notification.
- Each image is signed with the build server's sigstore key when pushed; the signature lives in
  the registry next to it (`sha256-<digest>.sig`), and the bootc systems refuse an unsigned image
  of `192.168.2.50:5000` (`/etc/containers/policy.json` and `registries.d/50-distro-builder.yaml`
  from the generic overlay of `image/arkdep-build.d/depends`, shared with the arkdep images; public
  key `keys/distro-builder-sigstore.pub` copied to `/etc/pki/containers/distro-builder.pub`).
  The status page marks each image "signada" or "sense signar".
- `bootc/prune <recipe>` keeps the newest 4 dated images (`KEEP`), with their signatures, deletes
  the signatures of images no tag names any more (a second build of the same day replaces the
  image of that date), and garbage-collects the registry (`--dry-run` shows what it would do). Both run under the same lock as the arkdep builds, one at a time.
- Scheduled weekly by `build-bootc@<recipe>.timer` for the recipes in `BOOTC_RECIPES` of
  `install` (default `t480`); run it now, for any recipe, with
  `sudo systemctl start build-bootc@p14s` and follow it with `journalctl -fu build-bootc@p14s`.
- On a bootc system `bootc-update.timer` (after boot and every 4 hours, skipped away from home)
  downloads and stages the newest image of its tag; it starts on the next boot. The waybar
  indicator (`arkdep-update-status`, same module as arkdep's) shows a staged image with its package
  changes; a click (or `sudo bootc-update`) looks for a newer one now.
- The registry (`serve/distro-registry.container`, `registry:2`, storage in `/mnt/repo/registry`)
  serves plain HTTP on port 5000; the images list it as insecure in
  `/etc/containers/registries.conf.d/50-distro-builder.conf`. A bootc system follows a recipe with
  `bootc switch 192.168.2.50:5000/<recipe>:latest` and updates with `bootc upgrade`.
- `bootc/install` installs an image on existing partitions from the installer ISO, keeping a
  `/home` partition: see [below](#installing-a-bootc-image-keeping-home).

## Installing a bootc image (keeping /home)

`bootc/install` formats the root partition (btrfs, `zstd:1`, `noatime`), reuses the ESP
(systemd-boot, first in the firmware boot order, a 5 s menu; other loaders stay), keeps the `/home`
partition untouched (mounted at `/var/home`), enables a swap partition for hibernation, and creates
the user (UID 1000, the arkdep installer's groups), the hostname and the Wi-Fi profile. Written for
the T480 (Artix: ESP `p1`, swap `p2`, root `p3`, ext4 home `p4`) and rehearsed in a VM with the same
layout.

Before, on the old system:

1. Back up what cannot be lost: the root partition is formatted (the home partition is not, but a
   wrong partition name would be).
2. The user's directory on the home partition must belong to UID 1000 (`--uid` otherwise).
3. Copy the Wi-Fi profile into it (iwd keeps it in a root-only directory):
   `sudo install -m 600 -o roger -g roger /var/lib/iwd/<SSID>.psk ~/`.
4. Note the partitions: `lsblk -f`.

Install:

1. Download the installer ISO, check its signature and write it to a USB stick (the whole device,
   e.g. `/dev/sda`, not a partition: `TRAN` says `usb`; everything on it is lost):

   ```sh
   curl -O http://192.168.2.50/iso/sha256sums.txt -O http://192.168.2.50/iso/sha256sums.txt.sig
   iso=$(awk '{ print $2 }' sha256sums.txt); curl -O "http://192.168.2.50/iso/$iso"
   gpg --dearmor < ~/distro-builder/keys/distro-builder.asc > distro-builder.gpg
   gpgv --keyring ./distro-builder.gpg sha256sums.txt.sig sha256sums.txt && sha256sum -c sha256sums.txt
   lsblk -d -o NAME,SIZE,TRAN,MODEL
   sudo dd if="$iso" of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
   ```

   Boot it in UEFI mode (ThinkPad: F12). At the boot menu press `e` and add `cow_spacesize=2G` to
   the kernel options: the live system installs podman (the image goes to a tmpfs, ~5 GB of RAM).
2. Network: a cable, or `iwctl station wlan0 connect <SSID>`.
3. Download and run the installer (it lists the disk, asks to type the root partition to confirm,
   and asks the user's password twice):

   ```sh
   curl -O https://raw.githubusercontent.com/vonbloom/distro-builder/main/bootc/install
   bash install --image 192.168.2.50:5000/t480:latest --root /dev/nvme0n1p3 --esp /dev/nvme0n1p1 \
       --home /dev/nvme0n1p4 --swap /dev/nvme0n1p2 --hostname anubis --wifi <SSID>.psk
   ```

   It stops before formatting anything if a partition, the user's directory or the Wi-Fi file is
   wrong, and can be run again after a failure.
4. Reboot and remove the USB stick.

First session:

1. Log in on tty1: sway starts.
2. If the home partition has an older `~/.dotfiles` checkout, update it (`git stash` local changes
   first) and restow: `cd ~/.dotfiles && git pull && ./install`. `deploy-userland` only clones the
   dotfiles when `~/.dotfiles` is missing, and only creates the distroboxes from
   `~/.config/distrobox/default.ini`.
3. `systemctl --user start deploy-userland` creates `playground` and `userland` and exports the
   apps. It runs by itself when the user manager starts (the first session after boot, SSH too),
   which on a home with older dotfiles happened before step 2. It takes minutes: do not log out or reboot until the
   "Sistema a punt" notification (an interrupted box is created again at the next login).
4. Check: `sudo bootc status` (the image and its tag), `systemctl --failed`.
5. A home from another system can hold user configs that win over the image's: move them aside
   (the T480's Artix home had `~/.config/rofi/config.rasi` with its own theme, GTK 3/4
   `settings.ini` and `gtk.css`, a full `~/.config/pipewire/pipewire.conf` and links to old
   dotfiles). Compare `ls ~/.config` with the P14s, which has none of them.

Afterwards, updates are staged by `bootc-update.timer` and shown by the waybar indicator (see
above), and start on the next boot. The boot menu lists each image as `Arch Linux (<recipe> <tag>)`
with the previous one as a fallback; `sudo bootc rollback` makes the previous one the default.

## Building and testing on a workstation

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
- `bootc status` showed no `version` on composefs (1.17.0 and 1.17.1) although the image had the
  label: the composefs backend reads only the manifest annotation, which `bootc/build` now sets too
  (bootc-dev/bootc#2227); `bootc-update` falls back to the image's creation date.
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
  `install` adds or reorders it with `efibootmgr`. Reported: bootc-dev/bootc#2557 (`bootctl --root`
  skips EFI variables unless `--variables=yes`).
- No boot menu: `bootctl install` writes a `loader.conf` with every line commented out, so bootc's
  own `timeout 5` (only written when the file is missing) never lands; `install` writes it.
  Reported: bootc-dev/bootc#2558. Every entry was titled "Arch Linux": the titles come from the
  image's os-release.
- `bootc status` shows no version on composefs for an image with only the
  `org.opencontainers.image.version` label: that backend reads the manifest annotation (the ostree
  one the label). `bootc/build` sets both; reported in bootc-dev/bootc#2227 (comment of
  2026-10-08).

## Missing before real use

- Done: the registry on the build server (`insecure` in `registries.conf.d`), retention
  (`prune`), `bootc` packaged once in `[aur]` instead of compiled in every build.
- Done (2026-10-08): image signing, sigstore (see the main README, Signatures).
- Machine-specific kernel arguments: `install` passes the `/home` mount, the swap partition and
  `resume=` with `--karg`, and they survive `bootc upgrade` (rehearsal). Hibernation: not tested.
- btrbk (`snapshot_dir /arkdep/snapshots`), `arkdep-diff`. Done: `notify-image`, the status page,
  updates (`bootc-update.timer`) and the waybar indicator.
- btrfs is "expected to work but not tested" upstream with the composefs backend; it worked here.
  No boot counting / automatic rollback (arkdep has none either).
- No in-place migration from arkdep: `install` reinstalls the root partition and keeps a separate
  `/home` partition (the T480 layout); the P14s has `/home` inside its btrfs root.
